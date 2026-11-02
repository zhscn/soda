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
    Modal(super::modal::Action),
    /// Work the runtime does for the modal layer.
    Effect(Box<super::modal::Effect>),
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
    /// Reads the next keys through the keypad.
    Keypad(super::KeypadStart),
    Define {
        name: String,
        body: String,
        /// What help and key hints show; `None` shows the body.
        doc: Option<String>,
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
    /// first non-blank.
    Jump,
    /// Goes back to where the caret jumped from, or forward again.
    JumpBack,
    JumpForward,
    /// Opens the next or previous location in the latest results: search
    /// matches or `run` output.
    ResultStep {
        backward: bool,
    },
    /// Fills the `*KIND*` document with result lines for `]q` to step
    /// through; lines that name no location stay as headings.
    /// Opens a file named relative to the project.
    OpenProjectFile(std::path::PathBuf),
    /// Asks for a file, starting from the active document's directory.
    OpenPrompt,
    /// Shows the project, or makes a directory it.
    ProjectRoot(Option<std::path::PathBuf>),
    Results {
        kind: String,
        lines: Vec<String>,
    },
    /// Runs a command whose output streams into the `*run*` document.
    Run(String),
    /// Stops background work: the run, the shell command and the search.
    Stop,
    /// Hands the terminal back to the shell until the editor is resumed.
    Suspend,
    /// Asks which of the items; `Choose` answers with one of them, and the
    /// Lua function under `id` gets its number.
    Offer {
        id: u64,
        title: String,
        items: Vec<String>,
    },
    /// Answers `Offer` with an item, from one.
    Choose(usize),
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
    /// Fails with a message, which stops a macro.
    Fail(String),
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
    EachLine(Vec<super::UserInput>),
    /// Replays keys in Normal mode from each match of a pattern in the
    /// selected lines, or in the whole document.
    EachMatch {
        pattern: regex::Regex,
        keys: Vec<super::UserInput>,
    },
    /// Replays input in Normal mode from each of these offsets, last first,
    /// as one undo step.
    EachAt {
        targets: Vec<usize>,
        keys: Vec<super::UserInput>,
    },
    /// Routes input as if typed, for `each-line` and `each-match`.
    Replay(Vec<super::UserInput>),
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
    SearchBackward,
    Completion(super::completion::Action),
    /// Inserts a snippet at the caret.
    Snippet(String),
    SnippetStep {
        backward: bool,
    },
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
    /// Grows the window by cells along an axis, or shrinks it.
    Resize(Axis, i32),
    /// Makes splits equal and side windows their opening size.
    ResetSizes,
    /// Resizes step by step until Esc.
    ResizeMode,
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

/// Replays keys in Normal at each selection, last first so that earlier
/// places hold, as one undoable step.
pub(super) fn replay_each(
    selections: impl DoubleEndedIterator<Item = crate::core::Selection>,
    keys: &[super::UserInput],
    depth: usize,
) -> Vec<Command> {
    let mut commands = vec![];
    for selection in selections.rev() {
        commands.extend([
            Command::SetMode(super::EditMode::Normal),
            Command::Edit(EditCommand::SetSelection(selection)),
            Command::Replay(keys.to_vec()),
        ]);
    }
    commands.extend([
        Command::SetMode(super::EditMode::Normal),
        Command::Edit(EditCommand::SquashHistory(depth)),
    ]);
    commands
}
/// Reloads the active view's document, or closes `document`.
fn leaving(app: &Application, document: DocumentId, reload: bool, discard: bool) -> Event {
    if reload {
        Event::Reload {
            view: app.active_view().unwrap(),
            discard,
        }
    } else {
        Event::CloseDocument { document, discard }
    }
}
fn active(app: &Application) -> Option<&crate::application::View> {
    app.active_view().and_then(|id| app.view(id))
}
/// A path typed by the user, against the current directory and `~`.
fn resolve(app: &Application, path: &Path) -> Result<std::path::PathBuf, String> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    super::path::resolve_path(&app.directory(), home.as_deref(), path)
}
/// A directory as a path to start from: under `~` when it can be, and
/// ending in a slash so that a file name follows.
fn prompt_directory(directory: &Path) -> String {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    let shown = match home.and_then(|home| directory.strip_prefix(home).ok().map(Path::to_owned)) {
        Some(below) if below.as_os_str().is_empty() => "~".to_owned(),
        Some(below) => format!("~/{}", below.display()),
        None => directory.display().to_string(),
    };
    if shown.ends_with('/') {
        shown
    } else {
        shown + "/"
    }
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
        self.modal.clear();
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
            Command::Define { name, body, doc } => self.registry.define(name, body, doc),
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
    /// The rows of text each window shows.
    pub fn set_window_rows(&mut self, rows: Vec<(crate::application::ViewId, usize)>) {
        self.window_rows = rows;
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
        // The prefix argument waits for the keypad to give it a command.
        if !matches!(
            command,
            Command::Modal(_) | Command::Keypad(_) | Command::Named(_)
        ) {
            self.modal.clear();
        }
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        let opening_path = matches!(command, Command::OpenPath(_));
        self.jumps.clear_pending();
        // With a mark set, every move extends from it, as in Emacs.
        let marked = self.mode != super::EditMode::Insert
            && super::modal::execute_place(app)
                .and_then(|selection| self.modal.tag(selection))
                .is_some_and(|tag| tag.kind == super::modal::Kind::Char);
        let command = match command {
            Command::Edit(EditCommand::Move {
                motion,
                extend: false,
            }) if marked => Command::Edit(EditCommand::Move {
                motion,
                extend: true,
            }),
            Command::Line {
                edit,
                extend: false,
            } if marked && edit.is_motion() => Command::Line { edit, extend: true },
            command => command,
        };
        match &command {
            Command::ResultStep { .. } => self.jumps.expect_result(),
            Command::Modal(super::modal::Action::Found {
                kind: super::modal::Kind::Block,
                ..
            })
            | Command::Edit(EditCommand::Goto { .. })
            | Command::Edit(EditCommand::Move {
                motion: crate::editor::Motion::DocumentStart | crate::editor::Motion::DocumentEnd,
                ..
            }) => self.jumps.expect(),
            _ => {}
        }
        match command {
            Command::Keypad(start) => self.sequence.start(start),
            Command::JumpBack => match self.jumps.back(app) {
                Some(place) => go(app, place, time, &mut response),
                None => response.message = Message::Set("At the oldest jump".into()),
            },
            Command::JumpForward => match self.jumps.forward() {
                Some(place) => go(app, place, time, &mut response),
                None => response.message = Message::Set("At the newest jump".into()),
            },
            Command::SetMode(mode) => {
                self.modal.tag = None;
                if self.mode == super::EditMode::Beacon {
                    self.leave_beacon();
                }
                self.mode = mode;
            }
            Command::Modal(action) => response = self.modal_execute(action, app, time),
            Command::Fail(message) => {
                response = self.fail(response, &message);
                response.failed = true;
            }
            // Only the runtime can do these; it takes them from the response.
            effect @ Command::Effect(_) => response.commands.push(effect),
            Command::Ex(_) | Command::Ask { .. } => {
                let (text, note) = match command {
                    Command::Ask { line, note } => (line, Some(note)),
                    Command::Ex(text) => (text, None),
                    _ => unreachable!(),
                };
                let mut line = CommandLine::new(
                    &text,
                    self.registry.commands(),
                    file_root.to_owned(),
                    app.directory(),
                    app,
                )
                .with_recent(self.recent_files.clone())
                .with_items(self.offer.as_ref().map_or(vec![], |(_, i)| i.clone()));
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
                    .find(|id| app.document_name(*id) == name)
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
                if let Some(view) = active(app) {
                    let directory = app.directory();
                    response.shell =
                        Some(Box::new(super::shell::pipe(app, view, shell, &directory)));
                }
            }
            Command::Shell(shell) => {
                let view = active(app);
                let directory = app.directory();
                response.shell = Some(Box::new(super::shell::run(app, view, shell, &directory)));
            }
            Command::Nop => {}
            Command::OpenPrompt => {
                let line = format!("open {}", prompt_directory(&app.directory()));
                return self.execute(Command::Ex(line), app, time, file_root);
            }
            Command::ProjectRoot(None) => {
                response.message = Message::Set(match app.project() {
                    Some(project) => project.display().to_string(),
                    None => format!("No project; using {}", app.directory().display()),
                });
            }
            Command::ProjectRoot(Some(path)) => {
                match resolve(app, &path).and_then(|path| {
                    std::fs::canonicalize(&path)
                        .ok()
                        .filter(|path| path.is_dir())
                        .ok_or_else(|| format!("{} is not a directory", path.display()))
                }) {
                    Ok(directory) => {
                        response.message = Message::Set(format!("Project {}", directory.display()));
                        response.events.push(Event::SetProject(directory));
                    }
                    Err(error) => {
                        response.message = Message::Set(error);
                        response.failed = true;
                    }
                }
            }
            Command::OpenProjectFile(path) => {
                response.events.push(Event::Open(file_root.join(path)));
            }
            Command::OpenPath(path) | Command::SavePath(path) => {
                match resolve(app, &path) {
                    Ok(path) => {
                        if opening_path {
                            // Nothing on screen changes, so say why.
                            if let Some(document) = active(app).map(|v| v.document_id)
                                && let Some(current) =
                                    app.workspace().file(document).and_then(|f| f.path())
                                && std::fs::canonicalize(&path).is_ok_and(|p| p == current)
                            {
                                response.message = Message::Set(format!(
                                    "Already at {}",
                                    app.document_name(document)
                                ));
                            }
                            response.events.push(Event::Open(path));
                        } else if let Some(view) = active(app) {
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
                let dirty =
                    active(app).is_some_and(|view| app.workspace().is_dirty(view.document_id));
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
                if let Some(view) = active(app) {
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
                            .min(snapshot.line_count().saturating_sub(self.page_rows.max(1)))
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
            Command::SearchBackward | Command::Search => {
                if let Some(view) = app.active_view() {
                    let mut session = SearchSession::new(app, view)?;
                    session.set_direction(matches!(command, Command::SearchBackward));
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
            Command::Clipboard(action) => {
                if let Some(view) = app.active_view() {
                    response
                        .events
                        .push(Event::Clipboard { view, action, time });
                }
            }
            Command::Completion(action) => {
                use super::completion::Action;
                match action {
                    Action::Trigger => self.completion.trigger(),
                    Action::Dismiss => self.completion.dismiss(app),
                    Action::Move { backward } => self.completion.step(backward),
                    Action::Accept | Action::Replace => {
                        let replace = action == Action::Replace;
                        if let Some(accepted) = self.completion.accept(replace, app) {
                            self.accept(accepted, app, time, &mut response);
                        }
                    }
                }
            }
            Command::Snippet(body) => {
                if let Some(view) = app.active_view()
                    && let Some(session) = app.view(view)
                {
                    let editor = app.workspace().editor(session.document_id).unwrap();
                    let selection = editor
                        .model()
                        .session(session.session_id)
                        .unwrap()
                        .selection();
                    let range = selection.range();
                    self.expand_snippet(view, range, vec![], &body, app, time, &mut response);
                }
            }
            Command::SnippetStep { backward } => {
                if let Some((view, selection)) = self.snippet.step(backward) {
                    response.events.push(Event::Edit {
                        view,
                        command: EditCommand::SetSelection(selection),
                        time,
                    });
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
                if let Some(view) = active(app) {
                    let document = view.document_id;
                    if app.workspace().is_dirty(document) && !app.workspace().is_saving(document) {
                        return self.depart("close", document, decision, app, time, file_root);
                    }
                    response = self.leave(document, false, app);
                }
            }
            Command::Reload(decision) => {
                if let Some(view) = active(app) {
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
                if let Some(view) = active(app) {
                    let document = view.document_id;
                    let path = app.workspace().file(document).unwrap().path();
                    if choose_path || path.is_none() {
                        let text = path.map_or_else(String::new, |p| {
                            p.strip_prefix(app.directory())
                                .unwrap_or(p)
                                .display()
                                .to_string()
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
                let active = active(app).map(|view| view.document_id);
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
                self.set_results(super::grep::SCRATCH.to_owned());
                response.grep = Some(Box::new(super::grep::GrepRequest {
                    pattern,
                    root: file_root.to_owned(),
                }));
            }
            Command::Jump => {
                // Enter on the results visits that line, as `]q` would.
                let document = active(app);
                if document.map(|view| view.document_id) == app.workspace().scratch(&self.results) {
                    self.results_fresh = false;
                }
                self.jumps.expect_result();
                if !super::grep::jump(app, time, &mut response) {
                    self.jumps.clear_pending();
                    self.jumps.end_walk();
                    response.commands.extend([
                        Command::Modal(super::modal::Action::Move {
                            step: super::modal::Step::Down,
                            extend: false,
                        }),
                        Command::Named("line-start".into()),
                    ]);
                }
            }
            Command::ResultStep { backward } => {
                let fresh = std::mem::take(&mut self.results_fresh);
                super::grep::step(app, &self.results, fresh, backward, time, &mut response)
            }
            Command::Results { kind, lines } => {
                if lines.iter().any(|line| {
                    super::grep::location(line).is_some() || super::grep::row(line).is_some()
                }) {
                    let name = format!("*{kind}*");
                    self.set_results(name.clone());
                    response.events.push(Event::ResultsDisplay { kind });
                    response.events.push(Event::Scratch {
                        name,
                        directory: file_root.to_owned(),
                        text: lines.join("\n") + "\n",
                    });
                } else {
                    response.message = Message::Set(format!("{kind}: no results"));
                }
            }
            Command::Run(shell) => {
                self.set_results(super::grep::RUN.to_owned());
                let view = active(app);
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
            Command::Offer { id, title, items } => {
                self.offer = Some((id, items));
                let line = "choose ".to_owned();
                let ask = Command::Ask { line, note: title };
                return self.execute(ask, app, time, file_root);
            }
            Command::Choose(index) => match self.offer.take() {
                Some((id, items)) if (1..=items.len()).contains(&index) => {
                    let argument = index.to_string();
                    response.lua.push(super::LuaRequest::Call { id, argument });
                }
                _ => response.message = Message::Set("Nothing to choose".into()),
            },
            Command::Messages => response.messages = true,
            Command::Echo(text) => response.message = Message::Set(text),
            Command::Highlight {
                local,
                face,
                pattern,
            } => {
                let document = active(app).map(|view| view.document_id);
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
                let document = active(app).map(|view| view.document_id);
                response
                    .events
                    .push(Event::Unhighlight { document, pattern });
            }
            Command::FlagLines { group, flag, lines } => match active(app) {
                Some(view) => response.events.push(Event::Flag {
                    document: view.document_id,
                    group,
                    flag,
                    lines,
                }),
                None => response.message = Message::Set("No document to flag".into()),
            },
            Command::UnflagLines(group) => {
                if let Some(view) = active(app) {
                    response.events.push(Event::Unflag {
                        document: view.document_id,
                        group,
                    });
                }
            }
            Command::EachLine(_) | Command::EachMatch { .. } | Command::EachAt { .. } => {
                if let Some(view) = active(app) {
                    response.commands = self.each(app, view, command);
                }
            }
            Command::Replay(keys) => {
                response.replay = keys;
            }
            Command::JumpTo => {
                if let Some(view) = app.active_view() {
                    let rows = |id: crate::application::ViewId| {
                        let shown = self.window_rows.iter().find(|(view, _)| *view == id);
                        shown.map_or(self.page_rows, |(_, rows)| *rows)
                    };
                    let others = app.windows().views();
                    let others = others.into_iter().filter(|id| *id != view);
                    let windows = std::iter::once(view)
                        .chain(others)
                        .map(|id| (id, rows(id)))
                        .collect();
                    let session = super::labels::LabelSession::jump(view, windows);
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
                let document = active(app).map(|view| view.document_id);
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
                if let Some(view) = active(app) {
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
                if matches!(command, WindowCommand::ResizeMode) {
                    if let Some(session) = super::resize::ResizeSession::new(app) {
                        response = self.enter(Layer::Resize(session), app, time)?;
                    }
                    return Ok(super::InputResult::Handled(response));
                }
                response.events.push(match command {
                    WindowCommand::Resize(axis, delta) => Event::ResizeWindow { axis, delta },
                    WindowCommand::ResetSizes => Event::ResetWindowSizes,
                    WindowCommand::ResizeMode => unreachable!(),
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
        let editor = app.workspace().editor(view.document_id).unwrap();
        let document = editor.model().document();
        let snapshot = document.snapshot();
        let selection = editor.model().session(view.session_id).unwrap().selection();
        let range = Some(selection.range()).filter(|range| !range.is_empty());
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
            Command::EachAt { targets, keys } => (targets, keys),
            _ => unreachable!(),
        };
        // The last 10,000, which go first.
        let skip = targets.len().saturating_sub(10_000);
        let carets = targets.into_iter().skip(skip);
        let carets = carets.map(crate::core::Selection::caret);
        replay_each(carets, &keys, document.history_depth())
    }
    /// Makes a results document the one `]q` and `[q` step through.
    fn set_results(&mut self, name: String) {
        self.results = name;
        self.results_fresh = true;
        self.jumps.end_walk();
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
        } else {
            response.events.push(leaving(app, document, reload, false));
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
        let name = app.document_name(document);
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
                response
                    .events
                    .push(leaving(app, document, action == "reload", true));
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
                let target = match path {
                    Some(path) => match resolve(app, &path) {
                        Ok(target) => Some(target),
                        Err(error) => {
                            response.message = Message::Set(error);
                            return Ok(super::InputResult::Handled(response));
                        }
                    },
                    None => None,
                };
                let retry = target.as_ref().map_or_else(
                    || format!("{action} save"),
                    |target| {
                        let directory = app.directory();
                        let shown = target.strip_prefix(directory).unwrap_or(target);
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
/// Takes the caret to a place from the jump history: focusing a view of its
/// document, one on screen if any, in the window that holds it.
fn go(
    app: &Application,
    place: crate::editor::DocumentPosition,
    time: Duration,
    response: &mut Response,
) {
    let view = app
        .views()
        .filter(|view| view.document_id == place.document_id)
        .max_by_key(|view| app.windows().contains(view.id));
    let Some(view) = view else {
        response.events.push(Event::AddView(place.document_id));
        return;
    };
    response.events.extend([
        Event::Focus(view.id),
        Event::Edit {
            view: view.id,
            command: EditCommand::SetSelection(crate::core::Selection::caret(place.offset.0)),
            time,
        },
    ]);
}
pub(super) fn show(app: &Application, document: crate::editor::DocumentId) -> Event {
    let active = active(app).filter(|v| v.document_id == document);
    let view = active.or_else(|| app.views().find(|v| v.document_id == document));
    view.map_or(Event::AddView(document), |v| Event::Focus(v.id))
}

/// How far changes before `at` move it: in bytes, and in lines.
fn shift(text: &str, changes: &[crate::core::Change], at: usize) -> (isize, isize) {
    let mut bytes = 0isize;
    let mut lines = 0isize;
    for change in changes.iter().filter(|change| change.range.end <= at) {
        let removed = &text[change.range.clone()];
        bytes += change.insert.len() as isize - removed.len() as isize;
        lines +=
            change.insert.matches('\n').count() as isize - removed.matches('\n').count() as isize;
    }
    (bytes, lines)
}
impl Layers {
    /// Puts a candidate in the document, and records for `.` and macros the
    /// keys that would have typed it: their replays do not complete.
    fn accept(
        &mut self,
        accepted: super::completion::Accepted,
        app: &Application,
        time: Duration,
        response: &mut Response,
    ) {
        use super::{Key, KeyStroke, UserInput};
        use crate::core::{Change, Selection, Transaction};
        let super::completion::Accepted {
            view,
            edits,
            range,
            caret,
            text,
            snippet,
        } = accepted;
        let document = app.view(view).unwrap().document_id;
        let editor = app.workspace().editor(document).unwrap();
        let snapshot = editor.model().document().snapshot();
        let whole = snapshot.text();
        let before = whole[range.start..caret].chars().count();
        let after = whole[caret..range.end].chars().count();
        for key in std::iter::repeat_n(Key::Backspace, before)
            .chain(std::iter::repeat_n(Key::Delete, after))
        {
            self.modal
                .replay
                .record(UserInput::Key(KeyStroke::plain(key)));
        }
        let typed = if snippet {
            self.expand_snippet(view, range, edits, &text, app, time, response)
        } else {
            let start = range
                .start
                .saturating_add_signed(shift(whole, &edits, range.start).0);
            let mut changes = edits;
            changes.push(Change::new(range, text.clone()));
            let mut tx = Transaction::new(snapshot.version(), changes);
            tx.selection = Some(Selection::caret(start + text.len()));
            response.events.push(Event::Edit {
                view,
                command: EditCommand::Apply(tx),
                time,
            });
            text
        };
        self.modal.replay.record(UserInput::Paste(typed));
    }
    /// Expands a snippet in place of a range as one undoable step, with
    /// other edits; returns its text. Lines after the first get the
    /// language's indentation.
    #[allow(clippy::too_many_arguments)]
    fn expand_snippet(
        &mut self,
        view: crate::application::ViewId,
        range: std::ops::Range<usize>,
        edits: Vec<crate::core::Change>,
        body: &str,
        app: &Application,
        time: Duration,
        response: &mut Response,
    ) -> String {
        use crate::core::{Change, Selection, Transaction};
        let document = app.view(view).unwrap().document_id;
        let model = app.workspace().editor(document).unwrap().model().document();
        let snapshot = model.snapshot();
        let line = snapshot.line_of(range.start).unwrap();
        let indent = snapshot.leading_whitespace(line).unwrap().to_string();
        let style = model.whitespace();
        let unit = crate::language::materialize(style.indent_width, 0, style.indent_width, &style);
        let parsed = super::snippet::parse(body).indented(&indent, &unit);
        let depth = model.history_depth();
        let first = parsed.stops[0].clone();
        // Where the snippet lands once the edits before it are made.
        let (bytes, lines) = shift(snapshot.text(), &edits, range.start);
        let start = range.start.saturating_add_signed(bytes);
        let line = line.saturating_add_signed(lines);
        let mut changes = edits;
        changes.push(Change::new(range.clone(), parsed.text.clone()));
        let mut tx = Transaction::new(snapshot.version(), changes);
        tx.selection = Some(Selection {
            anchor: start + first.start,
            head: start + first.end,
        });
        let lines = parsed.lines();
        let event = |command| Event::Edit {
            view,
            command,
            time,
        };
        response.events.push(event(EditCommand::Apply(tx)));
        if lines > 0 {
            for line in line..=line + lines {
                response.events.push(event(EditCommand::Reindent(line)));
            }
            response
                .events
                .push(event(EditCommand::SquashHistory(depth)));
        }
        self.snippet.pending = Some(super::snippet::Pending {
            view,
            document,
            offset: start,
            stops: parsed.stops,
        });
        parsed.text
    }
}
