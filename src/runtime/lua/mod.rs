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
mod editor;
mod files;
mod marks;
mod raw;
mod server;
mod setup;
use crate::interaction::{
    LuaRequest,
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
    "set",
    "declare_option",
    "message",
    "log",
    "flag",
    "unflag",
    "note",
    "paint",
    "popup",
    "prompt",
    "choose",
    "input",
    "hint",
    "status",
    "tokens",
    "inlays",
    "indicator",
    "keys",
    "map",
    "map_default",
    "unmap",
    "keymap",
    "face",
    "theme",
    "themes",
    "language",
    "thing",
    "bindings",
    "hook",
    "unhook",
    "define_command",
    "spawn",
    "kill",
    "defer",
    "cancel",
    "results",
    "ripgrep",
    "tree_show",
    "tree_children",
    "open",
    "clipboard",
    "file_kind",
    "create_file",
    "rename_file",
    "delete_file",
    "json_decode",
    "completion_source",
    "buffer_list",
    "window_list",
    "lsp_server",
    "lsp_request",
    "lsp_cancel",
    "lsp_notify",
    "lsp_on",
    "lsp_uri",
    "lsp_info",
    "lsp_restart",
    "lsp_array",
    "lsp_set_root",
    "lsp_start",
    "lsp_stop",
    "lsp_servers",
    "lsp_tokens",
    "lsp_inlays",
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
local buffer_list, window_list = soda.buffer_list, soda.window_list
soda.buffer_list, soda.window_list = nil, nil
-- Every open document, as handles.
function soda.buffers()
  local out = {}
  for _, id in ipairs(buffer_list()) do
    table.insert(out, setmetatable({ id = id }, Buffer))
  end
  return out
end
-- Windows on screen, the split ones in reading order, then side windows.
function soda.windows()
  local out = window_list()
  for _, window in ipairs(out) do
    window.buffer = setmetatable({ id = window.buffer }, Buffer)
  end
  return out
end
function soda.buffer(path)
  local id = lent("soda.buffer").buffer(path)
  return id and setmetatable({ id = id }, Buffer)
end
local tree_show, tree_children = soda.tree_show, soda.tree_children
soda.tree_show, soda.tree_children = nil, nil
local tree_ids = 0
-- A tree in the document `*name*`. Nodes are tables with `label`, and
-- `detail`, `children`, `expanded` or `leaf`; without children, `expand`
-- is asked for them when the node first opens, unless it is a leaf.
-- `open(node)` takes Enter on a node. The functions get the tables given.
function soda.tree(spec)
  if type(spec) ~= "table" or type(spec.name) ~= "string" then
    error("soda.tree takes { name, roots, expand, open }", 2)
  end
  local nodes = {}
  local function convert(list)
    local out = {}
    for _, node in ipairs(list or {}) do
      tree_ids = tree_ids + 1
      nodes[tree_ids] = node
      table.insert(out, {
        id = tree_ids,
        label = tostring(node.label or ""),
        detail = node.detail ~= nil and tostring(node.detail) or nil,
        children = node.children ~= nil and convert(node.children) or nil,
        more = node.children == nil and spec.expand ~= nil and not node.leaf,
        expanded = node.expanded == true,
      })
    end
    return out
  end
  tree_show(spec.name, convert(spec.roots), function(argument)
    local event, id = argument:match("^(%a+) (%d+)$")
    id = tonumber(id)
    local node = nodes[id]
    if not node then
      return
    end
    if event == "open" and spec.open then
      spec.open(node)
    elseif event == "expand" then
      spec.expand(node, function(children)
        tree_children(spec.name, id, convert(children))
      end)
    end
  end)
end
local completion_source = soda.completion_source
soda.completion_source = nil
soda.completion = {}
soda.lsp = {}
for _, name in ipairs({ "server", "request", "cancel", "notify", "on", "uri", "info", "restart", "array",
                        "set_root", "start", "stop", "servers", "tokens", "inlays" }) do
  soda.lsp[name] = soda["lsp_" .. name]
  soda["lsp_" .. name] = nil
end
function soda.completion.register(source)
  local triggers = source.triggers or {}
  if type(source.complete) ~= "function" then
    error("a completion source needs a complete function", 2)
  end
  if source.resolve ~= nil and type(source.resolve) ~= "function" then
    error("resolve is a function", 2)
  end
  completion_source(table.concat(triggers), source.complete, source.resolve)
end
"#;
const IMPLEMENTATION: &str = "soda.implementation";
const CALLBACKS: &str = "soda.callbacks";

/// A finished `soda.spawn` process.
pub(super) struct Job {
    id: u64,
    code: Option<i32>,
    stdout: String,
    stderr: String,
    /// The functions that took its lines, done with now.
    lines: Vec<u64>,
}
pub(super) enum Request {
    Chunk {
        origin: String,
        code: String,
    },
    Call {
        id: u64,
        argument: String,
    },
    /// An argument's `candidates` function, to list its words.
    Candidates {
        function: u64,
        token: u64,
    },
    /// A question's function, with its answer; the function goes once
    /// called.
    Answer {
        id: u64,
        text: String,
        index: Option<usize>,
    },
    Done(Job),
    /// A line a process wrote, for the function streaming it.
    Line {
        function: u64,
        text: String,
    },
    /// A `soda.defer` function whose time came.
    Timer(u64),
    Complete {
        source: u64,
        asked: Arc<Asked>,
    },
    /// A source's `resolve`, about the candidate with this key.
    Resolve {
        function: u64,
        source: u64,
        key: i64,
    },
    Lsp(super::lsp::Delivery),
}
/// What a source answered, whenever it does.
enum Answer {
    Items {
        generation: u64,
        source: u64,
        items: Vec<Item>,
        incomplete: bool,
    },
    /// The words an argument's `candidates` function listed.
    Candidates {
        token: u64,
        items: Vec<crate::interaction::slots::Item>,
    },
    /// More about one candidate.
    Resolved {
        source: u64,
        key: i64,
        detail: Option<String>,
        doc: Option<String>,
    },
}
impl From<LuaRequest> for Request {
    fn from(request: LuaRequest) -> Self {
        match request {
            LuaRequest::Chunk { origin, code } => Self::Chunk { origin, code },
            LuaRequest::Call { id, argument } => Self::Call { id, argument },
            LuaRequest::Candidates { function, token } => Self::Candidates { function, token },
            LuaRequest::Answer { id, text, index } => Self::Answer { id, text, index },
        }
    }
}
pub(super) struct Host {
    lua: Lua,
    /// The id the next registered function gets.
    next: Cell<u64>,
    /// What processes send, with the view each started in.
    jobs: (Sender<Sent>, Receiver<Sent>),
    /// `soda.spawn` processes by function: their process group once they
    /// run, none while they start.
    children: Children,
    answers: (Sender<Answer>, Receiver<Answer>),
    /// When the request running now has to stop.
    deadline: std::rc::Rc<Cell<Option<std::time::Instant>>>,
    /// `soda.defer` functions: when, which, and the view they run on.
    timers: RefCell<Vec<(std::time::Instant, u64, Option<crate::application::ViewId>)>>,
}
/// How long one request may run. Lua runs on the editor's thread, so a
/// loop that does not end would hold the editor for good; past this every
/// instruction count check fails, so a `pcall` cannot keep it going.
const LUA_LIMIT: std::time::Duration = std::time::Duration::from_secs(3);
impl Host {
    /// When the next `soda.defer` timer is due.
    pub(super) fn next_timer(&self) -> Option<std::time::Instant> {
        self.timers.borrow().iter().map(|(at, ..)| *at).min()
    }
    fn new() -> mlua::Result<Self> {
        let lua = Lua::new();
        let deadline = std::rc::Rc::new(Cell::new(None::<std::time::Instant>));
        let due = deadline.clone();
        lua.set_global_hook(
            mlua::HookTriggers::new().every_nth_instruction(10_000),
            move |_, _| match due.get() {
                Some(at) if std::time::Instant::now() > at => Err(mlua::Error::runtime(format!(
                    "stopped after {} s; does a loop never end?",
                    LUA_LIMIT.as_secs()
                ))),
                _ => Ok(mlua::VmState::Continue),
            },
        )?;
        // Errors a request's time ran out with go on through `pcall` and its
        // kind, so that catching them does not keep a loop going.
        let due = deadline.clone();
        let over = lua.create_function(move |_, ()| {
            Ok(due.get().is_some_and(|at| std::time::Instant::now() > at))
        })?;
        lua.load(
            r#"
            local over = ...
            local function pass(ok, ...)
              if not ok and over() then
                error((...), 0)
              end
              return ok, ...
            end
            local pcall, xpcall, resume = pcall, xpcall, coroutine.resume
            _G.pcall = function(...) return pass(pcall(...)) end
            _G.xpcall = function(...) return pass(xpcall(...)) end
            coroutine.resume = function(...) return pass(resume(...)) end
            "#,
        )
        .set_name("soda limit")
        .call::<()>(over)?;
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
            children: Default::default(),
            answers: channel(),
            deadline,
            timers: RefCell::default(),
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
        let answer = move |items, incomplete| Answer::Items {
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
                crate::wake::wake();
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
                crate::wake::wake();
                Ok(())
            })?,
        )?;
        self.callbacks()?
            .get::<Function>(source)?
            .call::<()>((context, sink))
    }
    /// Calls an argument's `candidates` function with a function to call
    /// with the words, now or later; words it returns instead are taken
    /// at once.
    fn candidates(&self, function: u64, token: u64) -> mlua::Result<()> {
        let sender = self.answers.0.clone();
        let send = move |items: Vec<Value>| -> mlua::Result<()> {
            let items = items
                .into_iter()
                .map(editor::word_item)
                .collect::<mlua::Result<_>>()?;
            let _ = sender.send(Answer::Candidates { token, items });
            crate::wake::wake();
            Ok(())
        };
        let done = {
            let send = send.clone();
            self.lua
                .create_function(move |_, items: Vec<Value>| send(items))?
        };
        let returned = self
            .callbacks()?
            .get::<Function>(function)?
            .call::<Option<Vec<Value>>>(done)?;
        match returned {
            Some(items) => send(items),
            None => Ok(()),
        }
    }
    /// Calls a source's `resolve` with a candidate's key and a function to
    /// call with `{ detail, doc }`, now or later.
    fn resolve(&self, function: u64, source: u64, key: i64) -> mlua::Result<()> {
        let sender = self.answers.0.clone();
        let done = self.lua.create_function(move |_, more: Option<Table>| {
            let field = |name: &str| -> mlua::Result<Option<String>> {
                more.as_ref()
                    .map_or(Ok(None), |more| more.get::<Option<String>>(name))
            };
            let _ = sender.send(Answer::Resolved {
                source,
                key,
                detail: field("detail")?,
                doc: field("doc")?,
            });
            crate::wake::wake();
            Ok(())
        })?;
        self.callbacks()?
            .get::<Function>(function)?
            .call::<()>((key, done))
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
        self.deadline
            .set(Some(std::time::Instant::now() + LUA_LIMIT));
        let result = self.request(runtime, request);
        self.deadline.set(None);
        result
    }
    fn request(&self, runtime: &mut Runtime, request: Request) -> mlua::Result<()> {
        let lua = &self.lua;
        if !runtime.released.is_empty() {
            let callbacks = self.callbacks()?;
            for id in std::mem::take(&mut runtime.released) {
                callbacks.set(id, Value::Nil)?;
            }
        }
        let runtime = RefCell::new(runtime);
        let edited = buffer::Edited::default();
        let result = lua.scope(|scope| {
            let soda = lua.create_table()?;
            buffer::register(scope, &soda, &runtime, &edited)?;
            editor::register(scope, &soda, &runtime, self)?;
            marks::register(scope, &soda, &runtime)?;
            files::register(scope, &soda, &runtime)?;
            setup::register(scope, &soda, &runtime, self)?;
            server::register(scope, &soda, &runtime, self)?;
            raw::register(scope, &soda, &runtime)?;
            lua.set_named_registry_value(IMPLEMENTATION, soda)?;
            let result = match request {
                Request::Chunk { origin, code } => lua.load(code).set_name(origin).exec(),
                Request::Call { id, argument } => {
                    self.callbacks()?.get::<Function>(id)?.call::<()>(argument)
                }
                Request::Candidates { function, token } => self.candidates(function, token),
                Request::Answer { id, text, index } => {
                    let callbacks = self.callbacks()?;
                    let function = callbacks.get::<Function>(id)?;
                    callbacks.set(id, Value::Nil)?;
                    function.call::<()>((text, index))
                }
                Request::Timer(id) => {
                    let callbacks = self.callbacks()?;
                    let function = callbacks.get::<Function>(id)?;
                    callbacks.set(id, Value::Nil)?;
                    function.call::<()>(())
                }
                Request::Line { function, text } => self
                    .callbacks()?
                    .get::<Function>(function)?
                    .call::<()>(text),
                Request::Done(job) => {
                    let callbacks = self.callbacks()?;
                    let function = callbacks.get::<Function>(job.id)?;
                    callbacks.set(job.id, Value::Nil)?;
                    for line in &job.lines {
                        callbacks.set(*line, Value::Nil)?;
                    }
                    function.call::<()>((job.code, job.stdout, job.stderr))
                }
                Request::Complete { source, asked } => self.complete(source, &asked),
                Request::Resolve {
                    function,
                    source,
                    key,
                } => self.resolve(function, source, key),
                Request::Lsp(super::lsp::Delivery::Answer {
                    function,
                    result,
                    error,
                    raw,
                }) => {
                    let callbacks = self.callbacks()?;
                    let call = callbacks.get::<Function>(function)?;
                    callbacks.set(function, Value::Nil)?;
                    // Asked for raw, the answer stays JSON behind a handle.
                    let result = match raw && !result.is_null() {
                        true => Value::UserData(
                            lua.create_userdata(raw::Json(std::sync::Arc::new(result)))?,
                        ),
                        false => to_lua(lua, &result)?,
                    };
                    call.call::<()>((result, to_lua(lua, &error)?))
                }
                Request::Lsp(super::lsp::Delivery::Request {
                    functions,
                    params,
                    key,
                    id,
                    fallback,
                }) => {
                    // The server waits for an answer, so it gets one even
                    // when a function fails.
                    let mut answer = Ok(None);
                    let callbacks = self.callbacks()?;
                    for function in functions {
                        let call = callbacks
                            .get::<Function>(function)
                            .and_then(|f| f.call::<Value>(to_lua(lua, &params)?));
                        match call {
                            Ok(Value::Nil) => continue,
                            Ok(value) => {
                                answer = lua.from_value::<serde_json::Value>(value).map(Some);
                                break;
                            }
                            Err(error) => {
                                answer = Err(error);
                                break;
                            }
                        }
                    }
                    let result = answer.as_ref().ok().cloned().flatten().unwrap_or(fallback);
                    runtime.borrow_mut().lsp.reply(&key, id, result);
                    answer.map(|_| ())
                }
                Request::Lsp(super::lsp::Delivery::Root {
                    function,
                    document,
                    path,
                }) => {
                    // It answers by returning a directory, or false for
                    // none, or later through `done`.
                    let id = document.number();
                    let done = lua.create_function(move |lua, root: Value| {
                        let soda: Table = lua.globals().get("soda")?;
                        let lsp: Table = soda.get("lsp")?;
                        lsp.get::<Function>("set_root")?.call::<()>((id, root))
                    })?;
                    let call = self.callbacks()?.get::<Function>(function)?;
                    let path = path.to_string_lossy().into_owned();
                    match call.call::<Value>((path, done.clone())) {
                        Ok(Value::Nil) => Ok(()),
                        Ok(root) => done.call::<()>(root),
                        Err(error) => {
                            // A failing function leaves the document its project.
                            let _ = done.call::<()>(Value::Boolean(false));
                            Err(error)
                        }
                    }
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
pub(super) fn to_lua(lua: &Lua, value: &serde_json::Value) -> mlua::Result<Value> {
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
    if let Some(doc) = table.get("doc")? {
        item.doc = doc;
    }
    if let Some(commit) = table.get::<Option<String>>("commit")? {
        item.commit = commit.chars().collect();
    }
    item.ahead = [table.get("insert")?, table.get("replace")?];
    item.key = table.get("key")?;
    if let Some(snippet) = snippet {
        item.text = snippet;
        item.snippet = true;
    }
    // `{ {line, column}, {line, column}, text }` as `buffer:edit` takes them.
    if let Some(edits) = table.get::<Option<Table>>("edits")? {
        let place = |point: Table| -> mlua::Result<(usize, usize)> {
            let line: usize = point.get(1)?;
            let column: usize = point.get(2)?;
            if line == 0 || column == 0 {
                return Err(mlua::Error::runtime("lines and columns count from 1"));
            }
            Ok((line - 1, column - 1))
        };
        for edit in edits.sequence_values::<Table>() {
            let edit = edit?;
            item.edits.push(crate::interaction::completion::Extra {
                from: place(edit.get(1)?)?,
                to: place(edit.get(2)?)?,
                text: edit.get(3)?,
            });
        }
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
/// What a process sent, with the view it started in.
pub(super) type Sent = (Message, Option<crate::application::ViewId>);
pub(super) type Children = std::sync::Arc<std::sync::Mutex<std::collections::HashMap<u64, Child>>>;
#[derive(Clone, Copy)]
pub(super) enum Child {
    Starting,
    /// `soda.kill` came before it started.
    Killed,
    Running(u32),
}
/// How `soda.spawn` runs a program.
pub(super) struct Spawn {
    pub argv: Vec<String>,
    pub cwd: std::path::PathBuf,
    pub env: Vec<(String, String)>,
    pub input: Option<String>,
    /// Functions that take each line of standard output and standard error
    /// as it comes; without one, the stream goes to the function at the end.
    pub lines: [Option<u64>; 2],
}
/// What a `soda.spawn` process sends, in the order it happens.
pub(super) enum Message {
    Line { function: u64, text: String },
    Done(Job),
}
/// Runs a program to its end in its own process group, which `soda.kill`
/// stops; streamed lines go out as they come, before the end.
fn spawn(
    id: u64,
    spawn: Spawn,
    sender: &Sender<Sent>,
    view: Option<crate::application::ViewId>,
    children: &Children,
) -> Job {
    use std::{
        io::{BufRead, Read, Write},
        process::Stdio,
    };
    let mut command = std::process::Command::new(&spawn.argv[0]);
    command
        .args(&spawn.argv[1..])
        .current_dir(&spawn.cwd)
        .envs(spawn.env.iter().map(|(k, v)| (k, v)))
        .stdin(if spawn.input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut command, 0);
    let failed = |error: std::io::Error| Job {
        id,
        code: None,
        stdout: String::new(),
        stderr: format!("{}: {error}", spawn.argv[0]),
        lines: spawn.lines.iter().flatten().copied().collect(),
    };
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            children.lock().unwrap().remove(&id);
            return failed(error);
        }
    };
    {
        let mut children = children.lock().unwrap();
        if matches!(children.get(&id), Some(Child::Killed)) {
            crate::runtime::process::terminate(child.id());
        }
        children.insert(id, Child::Running(child.id()));
    }
    if let (Some(input), Some(mut stdin)) = (spawn.input, child.stdin.take()) {
        // Written on its own thread, so a process that writes a lot before
        // it reads cannot hold both sides.
        std::thread::spawn(move || {
            // A process that exits without reading is not an error here.
            let _ = stdin.write_all(input.as_bytes());
        });
    }
    let readers: Vec<_> = [
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .zip(spawn.lines)
    .map(|(stream, function)| {
        let sender = sender.clone();
        std::thread::spawn(move || {
            let mut kept = String::new();
            let Some(stream) = stream else {
                return kept;
            };
            let mut reader = std::io::BufReader::new(stream);
            match function {
                Some(function) => {
                    let mut line = Vec::new();
                    while reader.read_until(b'\n', &mut line).is_ok_and(|n| n > 0) {
                        let text = String::from_utf8_lossy(&line);
                        let text = text.trim_end_matches(['\n', '\r']).to_owned();
                        let _ = sender.send((Message::Line { function, text }, view));
                        crate::wake::wake();
                        line.clear();
                    }
                }
                None => {
                    let mut bytes = Vec::new();
                    let _ = reader.read_to_end(&mut bytes);
                    kept = String::from_utf8_lossy(&bytes).into_owned();
                }
            }
            kept
        })
    })
    .collect();
    let mut streams = readers
        .into_iter()
        .map(|reader| reader.join().unwrap_or_default());
    let (stdout, stderr) = (streams.next().unwrap(), streams.next().unwrap());
    let status = child.wait();
    children.lock().unwrap().remove(&id);
    match status {
        Ok(status) => Job {
            id,
            code: status.code(),
            stdout,
            stderr,
            lines: spawn.lines.iter().flatten().copied().collect(),
        },
        Err(error) => failed(error),
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
    /// Asks a source about the selected candidate.
    pub(super) fn resolve_candidate(&mut self, resolve: crate::interaction::completion::Resolve) {
        let request = Request::Resolve {
            function: resolve.function,
            source: resolve.source,
            key: resolve.key,
        };
        self.lua_queue.push_back((request, Some(resolve.view)));
        self.run_lua();
    }
    /// Collects finished processes and calls their functions.
    pub(super) fn poll_lua(&mut self) {
        self.forget_closed_trees();
        let Some(host) = &self.lua else {
            return;
        };
        let answers: Vec<_> = host.answers.1.try_iter().collect();
        for answer in answers {
            self.dirty |= match answer {
                Answer::Items {
                    generation,
                    source,
                    items,
                    incomplete,
                } => self
                    .layers
                    .completion_results(generation, source, items, incomplete, &self.app),
                Answer::Resolved {
                    source,
                    key,
                    detail,
                    doc,
                } => self.layers.completion_resolved(source, key, detail, doc),
                Answer::Candidates { token, items } => {
                    let response = self.layers.candidates_listed(token, items, &self.app);
                    self.respond(response, self.epoch.elapsed());
                    true
                }
            };
        }
        let Some(host) = &self.lua else {
            return;
        };
        let done: Vec<_> = host
            .jobs
            .1
            .try_iter()
            .map(|(message, view)| {
                let request = match message {
                    Message::Line { function, text } => Request::Line { function, text },
                    Message::Done(job) => Request::Done(job),
                };
                (request, view)
            })
            .collect();
        let now = std::time::Instant::now();
        let due: Vec<_> = {
            let mut timers = host.timers.borrow_mut();
            let (due, waiting) = timers.drain(..).partition(|(at, ..)| *at <= now);
            *timers = waiting;
            due
        };
        let due = due
            .into_iter()
            .map(|(_, id, view): (_, u64, _)| (Request::Timer(id), view));
        let mut done = done;
        done.extend(due);
        if !done.is_empty() {
            self.lua_queue.extend(done);
            self.run_lua();
        }
    }
    /// Starts servers, sends edits and takes what servers said.
    pub(super) fn poll_lsp(&mut self) {
        let failure = self.lsp.sync(&self.app, false);
        let (deliveries, closed) = self.lsp.poll();
        // A server that went away starts again at the next sync; nothing
        // else may come to make one.
        let failure = match closed.is_some() {
            true => failure.or(self.lsp.sync(&self.app, false)),
            false => failure,
        };
        if let Some(error) = failure.or(closed) {
            self.report(error);
        }
        // The status line names them.
        if self.layers.set_servers(self.lsp.serving()) {
            self.dirty = true;
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
        self.lsp_key_of(self.document().ok()?)
    }
    /// The server of a document: its language and root.
    fn lsp_key_of(&self, document: crate::editor::DocumentId) -> Option<super::lsp::Key> {
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
