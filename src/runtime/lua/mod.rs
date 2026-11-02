//! Lua extensions (Lua 5.4 through mlua). Lua reaches the editor through
//! the `soda` table, whose functions run commands and read state as the
//! command line does, register hooks and commands as Lua functions, and run
//! processes in the background with a function to call when they finish.
//!
//! The runtime runs one Lua request at a time and lends itself to it:
//! `soda` functions act on the runtime directly, and Lua that the request
//! starts in turn, such as a hook of an edit it makes, waits in a queue
//! until the request returns.
use super::Runtime;
mod buffer;
mod bundled;
use crate::interaction::{
    Command, LuaRequest,
    completion::{Asked, Item},
};
use mlua::{Function, Lua, LuaSerdeExt, SerializeOptions, Table, Value};
use std::{
    cell::{Cell, RefCell},
    sync::{
        Arc,
        mpsc::{Receiver, Sender, channel},
    },
};

/// Functions of the `soda` table; each forwards to the implementation lent
/// for the request being run.
const FUNCTIONS: &[&str] = &[
    "command",
    "val",
    "option",
    "message",
    "flag",
    "unflag",
    "note",
    "popup",
    "hook",
    "define_command",
    "spawn",
    "results",
    "open",
    "clipboard",
    "completion_source",
    "lsp_server",
    "lsp_request",
    "lsp_notify",
    "lsp_on",
    "lsp_uri",
    "lsp_info",
    "lsp_restart",
];
const PRELUDE: &str = r#"
local current, names, methods, bundled = ...
-- Modules come from the configuration and the system, never from wherever
-- the editor was started: startup requires them by name.
local function outside_project(path)
  local kept = {}
  for entry in path:gmatch("[^;]+") do
    if entry:sub(1, 2) ~= "./" then
      table.insert(kept, entry)
    end
  end
  return table.concat(kept, ";")
end
package.path = outside_project(package.path)
package.cpath = outside_project(package.cpath)
table.insert(package.searchers, function(name)
  local code = bundled[name]
  if code then
    return assert(load(code, "@soda/" .. name .. ".lua", "t"))
  end
end)
local function lent(name)
  local implementation = current()
  if not implementation then
    error(name .. " is only available while the editor runs Lua", 3)
  end
  return implementation
end
soda = {}
for _, name in ipairs(names) do
  soda[name] = function(...)
    return lent("soda." .. name)[name](...)
  end
end
local Buffer = { __name = "soda.buffer" }
Buffer.__index = Buffer
Buffer.__eq = function(a, b) return a.id == b.id end
Buffer.__tostring = function(buffer) return "buffer " .. buffer.id end
for _, name in ipairs(methods) do
  Buffer[name] = function(self, ...)
    if getmetatable(self) ~= Buffer then
      error("buf:" .. name .. " is a method; call it with ':'", 2)
    end
    return lent("buf:" .. name)["buffer_" .. name](self.id, ...)
  end
end
function soda.buffer()
  return setmetatable({ id = lent("soda.buffer").buffer() }, Buffer)
end
local completion_source = soda.completion_source
soda.completion_source = nil
soda.completion = {}
soda.lsp = {}
for _, name in ipairs({ "server", "request", "notify", "on", "uri", "info", "restart" }) do
  soda.lsp[name] = soda["lsp_" .. name]
  soda["lsp_" .. name] = nil
end
function soda.completion.register(source)
  local triggers = source.triggers or {}
  if type(source.complete) ~= "function" then
    error("a completion source needs a complete function", 2)
  end
  completion_source(table.concat(triggers), source.complete)
end
"#;
const IMPLEMENTATION: &str = "soda.implementation";
const CALLBACKS: &str = "soda.callbacks";

