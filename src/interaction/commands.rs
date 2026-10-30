//! Application command reduction. Commands resolve their targets on the owner
//! thread and return ordered application events and platform effects.
use super::{
    CommandLine, HelpSession, Layer, Layers, Message, ReplaceSession, Response, SaveWait,
    SearchSession, TextInput, expand, registry::holds_commands,
};
use crate::{
    application::{Application, Axis, ClipboardAction, Direction, Event},
    core::EditError,
    editor::{Command as EditCommand, DocumentId, Language},
};
use std::{path::Path, time::Duration};

/// Commands shared by keyboard bindings and other invocation surfaces.
/// Targets are resolved against the current application state at invocation.
#[derive(Clone, Debug)]
pub enum Command {
    Edit(EditCommand),
    SetMode(super::EditMode),
    Vim(super::vim::VimCommand),
    /// Open the command line with initial text.
    Ex(String),
    /// Open the command line with a note on what it asks about.
    Ask {
        line: String,
        note: String,
    },
    /// A command line resolved through the registry when executed.
    Named(String),
    Line {
        edit: super::LineEdit,
        extend: bool,
    },
    Map {
        context: super::Context,
        keys: Vec<super::KeyStroke>,
        target: String,
    },
    Unmap {
        context: super::Context,
        keys: Vec<super::KeyStroke>,
    },
    Define {
        name: String,
        body: String,
    },
    Hook {
        event: &'static str,
        filter: String,
        command: String,
    },
    Unhook {
        event: &'static str,
        filter: Option<String>,
    },
    Pipe(String),
    Shell(String),
    Nop,
    OpenPath(std::path::PathBuf),
    /// Switch to the open document with this buffer name.
    Buffer(String),
    SavePath(std::path::PathBuf),
    WriteQuit,
    Clipboard(ClipboardAction),
    Page {
        backward: bool,
        extend: bool,
    },
    New,
    Close(Option<Departure>),
    Reload(Option<Departure>),
    Help,
    Save {
        choose_path: bool,
    },
    Quit(Option<Departure>),
    NextView,
    Window(WindowCommand),
    /// Searches the project; results go to the `*grep*` document.
    Grep(String),
    /// Opens the location on the caret line, or moves to the next line's
    /// first non-blank as Vim's Enter does.
    Jump,
    /// Opens the next or previous location in the latest results: search
    /// matches or `run` output.
    ResultStep {
        backward: bool,
    },
    /// Runs a command whose output streams into the `*run*` document.
    Run(String),
    /// Stops background work: the run, the shell command and the search.
    Stop,
    /// Hands the terminal back to the shell until the editor is resumed.
    Suspend,
    /// Runs Lua code.
    Lua(String),
    /// Calls a Lua function registered under an id, with one argument.
    LuaCall {
        id: u64,
        argument: String,
    },
    /// Looks for open files changed on disk: reloads those without unsaved
    /// edits and reports the rest.
    CheckFiles,
    /// Shows a message.
    Echo(String),
    /// Moves to one of the places two typed characters occur on screen.
    JumpTo,
    /// Highlights a pattern everywhere, or in the current document.
    Highlight {
        local: bool,
        face: Option<crate::application::Face>,
        pattern: regex::Regex,
    },
    /// Removes the highlights of a pattern, or all of them.
    Unhighlight(Option<String>),
    /// Flags zero-based lines of the current document in a group.
    FlagLines {
        group: String,
        flag: crate::application::Flag,
        lines: Vec<usize>,
    },
    /// Removes a group's flags, or all, from the current document.
    UnflagLines(Option<String>),
    /// Replays keys in Normal mode from the start of each selected line,
    /// or of the caret's line.
    EachLine(Vec<super::KeyStroke>),
    /// Replays keys in Normal mode from each match of a pattern in the
    /// selected lines, or in the whole document.
    EachMatch {
        pattern: regex::Regex,
        keys: Vec<super::KeyStroke>,
    },
    /// Routes keys as if typed, for `each-line` and `each-match`.
    Replay(Vec<super::KeyStroke>),
    /// Focuses a window chosen by its label.
    WindowPick,
    /// Shows recent messages in `*messages*`.
    Messages,
    /// Sets an option globally, or for the current document.
    SetOption {
        local: bool,
        name: &'static str,
        value: crate::options::Value,
    },
    /// Drops the current document's own value of an option.
    UnsetOption(&'static str),
    /// Sets where documents of a kind are shown.
    Display {
        kind: String,
        placement: crate::application::Placement,
    },
    Search,
    Replace,
}
#[derive(Clone, Debug)]
pub enum WindowCommand {
    /// Splits the active window, then opens a file in the new one if given.
    Split(Axis, Option<std::path::PathBuf>),
    Close,
    Only,
    Focus(Direction),
    Cycle {
        backward: bool,
    },
}
/// The outcome of configuration text, by one-based line number.
pub struct Sourced {
    pub errors: Vec<(usize, String)>,
    /// Settings the application keeps, to be executed in order.
    pub settings: Vec<(usize, Command)>,
}
/// How `close`, `reload` and `quit` treat a document with unsaved changes.
/// Without one, they ask through the command line.
#[derive(Clone, Debug)]
pub enum Departure {
    Save(Option<std::path::PathBuf>),
    Discard,
}

fn check_files(app: &Application, file_root: &Path, response: &mut Response) {
    // Focus comes back often; the message stays unless something changed.
    response.message = Message::Keep;
    response.redraw = false;
    let workspace = app.workspace();
    let mut changed = vec![];
    for document in workspace.documents() {
        if workspace.is_saving(document)
            || !workspace.externally_modified(document).unwrap_or(false)
        {
            continue;
        }
        let path = workspace.file(document).unwrap().path().unwrap();
        let name = path.strip_prefix(file_root).unwrap_or(path).display();
        let view = app.views().find(|view| view.document_id == document);
        if !path.exists() {
            changed.push(format!("{name} was deleted"));
        } else if let Some(view) = view.filter(|_| {
            !workspace.is_dirty(document) && app.options().bool(Some(document), "auto-reload")
        }) {
            response.events.push(Event::Reload {
                view: view.id,
                discard: false,
            });
        } else {
            changed.push(format!("{name} changed on disk"));
        }
    }
    // After the reloads, whose own messages it would otherwise lose to.
    if !changed.is_empty() {
        response.commands.push(Command::Echo(changed.join("; ")));
        response.redraw = true;
    }
}
impl Layers {
    /// Applies a configuration command: `map`, `unmap` or `define-command`.
    pub fn configure(&mut self, command: Command) -> Result<(), String> {
        self.sequence.clear();
        self.vim.clear();
        match command {
            Command::Map {
                context: super::Context::Prompt,
                keys,
                target,
            } => {
                let input = super::keymap::prompt_action(target.trim())
                    .ok_or_else(|| format!("unknown prompt action: {target}"))?;
                let [key] = keys[..] else {
                    return Err("prompt bindings use a single key".into());
                };
                self.keymap
                    .bind_input(key, input, target)
                    .map_err(|e| e.to_string())
            }
            Command::Map {
                context,
                keys,
                target,
            } => {
                if !self.registry.knows(&target) {
                    return Err(format!("unknown command: {target}"));
                }
                self.keymap
                    .bind(context, &keys, Command::Named(target.clone()), target)
                    .map_err(|e| e.to_string())
            }
            Command::Unmap { context, keys } => self
                .keymap
                .unbind(context, &keys)
                .map_err(|e| e.to_string()),
            Command::Define { name, body } => self.registry.define(name, body),
            Command::Hook {
                event,
                filter,
                command,
            } => {
                if !self.registry.knows(&command) {
                    return Err(format!("unknown command: {command}"));
                }
                self.hooks
                    .add(super::hooks::Hook::new(event, &filter, command)?);
                Ok(())
            }
            Command::Unhook { event, filter } => {
                match self.hooks.remove(event, filter.as_deref()) {
                    0 => Err(format!("no {event} hook to remove")),
                    _ => Ok(()),
                }
            }
            _ => Err(
                "only map, unmap, define-command, hook, unhook, set, display and highlight are allowed here"
                    .into(),
            ),
        }
    }
    /// Applies configuration text line by line. Failed lines are skipped and
    /// reported with their one-based line numbers. Settings that live in the
    /// application (`set`, `display`) come back to be executed, with their
    /// line numbers.
    pub fn source(&mut self, text: &str) -> Sourced {
        let mut errors = vec![];
        let mut settings = vec![];
        for (index, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let result = self
                .registry
                .parse_builtin(line)
                .and_then(|command| match command {
                    Command::SetOption { local: false, .. }
                    | Command::Display { .. }
                    | Command::Highlight { local: false, .. } => {
                        settings.push((index + 1, command));
                        Ok(())
                    }
                    command => self.configure(command),
                });
            if let Err(error) = result {
                errors.push((index + 1, error));
            }
        }
        Sourced { errors, settings }
    }
    pub fn set_page_rows(&mut self, rows: usize) {
        self.page_rows = rows;
    }
    /// Invoke a command independently of key bindings. Invocation is blocked
    /// while a modal layer owns focus; confirmation uses that layer's contract.
    pub fn execute(
        &mut self,
        command: Command,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<super::InputResult, EditError> {
        if self.active().is_some() {
            return Ok(super::InputResult::Blocked);
        }
        self.sequence.clear();
        self.vim.clear();
        let register = self.vim.armed.take();
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        let opening_path = matches!(command, Command::OpenPath(_));
        match command {
            Command::SetMode(mode) => {
                if matches!(mode, super::EditMode::Visual | super::EditMode::VisualLine) {
                    if self.mode == mode {
                        return Ok(super::InputResult::Handled(response));
                    }
                    return self.execute(
                        Command::Vim(super::vim::VimCommand::Visual {
                            linewise: mode == super::EditMode::VisualLine,
                        }),
                        app,
                        time,
                        file_root,
                    );
                }
                let caret = self.vim.caret();
                self.vim.reset();
                self.mode = mode;
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let selection = app
                        .workspace()
                        .editor(view.document_id)
                        .unwrap()
                        .model()
                        .session(view.session_id)
                        .unwrap()
                        .selection();
                    response.events.push(Event::Edit {
                        view: view.id,
                        command: EditCommand::SetSelection(
                            caret.map_or(selection, crate::core::Selection::caret),
                        ),
                        time,
                    });
                }
            }
            Command::Vim(super::vim::VimCommand::Search { backward }) => {
                if let Some(view) = app.active_view() {
                    let mut session = SearchSession::new(app, view)?;
                    session.set_direction(backward, self.vim.last_search.clone());
                    response = self.enter(
                        Layer::Search {
                            input: TextInput::default(),
                            session,
                        },
                        app,
                        time,
                    )?;
                }
            }
            Command::Vim(command) => response = self.vim_execute(command, register, app, time),
            Command::Ex(_) | Command::Ask { .. } => {
                let (text, note) = match command {
                    Command::Ask { line, note } => (line, Some(note)),
                    Command::Ex(text) => (text, None),
                    _ => unreachable!(),
                };
                let mut line =
                    CommandLine::new(&text, self.registry.commands(), file_root.to_owned(), app)
                        .with_recent(self.recent_files.clone());
                if let Some(note) = note {
                    line = line.with_note(note);
                }
                response = self.enter(Layer::CommandLine(Box::new(line)), app, time)?;
                if let Some(Layer::CommandLine(line)) = &mut self.active {
                    let first = line.refresh(app, true);
                    response.effects.extend(first.effects);
                    response.path_requests.extend(first.path_requests);
                }
            }
            Command::Buffer(name) => {
                let name = name.trim();
                match app
                    .workspace()
                    .documents()
                    .find(|id| super::command_line::buffer_name(app, *id) == name)
                {
                    Some(document) => response.events.push(show(app, document)),
                    None => response.message = Message::Set(format!("No buffer named {name}")),
                }
            }
            Command::Named(line) => {
                let line = if holds_commands(&line) || !expand::has_expansions(&line) {
                    line
                } else {
                    match expand::expand(&line, &self.expansion(app, file_root)) {
                        Ok(line) => line,
                        Err(error) => {
                            response.message = Message::Set(error);
                            response.failed = true;
                            return Ok(super::InputResult::Handled(response));
                        }
                    }
                };
                if let Some(handler) = self.registry.handler(line.trim()) {
                    let command = handler(app)?;
                    if matches!(command, Command::Named(_)) {
                        response.message = Message::Set(
                            "Registered commands cannot recursively dispatch named commands".into(),
                        );
                    } else {
                        return self.execute(command, app, time, file_root);
                    }
                } else {
                    match self.registry.expand(&line) {
                        Ok(mut commands) if commands.len() == 1 => {
                            return self.execute(commands.pop().unwrap(), app, time, file_root);
                        }
                        Ok(commands) => response.commands = commands,
                        Err(error) => {
                            response.message = Message::Set(error);
                            response.failed = true;
                        }
                    }
                }
            }
            Command::Line { edit, extend } => {
                return self.execute(edit.command(extend), app, time, file_root);
            }
            Command::Map { .. }
            | Command::Unmap { .. }
            | Command::Define { .. }
            | Command::Hook { .. }
            | Command::Unhook { .. } => {
                if let Err(error) = self.configure(command) {
                    response.message = Message::Set(error);
                    response.failed = true;
                }
            }
            Command::Pipe(shell) => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    response.shell =
                        Some(Box::new(super::shell::pipe(app, view, shell, file_root)));
                }
            }
            Command::Shell(shell) => {
                let view = app.active_view().and_then(|id| app.view(id));
                response.shell = Some(Box::new(super::shell::run(app, view, shell, file_root)));
            }
            Command::Nop => {}
            Command::OpenPath(path) | Command::SavePath(path) => {
                let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
                match super::path::resolve_path(file_root, home.as_deref(), &path) {
                    Ok(path) => {
                        if opening_path {
                            response.events.push(Event::Open(path));
                        } else if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                            response.events.push(Event::Save {
                                document: view.document_id,
                                target: Some(path),
                            });
                        }
                    }
                    Err(error) => {
                        response.message = Message::Set(error);
                        response.failed = true;
                    }
                }
            }
            Command::WriteQuit => {
                let dirty = app
                    .active_view()
                    .and_then(|id| app.view(id))
                    .is_some_and(|view| app.workspace().is_dirty(view.document_id));
                let decision = dirty.then_some(Departure::Save(None));
                return self.execute(Command::Quit(decision), app, time, file_root);
            }
            Command::Help => {
                response = self.enter(
                    Layer::Help(HelpSession::new(super::help::text(
                        &self.keymap,
                        &self.registry,
                    ))),
                    app,
                    time,
                )?
            }
            Command::Page { backward, extend } => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let count = self.page_rows.saturating_sub(1).max(1);
                    let snapshot = app
                        .workspace()
                        .editor(view.document_id)
                        .unwrap()
                        .model()
                        .document()
                        .snapshot();
                    let top = snapshot.line_of(view.viewport.anchor.offset.0).unwrap();
                    let top = if backward {
                        top.saturating_sub(count)
                    } else {
                        top.saturating_add(count)
                            .min(snapshot.text_lines().saturating_sub(self.page_rows.max(1)))
                    };
                    response.events.push(Event::Edit {
                        view: view.id,
                        command: EditCommand::Move {
                            motion: crate::editor::Motion::Lines { backward, count },
                            extend,
                        },
                        time,
                    });
                    response.events.push(Event::SetViewport {
                        view: view.id,
                        anchor: crate::core::ByteOffset(snapshot.line_start(top).unwrap()),
                        horizontal_column: view.viewport.horizontal_column,
                    });
                }
            }
            Command::Replace => {
                if let Some(view) = app.active_view() {
                    response =
                        self.enter(Layer::Replace(ReplaceSession::new(app, view)?), app, time)?;
                }
            }
            Command::Search => {
                if let Some(view) = app.active_view() {
                    response = self.enter(
                        Layer::Search {
                            input: TextInput::default(),
                            session: SearchSession::new(app, view)?,
                        },
                        app,
                        time,
                    )?;
                }
            }
            Command::Clipboard(action) => {
                if let Some(view) = app.active_view() {
                    response
                        .events
                        .push(Event::Clipboard { view, action, time });
                }
            }
            Command::Edit(command) => {
                if let Some(view) = app.active_view() {
                    response.events.push(Event::Edit {
                        view,
                        command,
                        time,
                    });
                }
            }
            Command::New => response
                .events
                .push(Event::NewDocument(Language::PlainText)),
            Command::Close(decision) => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let document = view.document_id;
                    if app.workspace().is_dirty(document) && !app.workspace().is_saving(document) {
                        return self.depart("close", document, decision, app, time, file_root);
                    }
                    response = self.leave(document, false, app);
                }
            }
            Command::Reload(decision) => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let document = view.document_id;
                    if app.workspace().file(document).unwrap().path().is_none() {
                        response.message =
                            Message::Set("Untitled document has no file to reload".into());
                    } else if app.workspace().is_dirty(document)
                        && !app.workspace().is_saving(document)
                    {
                        return self.depart("reload", document, decision, app, time, file_root);
                    } else {
                        response = self.leave(document, true, app);
                    }
                }
            }
            Command::Save { choose_path } => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let document = view.document_id;
                    let path = app.workspace().file(document).unwrap().path();
                    if choose_path || path.is_none() {
                        let text = path.map_or_else(String::new, |p| {
                            p.strip_prefix(file_root).unwrap_or(p).display().to_string()
                        });
                        return self.execute(
                            Command::Ex(format!("saveas {text}")),
                            app,
                            time,
                            file_root,
                        );
                    } else {
                        response.events.push(Event::Save {
                            document,
                            target: None,
                        });
                    }
                }
            }
            Command::Quit(decision) => {
                let active = app
                    .active_view()
                    .and_then(|id| app.view(id))
                    .map(|view| view.document_id);
                let dirty = active
                    .filter(|id| app.workspace().is_dirty(*id))
                    .or_else(|| {
                        app.workspace()
                            .documents()
                            .find(|id| app.workspace().is_dirty(*id))
                    });
                if app
                    .workspace()
                    .documents()
                    .any(|id| app.workspace().is_saving(id))
                {
                    response.message =
                        Message::Set("Save in progress; quit after it completes".into());
                } else if let Some(document) = dirty {
                    return self.depart("quit", document, decision, app, time, file_root);
                } else {
                    response.quit = true;
                }
            }
            Command::Grep(pattern) => {
                self.results = super::grep::SCRATCH;
                response.grep = Some(Box::new(super::grep::GrepRequest {
                    pattern,
                    root: file_root.to_owned(),
                }));
            }
            Command::Jump => {
                if !super::grep::jump(app, file_root, &mut response) {
                    use super::vim::{Motion, VimCommand};
                    response.commands.extend([
                        Command::Vim(VimCommand::Move(Motion::Down, 1)),
                        Command::Vim(VimCommand::Move(Motion::First, 1)),
                    ]);
                }
            }
            Command::ResultStep { backward } => {
                super::grep::step(app, self.results, file_root, backward, time, &mut response)
            }
            Command::Run(shell) => {
                self.results = super::grep::RUN;
                let view = app.active_view().and_then(|id| app.view(id));
                response.run = Some(Box::new(super::shell::run(app, view, shell, file_root)));
            }
            Command::Stop => response.stop = true,
            Command::Suspend => response.suspend = true,
            Command::Lua(code) => response.lua.push(super::LuaRequest::Chunk {
                origin: "lua".into(),
                code,
            }),
            Command::LuaCall { id, argument } => {
                response.lua.push(super::LuaRequest::Call { id, argument })
            }
            Command::Messages => response.messages = true,
            Command::Echo(text) => response.message = Message::Set(text),
            Command::Highlight {
                local,
                face,
                pattern,
            } => {
                let document = app
                    .active_view()
                    .and_then(|id| app.view(id))
                    .map(|view| view.document_id);
                if local && document.is_none() {
                    response.message = Message::Set("No document to highlight in".into());
                } else {
                    response.events.push(Event::Highlight {
                        document: document.filter(|_| local),
                        face,
                        pattern,
                    });
                }
            }
            Command::Unhighlight(pattern) => {
                let document = app
                    .active_view()
                    .and_then(|id| app.view(id))
                    .map(|view| view.document_id);
                response
                    .events
                    .push(Event::Unhighlight { document, pattern });
            }
            Command::FlagLines { group, flag, lines } => {
                match app.active_view().and_then(|id| app.view(id)) {
                    Some(view) => response.events.push(Event::Flag {
                        document: view.document_id,
                        group,
                        flag,
                        lines,
                    }),
                    None => response.message = Message::Set("No document to flag".into()),
                }
            }
            Command::UnflagLines(group) => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    response.events.push(Event::Unflag {
                        document: view.document_id,
                        group,
                    });
                }
            }
            Command::EachLine(_) | Command::EachMatch { .. } => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    response.commands = self.each(app, view, command);
                }
            }
            Command::Replay(keys) => {
                response.replay = keys.into_iter().map(super::UserInput::Key).collect();
            }
            Command::JumpTo => {
                if let Some(view) = app.active_view() {
                    let session = super::labels::LabelSession::jump(view, self.page_rows);
                    response = self.enter(Layer::Labels(session), app, time)?;
                }
            }
            Command::WindowPick => match super::labels::LabelSession::windows(app) {
                Ok(session) => response = self.enter(Layer::Labels(session), app, time)?,
                Err(Some(other)) => response.events.push(Event::Focus(other)),
                Err(None) => {}
            },
            Command::CheckFiles => {
                // Unlike other commands, an empty check keeps the message.
                check_files(app, file_root, &mut response);
                return Ok(super::InputResult::Handled(response));
            }
            Command::SetOption { local, name, value } => {
                let document = app
                    .active_view()
                    .and_then(|id| app.view(id))
                    .map(|view| view.document_id);
                let scope = match (local, document) {
                    (false, _) => Some(crate::options::Scope::Global),
                    (true, Some(document)) => Some(crate::options::Scope::Document(document)),
                    (true, None) => None,
                };
                match scope {
                    Some(scope) => response
                        .events
                        .push(Event::SetOption { scope, name, value }),
                    None => response.message = Message::Set("No document to set it for".into()),
                }
            }
            Command::UnsetOption(name) => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    response.events.push(Event::UnsetOption {
                        document: view.document_id,
                        name,
                    });
                }
            }
            Command::Display { kind, placement } => {
                response.events.push(Event::SetDisplay { kind, placement })
            }
            Command::Window(command) => {
                let Some(active) = app.active_view() else {
                    return Ok(super::InputResult::Handled(response));
                };
                response.events.push(match command {
                    WindowCommand::Split(axis, path) => {
                        response.commands.extend(path.map(Command::OpenPath));
                        Event::Split(axis)
                    }
                    WindowCommand::Close => Event::CloseWindow(active),
                    WindowCommand::Only => Event::OnlyWindow(active),
                    WindowCommand::Focus(direction) => Event::FocusWindow(direction),
                    WindowCommand::Cycle { backward } => Event::CycleWindow { backward },
                });
            }
            Command::NextView => {
                // Views shown in other windows stay where they are.
                let ids: Vec<_> = app
                    .views()
                    .map(|v| v.id)
                    .filter(|id| Some(*id) == app.active_view() || !app.windows().contains(*id))
                    .collect();
                if let Some(index) = app
                    .active_view()
                    .and_then(|active| ids.iter().position(|id| *id == active))
                {
                    response
                        .events
                        .push(Event::Focus(ids[(index + 1) % ids.len()]));
                }
            }
        }
        if matches!(response.message, Message::Keep) {
            response.message = Message::Clear;
        }
        Ok(super::InputResult::Handled(response))
    }
}
impl Layers {
    /// The commands that replay keys at each target, bottom first so that
    /// edits leave the targets above in place, then merge the edits into one
    /// undo step.
    fn each(
        &self,
        app: &Application,
        view: &crate::application::View,
        command: Command,
    ) -> Vec<Command> {
        use super::EditMode;
        let editor = app.workspace().editor(view.document_id).unwrap();
        let document = editor.model().document();
        let snapshot = document.snapshot();
        let selection = editor.model().session(view.session_id).unwrap().selection();
        // Visual mode covers its lines even when anchor and head meet.
        let range = match (self.mode, self.vim.visual) {
            (EditMode::Visual | EditMode::VisualLine, Some((anchor, head))) => {
                Some(anchor.min(head)..anchor.max(head))
            }
            _ => Some(selection.range()).filter(|range| !range.is_empty()),
        };
        let lines = range.map(|range| {
            snapshot.line_of(range.start).unwrap()..=snapshot.line_of(range.end).unwrap()
        });
        let (targets, keys): (Vec<usize>, _) = match command {
            Command::EachLine(keys) => {
                let caret = snapshot.line_of(selection.head).unwrap();
                let lines = lines.unwrap_or(caret..=caret);
                (
                    lines
                        .map(|line| snapshot.line_start(line).unwrap())
                        .collect(),
                    keys,
                )
            }
            Command::EachMatch { pattern, keys } => {
                let lines = lines.unwrap_or(0..=snapshot.text_lines() - 1);
                let mut targets = vec![];
                for line in lines {
                    let start = snapshot.line_start(line).unwrap();
                    let text = snapshot.line(line).unwrap_or_default();
                    targets.extend(pattern.find_iter(&text).map(|m| start + m.start()));
                }
                (targets, keys)
            }
            _ => unreachable!(),
        };
        let mut commands = vec![];
        for target in targets.into_iter().rev().take(10_000) {
            commands.extend([
                Command::SetMode(EditMode::Normal),
                Command::Edit(EditCommand::SetSelection(crate::core::Selection::caret(
                    target,
                ))),
                Command::Replay(keys.clone()),
            ]);
        }
        commands.extend([
            Command::SetMode(EditMode::Normal),
            Command::Edit(EditCommand::SquashHistory(document.history_depth())),
        ]);
        commands
    }
    /// Closes or reloads a document that needs no decision.
    fn leave(&self, document: DocumentId, reload: bool, app: &Application) -> Response {
        let mut response = Response {
            redraw: true,
            ..Response::default()
        };
        if app.workspace().is_saving(document) {
            response.message =
                Message::Set("Save in progress; wait before leaving document".into());
        } else if reload {
            let view = app.active_view().unwrap();
            response.events.push(Event::Reload {
                view,
                discard: false,
            });
        } else {
            response.events.push(Event::CloseDocument {
                document,
                discard: false,
            });
        }
        response
    }
    /// Leaves a dirty document by the decision, asking for one through the
    /// command line when there is none. Each step is a command line; nothing
    /// nests.
    fn depart(
        &mut self,
        action: &str,
        document: DocumentId,
        decision: Option<Departure>,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<super::InputResult, EditError> {
        let name = super::command_line::buffer_name(app, document);
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        match decision {
            None => {
                let ask = Command::Ask {
                    line: format!("{action} "),
                    note: format!("unsaved {name}"),
                };
                return self.execute(ask, app, time, file_root);
            }
            Some(Departure::Discard) => {
                if action == "reload" {
                    response.events.push(Event::Reload {
                        view: app.active_view().unwrap(),
                        discard: true,
                    });
                } else {
                    response.events.push(Event::CloseDocument {
                        document,
                        discard: true,
                    });
                }
                // Quitting continues with the next unsaved document.
                if action == "quit" {
                    response.commands.push(Command::Named("quit".into()));
                }
            }
            Some(Departure::Save(None))
                if app.workspace().file(document).unwrap().path().is_none() =>
            {
                let ask = Command::Ask {
                    line: format!("{action} save "),
                    note: format!("{name} needs a PATH"),
                };
                return self.execute(ask, app, time, file_root);
            }
            Some(Departure::Save(path)) => {
                let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
                let target = match path {
                    Some(path) => {
                        match super::path::resolve_path(file_root, home.as_deref(), &path) {
                            Ok(target) => Some(target),
                            Err(error) => {
                                response.message = Message::Set(error);
                                return Ok(super::InputResult::Handled(response));
                            }
                        }
                    }
                    None => None,
                };
                let retry = target.as_ref().map_or_else(
                    || format!("{action} save"),
                    |target| {
                        let shown = target.strip_prefix(file_root).unwrap_or(target);
                        format!("{action} save {}", shown.display())
                    },
                );
                let wait = SaveWait::new(app, document, action.to_owned(), retry);
                response = self.enter(Layer::Saving(wait), app, time)?;
                response.events.push(Event::Save { document, target });
            }
        }
        Ok(super::InputResult::Handled(response))
    }
}

/// Shows a document in the active view's place: focuses a view of it, or
/// adds one.
pub(super) fn show(app: &Application, document: crate::editor::DocumentId) -> Event {
    let active = app
        .active_view()
        .and_then(|id| app.view(id))
        .filter(|v| v.document_id == document);
    let view = active.or_else(|| app.views().find(|v| v.document_id == document));
    view.map_or(Event::AddView(document), |v| Event::Focus(v.id))
}