/// A finished `soda.spawn` process.
pub(super) struct Job {
    id: u64,
    /// Where `soda.spawn` was called; the function runs there.
    view: Option<crate::application::ViewId>,
    code: Option<i32>,
    stdout: String,
    stderr: String,
}
pub(super) enum Request {
    Chunk { origin: String, code: String },
    Call { id: u64, argument: String },
    Done(Job),
    Complete { source: u64, asked: Arc<Asked> },
    Lsp(super::lsp::Delivery),
}
/// What a source answered, whenever it does.
struct Answer {
    generation: u64,
    source: u64,
    items: Vec<Item>,
    incomplete: bool,
}
impl From<LuaRequest> for Request {
    fn from(request: LuaRequest) -> Self {
        match request {
            LuaRequest::Chunk { origin, code } => Self::Chunk { origin, code },
            LuaRequest::Call { id, argument } => Self::Call { id, argument },
        }
    }
}
pub(super) struct Host {
    lua: Lua,
    /// The id the next registered function gets.
    next: Cell<u64>,
    jobs: (Sender<Job>, Receiver<Job>),
    answers: (Sender<Answer>, Receiver<Answer>),
}
impl Host {
    fn new() -> mlua::Result<Self> {
        let lua = Lua::new();
        lua.set_named_registry_value(CALLBACKS, lua.create_table()?)?;
        let current =
            lua.create_function(|lua, ()| lua.named_registry_value::<Value>(IMPLEMENTATION))?;
        lua.load(PRELUDE).set_name("soda prelude").call::<()>((
            current,
            FUNCTIONS,
            buffer::METHODS,
            lua.create_table_from(bundled::MODULES.iter().copied())?,
        ))?;
        Ok(Self {
            lua,
            next: Cell::new(1),
            jobs: channel(),
            answers: channel(),
        })
    }
    /// Calls a source with what it is asked and a sink for its answer. The
    /// sink outlives the call: a source that runs a process fills it later.
    fn complete(&self, source: u64, asked: &Asked) -> mlua::Result<()> {
        let lua = &self.lua;
        let context = lua.create_table()?;
        context.set("prefix", asked.prefix.as_str())?;
        context.set("language", asked.language.as_str())?;
        context.set("line", asked.line)?;
        context.set("column", asked.column)?;
        context.set("trigger", asked.trigger.map(String::from))?;
        let generation = asked.generation;
        let answer = move |items, incomplete| Answer {
            generation,
            source,
            items,
            incomplete,
        };
        let sink = lua.create_table()?;
        let sender = self.answers.0.clone();
        sink.set(
            "add",
            lua.create_function(move |_, (_, items): (Table, Vec<Table>)| {
                let items = items.iter().map(item).collect::<mlua::Result<_>>()?;
                let _ = sender.send(answer(items, false));
                Ok(())
            })?,
        )?;
        let sender = self.answers.0.clone();
        sink.set(
            "done",
            lua.create_function(move |_, (_, options): (Table, Option<Table>)| {
                let incomplete = options.is_some_and(|o| {
                    o.get::<Option<bool>>("incomplete").ok().flatten() == Some(true)
                });
                let _ = sender.send(answer(vec![], incomplete));
                Ok(())
            })?,
        )?;
        self.callbacks()?
            .get::<Function>(source)?
            .call::<()>((context, sink))
    }
    fn callbacks(&self) -> mlua::Result<Table> {
        self.lua.named_registry_value(CALLBACKS)
    }
    /// Keeps a function for a later call; returns its id.
    fn keep(&self, function: Function) -> mlua::Result<u64> {
        let id = self.next.get();
        self.next.set(id + 1);
        self.callbacks()?.set(id, function)?;
        Ok(id)
    }
    /// Runs one request with the `soda` functions lent the runtime.
    fn run(&self, runtime: &mut Runtime, request: Request) -> mlua::Result<()> {
        let lua = &self.lua;
        let runtime = RefCell::new(runtime);
        let edited = buffer::Edited::default();
        let result = lua.scope(|scope| {
            let soda = lua.create_table()?;
            buffer::register(scope, &soda, &runtime, &edited)?;
            soda.set(
                "command",
                scope.create_function(|_, line: String| {
                    let mut runtime = runtime.borrow_mut();
                    runtime.failed = false;
                    runtime.command(Command::Named(line));
                    Ok((!runtime.failed, runtime.message.clone()))
                })?,
            )?;
            soda.set(
                "val",
                scope.create_function(|_, name: String| {
                    expand(&runtime.borrow(), &format!("%val{{{name}}}"))
                })?,
            )?;
            soda.set(
                "option",
                scope.create_function(|_, name: String| {
                    expand(&runtime.borrow(), &format!("%opt{{{name}}}"))
                })?,
            )?;
            soda.set(
                "message",
                scope.create_function(|_, text: String| {
                    runtime.borrow_mut().report(text);
                    Ok(())
                })?,
            )?;
            soda.set(
                "flag",
                scope.create_function(
                    |_, (group, face, sign, lines): (String, String, String, Vec<usize>)| {
                        let flag = crate::application::Flag::new(&face, &sign)
                            .map_err(mlua::Error::runtime)?;
                        let lines = lines
                            .into_iter()
                            .filter(|line| *line > 0)
                            .map(|line| line - 1)
                            .collect();
                        let mut runtime = runtime.borrow_mut();
                        let document = runtime.document().map_err(mlua::Error::runtime)?;
                        runtime.edit_event(crate::application::Event::Flag {
                            document,
                            group,
                            flag,
                            lines,
                        })
                    },
                )?,
            )?;
            soda.set(
                "note",
                scope.create_function(|_, (group, items): (String, Vec<mlua::Table>)| {
                    let notes = items
                        .iter()
                        .map(|item| {
                            let place = |name: &str| -> mlua::Result<(usize, usize)> {
                                let [line, column]: [usize; 2] = item.get(name)?;
                                Ok((line.saturating_sub(1), column.saturating_sub(1)))
                            };
                            let severity: String = item.get("severity")?;
                            Ok(crate::application::NoteSpan {
                                start: place("from")?,
                                end: place("to")?,
                                severity: crate::application::Severity::parse(&severity)
                                    .map_err(mlua::Error::runtime)?,
                                text: item.get("text")?,
                            })
                        })
                        .collect::<mlua::Result<Vec<_>>>()?;
                    let mut runtime = runtime.borrow_mut();
                    let document = runtime.document().map_err(mlua::Error::runtime)?;
                    runtime.edit_event(crate::application::Event::Note {
                        document,
                        group,
                        notes,
                    })
                })?,
            )?;
            soda.set(
                "popup",
                scope.create_function(|_, text: String| {
                    let mut runtime = runtime.borrow_mut();
                    runtime.popup = Some(text);
                    runtime.popup_scroll.set(0);
                    runtime.dirty = true;
                    Ok(())
                })?,
            )?;
            soda.set(
                "unflag",
                scope.create_function(|_, group: Option<String>| {
                    let mut runtime = runtime.borrow_mut();
                    let document = runtime.document().map_err(mlua::Error::runtime)?;
                    // Nothing to remove is not a failure for a script.
                    let _ = runtime
                        .app
                        .dispatch(crate::application::Event::Unflag { document, group });
                    runtime.dirty = true;
                    Ok(())
                })?,
            )?;
            soda.set(
                "hook",
                scope.create_function(
                    |_, (event, filter, function): (String, String, Function)| {
                        let id = self.keep(function)?;
                        runtime
                            .borrow_mut()
                            .layers
                            .add_hook(&event, &filter, format!("lua-call {id} %val{{hook}}"))
                            .map_err(mlua::Error::runtime)
                    },
                )?,
            )?;
            soda.set(
                "define_command",
                scope.create_function(|_, (name, function): (String, Function)| {
                    let id = self.keep(function)?;
                    runtime
                        .borrow_mut()
                        .layers
                        .configure(Command::Define {
                            name,
                            body: format!("lua-call {id} %arg{{@}}"),
                        })
                        .map_err(mlua::Error::runtime)
                })?,
            )?;
            soda.set(
                "results",
                scope.create_function(|_, (kind, lines): (String, Vec<String>)| {
                    if kind.is_empty() || kind == "file" || kind.contains(['*', ' ']) {
                        return Err(mlua::Error::runtime(format!(
                            "{kind:?} cannot name results"
                        )));
                    }
                    let mut runtime = runtime.borrow_mut();
                    runtime.command(Command::Results { kind, lines });
                    Ok(())
                })?,
            )?;
            soda.set(
                "open",
                scope.create_function(
                    |_, (path, line, column): (String, Option<i64>, Option<i64>)| {
                        let line = line.unwrap_or(1);
                        let column = column.unwrap_or(1);
                        if line < 1 || column < 1 {
                            return Err(mlua::Error::runtime(format!(
                                "position {{{line}, {column}}} is outside the buffer"
                            )));
                        }
                        let mut runtime = runtime.borrow_mut();
                        runtime.layers.expect_jump();
                        let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
                        let path = crate::interaction::path::resolve_path(
                            &runtime.app.root(),
                            home.as_deref(),
                            std::path::Path::new(&path),
                        )
                        .map_err(mlua::Error::runtime)?;
                        runtime.edit_event(crate::application::Event::OpenAt {
                            path,
                            line: line as usize - 1,
                            column: column as usize - 1,
                        })
                    },
                )?,
            )?;
            soda.set(
                "clipboard",
                scope.create_function(|_, text: String| {
                    runtime
                        .borrow_mut()
                        .edit_event(crate::application::Event::SetClipboard {
                            text,
                            linewise: false,
                        })
                })?,
            )?;
            soda.set(
                "spawn",
                scope.create_function(
                    |_, (argv, function, input): (Vec<String>, Function, Option<String>)| {
                        if argv.is_empty() {
                            return Err(mlua::Error::runtime("soda.spawn needs a program"));
                        }
                        let id = self.keep(function)?;
                        let (root, view) = {
                            let runtime = runtime.borrow();
                            (runtime.app.root(), runtime.app.active_view())
                        };
                        let sender = self.jobs.0.clone();
                        std::thread::spawn(move || {
                            let mut job = spawn(id, &argv, &root, input);
                            job.view = view;
                            let _ = sender.send(job);
                        });
                        Ok(())
                    },
                )?,
            )?;
            soda.set(
                "completion_source",
                scope.create_function(|_, (triggers, function): (String, Function)| {
                    let id = self.keep(function)?;
                    runtime
                        .borrow_mut()
                        .layers
                        .completion_source(id, triggers.chars().collect());
                    Ok(())
                })?,
            )?;
            soda.set(
                "lsp_server",
                scope.create_function(
                    |_, (language, command): (String, Option<Vec<String>>)| {
                        if command.as_ref().is_some_and(Vec::is_empty) {
                            return Err(mlua::Error::runtime("a language server needs a program"));
                        }
                        runtime.borrow_mut().lsp.set_server(language, command);
                        Ok(())
                    },
                )?,
            )?;
            soda.set(
                "lsp_request",
                scope.create_function(
                    |lua, (method, params, function): (String, Value, Function)| {
                        let params: serde_json::Value = lua.from_value(params)?;
                        let id = self.keep(function)?;
                        let mut runtime = runtime.borrow_mut();
                        let Some(key) = runtime.lsp_key() else {
                            return Ok(false);
                        };
                        let Runtime { lsp, app, .. } = &mut **runtime;
                        lsp.sync(app, true);
                        Ok(lsp.request(&key, &method, params, id))
                    },
                )?,
            )?;
            soda.set(
                "lsp_notify",
                scope.create_function(|lua, (method, params): (String, Value)| {
                    let params: serde_json::Value = lua.from_value(params)?;
                    let mut runtime = runtime.borrow_mut();
                    let Some(key) = runtime.lsp_key() else {
                        return Ok(false);
                    };
                    Ok(runtime.lsp.notify(&key, &method, params))
                })?,
            )?;
            soda.set(
                "lsp_on",
                scope.create_function(|_, (method, function): (String, Function)| {
                    let id = self.keep(function)?;
                    runtime.borrow_mut().lsp.on(method, id);
                    Ok(())
                })?,
            )?;
            soda.set(
                "lsp_uri",
                scope.create_function(|_, ()| {
                    let runtime = runtime.borrow();
                    let document = runtime.document().ok();
                    let path = document
                        .and_then(|document| runtime.app.workspace().file(document))
                        .and_then(|file| file.path());
                    Ok(path.map(super::lsp::uri))
                })?,
            )?;
            soda.set(
                "lsp_info",
                scope.create_function(|lua, ()| {
                    let runtime = runtime.borrow();
                    let Some(key) = runtime.lsp_key() else {
                        return Ok(Value::Nil);
                    };
                    let Some((encoding, capabilities)) = runtime.lsp.client_of(&key) else {
                        return Ok(Value::Nil);
                    };
                    let info = lua.create_table()?;
                    info.set("encoding", encoding)?;
                    info.set("capabilities", to_lua(lua, capabilities)?)?;
                    Ok(Value::Table(info))
                })?,
            )?;
            soda.set(
                "lsp_restart",
                scope.create_function(|_, ()| {
                    let mut runtime = runtime.borrow_mut();
                    if let Some(key) = runtime.lsp_key() {
                        runtime.lsp.restart(&key);
                    }
                    Ok(())
                })?,
            )?;
            lua.set_named_registry_value(IMPLEMENTATION, soda)?;
            let result = match request {
                Request::Chunk { origin, code } => lua.load(code).set_name(origin).exec(),
                Request::Call { id, argument } => {
                    self.callbacks()?.get::<Function>(id)?.call::<()>(argument)
                }
                Request::Done(job) => {
                    let callbacks = self.callbacks()?;
                    let function = callbacks.get::<Function>(job.id)?;
                    callbacks.set(job.id, Value::Nil)?;
                    function.call::<()>((job.code, job.stdout, job.stderr))
                }
                Request::Complete { source, asked } => self.complete(source, &asked),
                Request::Lsp(super::lsp::Delivery::Answer {
                    function,
                    result,
                    error,
                }) => {
                    let callbacks = self.callbacks()?;
                    let call = callbacks.get::<Function>(function)?;
                    callbacks.set(function, Value::Nil)?;
                    call.call::<()>((to_lua(lua, &result)?, to_lua(lua, &error)?))
                }
                Request::Lsp(super::lsp::Delivery::Notification { function, params }) => self
                    .callbacks()?
                    .get::<Function>(function)?
                    .call::<()>(to_lua(lua, &params)?),
            };
            lua.set_named_registry_value(IMPLEMENTATION, Value::Nil)?;
            result
        });
        buffer::squash(runtime.into_inner(), edited.into_inner());
        result
    }
}
/// JSON as Lua sees it: `null` is `nil`, so a field left out and a field
/// set to null read alike.
fn to_lua(lua: &Lua, value: &serde_json::Value) -> mlua::Result<Value> {
    lua.to_value_with(
        value,
        SerializeOptions::new()
            .serialize_none_to_null(false)
            .serialize_unit_to_null(false),
    )
}
/// A candidate from the table a source gives.
fn item(table: &Table) -> mlua::Result<Item> {
    let label: String = table.get("label")?;
    let snippet: Option<String> = table.get("snippet")?;
    let mut item = Item::plain(
        label,
        table.get::<Option<String>>("detail")?.unwrap_or_default(),
        table.get::<Option<usize>>("back")?.unwrap_or(0),
    );
    if let Some(filter) = table.get("filter")? {
        item.filter = filter;
    }
    if let Some(text) = table.get("text")? {
        item.text = text;
    }
    if let Some(snippet) = snippet {
        item.text = snippet;
        item.snippet = true;
    }
    Ok(item)
}
fn expand(runtime: &Runtime, text: &str) -> mlua::Result<String> {
    runtime
        .layers
        .expand(text, &runtime.app, &runtime.app.root())
        .map_err(mlua::Error::runtime)
}
/// Runs a process to its end, in the project root.
fn spawn(id: u64, argv: &[String], root: &std::path::Path, input: Option<String>) -> Job {
    use std::{io::Write, process::Stdio};
    let child = std::process::Command::new(&argv[0])
        .args(&argv[1..])
        .current_dir(root)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let output = child.and_then(|mut child| {
        if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
            // A process that exits without reading is not an error here.
            let _ = stdin.write_all(input.as_bytes());
        }
        child.wait_with_output()
    });
    match output {
        Ok(output) => Job {
            id,
            view: None,
            code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        },
        Err(error) => Job {
            id,
            view: None,
            code: None,
            stdout: String::new(),
            stderr: format!("{}: {error}", argv[0]),
        },
    }
}

impl Runtime {
    /// Runs Lua code, such as `init.lua`; returns its error, which is also
    /// the status message and logged.
    pub fn source_lua(&mut self, origin: &str, code: &str) -> Result<(), String> {
        let view = self.app.active_view();
        self.lua_queue.push_back((
            Request::Chunk {
                origin: origin.to_owned(),
                code: code.to_owned(),
            },
            view,
        ));
        match self.run_lua() {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
    /// Makes a directory's `?.lua` modules take precedence in `require`.
    pub fn add_lua_modules(&mut self, directory: &std::path::Path) {
        let _ = self.source_lua(
            "package.path",
            &format!(
                "package.path = [==[{}]==] .. ';' .. package.path",
                directory.join("?.lua").display()
            ),
        );
    }
    /// Loads the built-in modules that start with the editor, each on its
    /// own, so that one replaced by a broken file costs only itself.
    pub fn load_startup_lua(&mut self) {
        for name in bundled::STARTUP {
            let _ = self.source_lua("startup", &format!("require({name:?})"));
        }
    }
    /// Runs queued Lua unless Lua is running already, in which case it
    /// runs when that returns. Returns the last error.
    pub(super) fn run_lua(&mut self) -> Option<String> {
        if self.lua_running {
            return None;
        }
        let host = match self.lua.take().map_or_else(Host::new, Ok) {
            Ok(host) => host,
            Err(error) => {
                self.lua_queue.clear();
                let error = format!("lua: {error}");
                self.lua_failed(error.clone());
                return Some(error);
            }
        };
        self.lua_running = true;
        let mut last = None;
        while let Some((request, view)) = self.lua_queue.pop_front() {
            // Commands act on the view the request came from while it is
            // open, as hooks do.
            let outer = self.app.context();
            let _ = self
                .app
                .dispatch(crate::application::Event::SetContext(view));
            let result = host.run(self, request);
            let _ = self
                .app
                .dispatch(crate::application::Event::SetContext(outer));
            if let Err(error) = result {
                let error = format!("lua: {error}");
                self.lua_failed(error.clone());
                last = Some(error);
            }
        }
        self.lua_running = false;
        self.lua = Some(host);
        last
    }
    fn lua_failed(&mut self, error: String) {
        self.log(error.clone());
        self.logged = error.clone();
        self.message = error;
        self.dirty = true;
    }
    /// Asks the Lua sources a request names.
    pub(super) fn ask_lua_sources(&mut self, asked: &Asked) {
        let shared = Arc::new(Asked {
            sources: vec![],
            prefix: asked.prefix.clone(),
            language: asked.language.clone(),
            ..*asked
        });
        for source in &asked.sources {
            let request = Request::Complete {
                source: *source,
                asked: shared.clone(),
            };
            self.lua_queue.push_back((request, Some(asked.view)));
        }
        if !asked.sources.is_empty() {
            self.run_lua();
        }
    }
    /// Collects finished processes and calls their functions.
    pub(super) fn poll_lua(&mut self) {
        let Some(host) = &self.lua else {
            return;
        };
        let answers: Vec<_> = host.answers.1.try_iter().collect();
        for answer in answers {
            self.dirty |= self.layers.completion_results(
                answer.generation,
                answer.source,
                answer.items,
                answer.incomplete,
                &self.app,
            );
        }
        let Some(host) = &self.lua else {
            return;
        };
        let done: Vec<_> = host
            .jobs
            .1
            .try_iter()
            .map(|job| {
                let view = job.view;
                (Request::Done(job), view)
            })
            .collect();
        if !done.is_empty() {
            self.lua_queue.extend(done);
            self.run_lua();
        }
    }
    /// Starts servers, sends edits and takes what servers said.
    pub(super) fn poll_lsp(&mut self) {
        let failure = self.lsp.sync(&self.app, false);
        let (deliveries, closed) = self.lsp.poll();
        if let Some(error) = failure.or(closed) {
            self.report(error);
        }
        if !deliveries.is_empty() {
            let view = self.app.active_view();
            self.lua_queue
                .extend(deliveries.into_iter().map(|d| (Request::Lsp(d), view)));
            self.run_lua();
        }
    }
    /// The server of the current document: its language and root.
    fn lsp_key(&self) -> Option<super::lsp::Key> {
        let document = self.document().ok()?;
        let editor = self.app.workspace().editor(document)?;
        let language = editor.model().document().language().profile().id.clone();
        Some((language, self.app.server_root_of(document)))
    }
    /// The current document, for Lua functions acting on it.
    fn document(&self) -> Result<crate::editor::DocumentId, String> {
        self.app
            .active_view()
            .and_then(|id| self.app.view(id))
            .map(|view| view.document_id)
            .ok_or_else(|| "no document".to_owned())
    }
    /// Dispatches an event for Lua; a failure becomes a Lua error.
    fn edit_event(&mut self, event: crate::application::Event) -> mlua::Result<()> {
        self.failed = false;
        self.dispatch(event);
        if self.failed {
            Err(mlua::Error::runtime(self.message.clone()))
        } else {
            Ok(())
        }
    }
}
