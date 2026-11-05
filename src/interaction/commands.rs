//! Application command reduction. Commands resolve their targets on the owner
//! thread and return ordered application events and platform effects.
use super::{
    CommandLine, HelpSession, Layer, Layers, Message, Response, SaveWait, SearchSession, expand,
    registry::holds_commands,
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
    /// Binds keys in a key table: a context, a document keymap or a
    /// language's keymap, by name.
    Map {
        keymap: String,
        keys: Vec<super::KeyStroke>,
        target: String,
        /// What help and key hints show; `None` shows the target.
        label: Option<String>,
        /// A plugin's binding: a default, which user bindings shadow and
        /// which `unmap` does not take away.
        default: bool,
    },
    Unmap {
        keymap: String,
        keys: Vec<super::KeyStroke>,
    },
    /// Reads the next keys through the keypad.
    Keypad(super::KeypadStart),
    Define {
        name: String,
        body: String,
        /// What help and key hints show; `None` shows the body.
        doc: Option<String>,
        /// What the command line completes its arguments as; `None` takes
        /// them as text.
        slots: Option<&'static [super::Slot]>,
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
    /// Close the open document with this buffer name, as `close` does the
    /// current one.
    KillBuffer(String),
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
    /// Asks for a project file, or first for a project when the active
    /// document has none, as project.el's `project-find-file` does.
    FindProjectFile,
    /// Asks for a file of another project.
    SwitchProject(std::path::PathBuf),
    /// The command line for `project`, choosing among this project's files.
    ProjectLine(std::path::PathBuf),
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
    Restart,
    /// Asks in the command line, as `completing-read` and `read-string`
    /// do; the Lua function under `id` gets the answer.
    Question {
        id: u64,
        title: String,
        asked: super::slots::Asked,
        /// The history the answer is recalled from and added to; a kind
        /// has its own otherwise.
        history: Option<String>,
    },
    /// Answers `Question` with an item, from one.
    Choose(usize),
    /// Answers `Question` with text.
    Answer(String),
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
    /// Names the last keyboard macro, making it a command.
    MacroName(String),
    /// Sets the format the macro counter is inserted in.
    MacroFormat(String),
    /// Plays a macro by its name.
    MacroCall(String),
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
    /// Gives files of a name or extension a language.
    MapLanguage {
        name: String,
        language: String,
    },
    /// Sets a face over the theme; `None` gives it back.
    Face {
        name: String,
        spec: Option<crate::application::faces::FaceSpec>,
    },
    /// Sets where documents of a kind are shown.
    Display {
        kind: String,
        placement: crate::application::Placement,
    },
    Search,
    SearchBackward,
    /// Searches for the symbol at the caret, from its start, as Emacs's
    /// `isearch-forward-symbol-at-point`.
    SearchSymbol,
    /// Asks about each unsaved file whether to save it, as Emacs's
    /// `save-some-buffers`; the answer is for the one being asked.
    SaveSome(Option<SaveAnswer>),
    /// Shows the buffer used before, or after, in the order of use, as
    /// Emacs's `previous-buffer` and `next-buffer`.
    CycleBuffer {
        backward: bool,
    },
    Completion(super::completion::Action),
    /// Inserts a snippet at the caret.
    Snippet(String),
    /// Searches for a symbol, or for text, and selects its next place.
    Visit(String),
    SnippetStep {
        backward: bool,
    },
    Replace,
}
/// An answer to `save-some-buffers` about one file.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SaveAnswer {
    Yes,
    No,
    /// This one and every one after it.
    All,
    /// None of them any more.
    Quit,
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
    /// Takes the window's document out of its row of tabs.
    CloseTab,
    /// Resizes step by step until Esc.
    ResizeMode,
}
/// How `close`, `reload` and `quit` treat a document with unsaved changes.
/// Without one, they ask through the command line.
#[derive(Clone, Debug)]
pub enum Departure {
    Save(Option<std::path::PathBuf>),
    Discard,
}

/// Replays keys in Normal at each selection, last first so that earlier
/// places hold, as one undoable step. With `kind`, each selection is of
/// that kind, so that keys which extend it extend it the same way.
pub(super) fn replay_each(
    selections: impl DoubleEndedIterator<Item = crate::core::Selection>,
    kind: Option<(super::modal::Kind, bool)>,
    keys: &[super::UserInput],
    depth: usize,
) -> Vec<Command> {
    let mut commands = vec![];
    for selection in selections.rev() {
        let select = match kind {
            Some((kind, expand)) => Command::Modal(super::modal::Action::Found {
                anchor: selection.anchor,
                head: selection.head,
                kind,
                expand,
            }),
            None => Command::Edit(EditCommand::SetSelection(selection)),
        };
        commands.extend([
            Command::SetMode(super::EditMode::Normal),
            select,
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
/// Why a move cannot go: the caret is at the first or last line, or the
/// start or end of the text, already.
fn past_the_end(app: &Application, command: &EditCommand) -> Option<&'static str> {
    use crate::editor::Motion;
    let EditCommand::Move { motion, .. } = command else {
        return None;
    };
    let view = active(app)?;
    let editor = app.workspace().editor(view.document_id)?;
    let text = editor.model().document().snapshot();
    let head = editor.model().session(view.session_id)?.selection().head;
    let line = text.line_of(head)?;
    match motion {
        Motion::Up if line == 0 => Some("Beginning of buffer"),
        Motion::Backward if head == 0 => Some("Beginning of buffer"),
        Motion::Down if line + 1 >= text.line_count() => Some("End of buffer"),
        Motion::Forward if head >= text.len_bytes() => Some("End of buffer"),
        _ => None,
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
        let table = |keymap: &mut super::Keymap, name: &str| {
            keymap
                .table(name)
                .ok_or_else(|| format!("unknown keymap: {name}"))
        };
        match command {
            Command::Map {
                keymap,
                keys,
                target,
                ..
            } if keymap == "prompt" => {
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
                keymap,
                keys,
                target,
                label,
                default,
            } => {
                if !self.registry.knows(&target) {
                    return Err(format!("unknown command: {target}"));
                }
                let table = table(&mut self.keymap, &keymap)?;
                let label = label.unwrap_or_else(|| target.clone());
                let command = Command::Named(target);
                if default {
                    self.keymap.bind_default(table, &keys, command, label)
                } else {
                    self.keymap.bind(table, &keys, command, label)
                }
                .map_err(|e| e.to_string())
            }
            Command::Unmap { keymap, keys } => {
                let table = table(&mut self.keymap, &keymap)?;
                self.keymap.unbind(table, &keys).map_err(|e| e.to_string())
            }
            Command::Define {
                name,
                body,
                doc,
                slots,
            } => self.registry.define(name, body, doc, slots),
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
        // A hook runs between keys, not because of one: the keys of a
        // binding being typed stay.
        if self.hook.is_none() {
            self.sequence.clear();
        }
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
        // With a mark set, every move extends from it, as in Emacs; in
        // Insert only when editing is not modal, as meow's Insert typing
        // drops it.
        let marked = (self.mode != super::EditMode::Insert || !super::modal_on(app))
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
            command => command,
        };
        // Typing and yanking go in at the caret and drop the selection, as
        // Emacs does without delete-selection-mode; meow's Insert keeps its
        // own way.
        if self.mode == super::EditMode::Insert
            && !super::modal_on(app)
            && matches!(
                command,
                Command::Edit(
                    EditCommand::TypeChar(_) | EditCommand::InsertText(_) | EditCommand::Enter
                ) | Command::Clipboard(ClipboardAction::Paste)
            )
            && let Some(view) = active(app)
            && let Some(selection) = super::modal::execute_place(app)
            && !selection.range().is_empty()
        {
            self.modal.tag = None;
            response.events.push(Event::Edit {
                view: view.id,
                command: EditCommand::SetSelection(crate::core::Selection::caret(selection.head)),
                time,
            });
        }
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
                // Without modal editing there is no other mode to be in.
                self.mode = if super::modal_on(app) {
                    mode
                } else {
                    super::EditMode::Insert
                };
            }
            Command::Modal(action) => response = self.modal_execute(action, app, time),
            Command::Fail(message) => {
                response = self.fail(response, &message);
                response.failed = true;
            }
            // Only the runtime can do these; it takes them from the response.
            effect @ Command::Effect(_) => response.commands.push(effect),
            Command::Ex(_) | Command::Ask { .. } | Command::ProjectLine(_) => {
                // Only the question Lua just put names a history.
                let asked_history = self.asked_history.take();
                let asked_kind = self.asked_kind.take();
                let (text, note, project) = match command {
                    Command::Ask { line, note } => (line, Some(note), None),
                    Command::Ex(text) => (text, None, None),
                    Command::ProjectLine(project) => ("project ".to_owned(), None, Some(project)),
                    _ => unreachable!(),
                };
                // A command line of its own answers no earlier question.
                if note.is_none() {
                    self.forget_reply();
                }
                // A question of a kind answers as an argument of it would.
                let mut catalog = self.registry.commands();
                if let Some(kind) = asked_kind
                    && let Some(answer) = catalog.iter_mut().find(|info| info.name == "answer")
                {
                    answer.slots = super::slots::answer_slots(kind);
                }
                let mut line = CommandLine::new(
                    &text,
                    catalog,
                    project.clone().unwrap_or_else(|| file_root.to_owned()),
                    app.directory(),
                    app,
                )
                .with_recent(self.recent_files.clone())
                .with_projects(self.projects.clone())
                .with_keymaps(self.keymap.names())
                .with_items(self.question.as_ref().map_or(vec![], |(_, i)| i.clone()))
                .with_histories(self.history.clone())
                .with_history(asked_history);
                if let Some(note) = note {
                    line = line.with_note(note);
                }
                // Files of another project complete to absolute paths, which
                // `project` opens whatever the active document's project.
                if project.is_some() {
                    line = line.with_absolute_files();
                }
                response = self.enter(Layer::CommandLine(Box::new(line)), app, time)?;
                if let Some(Layer::CommandLine(line)) = &mut self.active {
                    let first = line.refresh(app, true);
                    response.effects.extend(first.effects);
                    response.path_requests.extend(first.path_requests);
                    response.lua.extend(first.lua);
                }
            }
            Command::KillBuffer(name) => {
                let name = name.trim();
                let document = app
                    .workspace()
                    .documents()
                    .find(|id| app.document_name(*id) == name);
                match document {
                    None => response.message = Message::Set(format!("No buffer named {name}")),
                    Some(document) if active(app).is_some_and(|v| v.document_id == document) => {
                        return self.execute(Command::Close(None), app, time, file_root);
                    }
                    // Unsaved changes are decided where they can be seen:
                    // the document comes forward, then `close` asks.
                    Some(document)
                        if app.workspace().is_dirty(document)
                            && !app.workspace().is_saving(document) =>
                    {
                        response.events.push(show(app, document));
                        response.commands.push(Command::Close(None));
                    }
                    Some(document) => response = self.leave(document, false, app),
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
            Command::FindProjectFile => {
                let line = match app.project() {
                    Some(_) => "project ",
                    None => "project-switch ",
                };
                return self.execute(Command::Ex(line.into()), app, time, file_root);
            }
            Command::SwitchProject(path) => {
                match resolve(app, &path).and_then(|path| {
                    std::fs::canonicalize(&path)
                        .ok()
                        .filter(|path| path.is_dir())
                        .ok_or_else(|| format!("{} is not a directory", path.display()))
                }) {
                    Ok(directory) => {
                        // A directory chosen without a marker is a project
                        // from now on, so the file opened in it has it.
                        let line = Command::ProjectLine(directory.clone());
                        let mut opened = self.execute(line, app, time, file_root)?;
                        if let super::InputResult::Handled(response) = &mut opened {
                            response.events.insert(0, Event::AddProject(directory));
                        }
                        return Ok(opened);
                    }
                    Err(error) => {
                        response.message = Message::Set(error);
                        response.failed = true;
                    }
                }
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
                        super::modal_on(app),
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
                        horizontal_scroll: view.viewport.horizontal_scroll,
                    });
                }
            }
            Command::SearchSymbol => {
                let Some(view) = active(app) else {
                    return Ok(super::InputResult::Handled(response));
                };
                let editor = app.workspace().editor(view.document_id).unwrap();
                let session = editor.model().session(view.session_id).unwrap();
                let snapshot = editor.model().document().snapshot();
                let head = session.selection().head;
                let Some(range) = super::modal::text::thing_at(snapshot, head, true) else {
                    response.message = Message::Set("No symbol at point".into());
                    return Ok(super::InputResult::Handled(response));
                };
                let word = snapshot.byte_slice(range.clone()).unwrap().to_string();
                let query = crate::editor::search::SearchQuery::symbol(word);
                // As in Emacs the search starts at the symbol's start, so its
                // first match is this one, and cancelling comes back there.
                let session = SearchSession::starting_at(app, view.id, range.start)?;
                let (session, seeded) = session.seeded(query, app, time)?;
                response = self.enter(Layer::Search(Box::new(session)), app, time)?;
                response.events.splice(0..0, seeded.events);
            }
            Command::SaveSome(answer) => {
                let unsaved = |id: &crate::editor::DocumentId| {
                    app.workspace().is_dirty(*id)
                        && !app.workspace().is_saving(*id)
                        && app
                            .workspace()
                            .file(*id)
                            .is_some_and(|f| f.path().is_some())
                };
                match answer {
                    None => self.save_some = app.workspace().documents().filter(unsaved).collect(),
                    Some(answer) => {
                        let asked = self.save_some.first().copied();
                        let rest = match answer {
                            SaveAnswer::Yes => asked.into_iter().collect(),
                            SaveAnswer::All => std::mem::take(&mut self.save_some),
                            SaveAnswer::No | SaveAnswer::Quit => vec![],
                        };
                        for document in rest.into_iter().filter(unsaved) {
                            response.events.push(Event::Save {
                                document,
                                target: None,
                            });
                        }
                        if answer == SaveAnswer::Quit {
                            self.save_some.clear();
                        } else if !self.save_some.is_empty() {
                            self.save_some.remove(0);
                        }
                    }
                }
                self.save_some.retain(unsaved);
                match self.save_some.first() {
                    Some(document) => {
                        let ask = Command::Ask {
                            line: "save-some-buffers ".into(),
                            note: format!("save {}?", app.document_name(*document)),
                        };
                        let asked = self.execute(ask, app, time, file_root)?;
                        if let super::InputResult::Handled(mut asked) = asked {
                            asked.events.splice(0..0, response.events);
                            return Ok(super::InputResult::Handled(asked));
                        }
                        return Ok(asked);
                    }
                    None if answer.is_none() => {
                        response.message = Message::Set("(No files need saving)".into());
                    }
                    None => {}
                }
            }
            Command::CycleBuffer { backward } => {
                let current = active(app).map(|view| view.document_id);
                let again = self.command.after(
                    |c| matches!(c, Command::CycleBuffer { .. }),
                    &["previous-buffer", "next-buffer"],
                );
                let fresh = !again || self.modal.buffer_cycle.is_none();
                if fresh {
                    let mut order: Vec<_> = current.into_iter().collect();
                    for document in app.documents_by_use().chain(app.workspace().documents()) {
                        if !order.contains(&document) {
                            order.push(document);
                        }
                    }
                    self.modal.buffer_cycle = Some((order, 0));
                }
                let (order, at) = self.modal.buffer_cycle.as_mut().unwrap();
                order.retain(|document| app.workspace().editor(*document).is_some());
                if order.len() < 2 {
                    response.message = Message::Set("No other buffer".into());
                    return Ok(super::InputResult::Handled(response));
                }
                let n = order.len();
                *at = if backward {
                    (*at + 1) % n
                } else {
                    (*at + n - 1) % n
                };
                response.events.push(show(app, order[*at]));
            }
            Command::Search | Command::SearchBackward | Command::Replace => {
                if let Some(view) = app.active_view() {
                    let session = SearchSession::new(app, view)?;
                    let session = match command {
                        Command::SearchBackward => session.backward(),
                        Command::Replace => session.replacing(),
                        _ => session,
                    };
                    response = self.enter(Layer::Search(Box::new(session)), app, time)?;
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
                    let selected = !range.is_empty();
                    // Its places are filled in Insert.
                    if self.mode == super::EditMode::Normal && !self.modal.active() {
                        self.modal.insert_view = Some(view);
                        self.mode = super::EditMode::Insert;
                        self.modal.tag = None;
                        response.events.push(Event::Edit {
                            view,
                            command: EditCommand::BeginUndoGroup(selection),
                            time,
                        });
                    }
                    self.expand_snippet(
                        view,
                        range,
                        vec![],
                        &body,
                        selected,
                        app,
                        time,
                        &mut response,
                    );
                }
            }
            Command::Visit(text) => {
                if let Some(view) = app.active_view()
                    && let Some(state) = app.view(view)
                {
                    let editor = app.workspace().editor(state.document_id).unwrap();
                    let snapshot = editor.model().document().snapshot();
                    let symbol = text.chars().all(super::completion::is_word)
                        && super::command_line::symbols(snapshot.text(), 0).contains(&text);
                    let query = if symbol {
                        crate::editor::search::SearchQuery::symbol(text.clone())
                    } else {
                        crate::editor::search::SearchQuery::new(regex::escape(&text))
                    };
                    self.modal.set_search(query.clone());
                    self.history.record(super::history::SEARCH, &text);
                    let head = editor
                        .model()
                        .session(state.session_id)
                        .unwrap()
                        .selection()
                        .head;
                    // From the caret, so the selection is not what is sought.
                    response.events.push(Event::Edit {
                        view,
                        command: EditCommand::SetSearchQuery(query),
                        time,
                    });
                    response.events.push(Event::Edit {
                        view,
                        command: EditCommand::SetSelection(crate::core::Selection::caret(head)),
                        time,
                    });
                    response.commands.push(Command::Named("search-next".into()));
                }
            }
            Command::SnippetStep { backward } => {
                if let Some((view, selection)) = self.snippet.step(backward)
                    && let Some(state) = app.view(view)
                {
                    // Not a move of its own: filling a snippet is one undo step.
                    let version = app
                        .workspace()
                        .editor(state.document_id)
                        .unwrap()
                        .model()
                        .document()
                        .snapshot()
                        .version();
                    let mut tx = crate::core::Transaction::new(version, vec![]);
                    tx.selection = Some(selection);
                    response.events.push(Event::Edit {
                        view,
                        command: EditCommand::Apply(tx),
                        time,
                    });
                }
            }
            Command::Edit(command) => {
                // Moving past either end of the text fails, as Emacs's
                // `next-line` and `forward-char` signal, which ends a macro
                // played until something fails.
                if let Some(message) = past_the_end(app, &command) {
                    return Ok(super::InputResult::Handled(self.fail(response, message)));
                }
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
            // Unsaved text goes along, so nothing is asked.
            Command::Restart => {
                if app
                    .workspace()
                    .documents()
                    .any(|id| app.workspace().is_saving(id))
                {
                    response.message =
                        Message::Set("Save in progress; restart after it completes".into());
                } else {
                    response.restart = true;
                }
            }
            Command::Lua(code) => response.lua.push(super::LuaRequest::Chunk {
                origin: "lua".into(),
                code,
            }),
            Command::LuaCall { id, argument } => {
                response.lua.push(super::LuaRequest::Call { id, argument })
            }
            Command::Question {
                id,
                title,
                asked,
                history,
            } => {
                use super::slots::Asked;
                let (line, items, kind) = match asked {
                    Asked::Text(initial) => (format!("answer {initial}"), vec![], None),
                    Asked::Items(items) => ("choose ".to_owned(), items, None),
                    Asked::Kind(kind) => ("answer ".to_owned(), vec![], Some(kind)),
                };
                self.question = Some((id, items));
                self.asked_history = history.or_else(|| {
                    let kind = kind?;
                    super::slots::behavior(kind).history.map(str::to_owned)
                });
                self.asked_kind = kind;
                let ask = Command::Ask { line, note: title };
                return self.execute(ask, app, time, file_root);
            }
            Command::Answer(text) => match self.question.take() {
                Some((id, _)) => response.lua.push(super::LuaRequest::Answer {
                    id,
                    text,
                    index: None,
                }),
                None => response.message = Message::Set("Nothing to answer".into()),
            },
            Command::Choose(index) => match self.question.take() {
                Some((id, items)) if (1..=items.len()).contains(&index) => {
                    let text = items[index - 1].text.clone();
                    let index = Some(index);
                    response
                        .lua
                        .push(super::LuaRequest::Answer { id, text, index });
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
            Command::MacroName(name) => {
                if let Err(message) = self.modal.replay.name(&name) {
                    response = self.fail(response, message);
                } else {
                    response.commands.push(Command::Define {
                        body: format!("macro-call {name}"),
                        name,
                        doc: Some("A keyboard macro".into()),
                        slots: None,
                    });
                }
            }
            Command::MacroFormat(format) => {
                let replay = &mut self.modal.replay;
                replay.format = format;
                // Outside a macro it holds for those defined from now on.
                if !replay.recording() && !self.command.executing {
                    replay.default_format = replay.format.clone();
                }
            }
            Command::MacroCall(name) => response = self.call_named(&name, response),
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
            Command::Face { name, spec } => response.events.push(Event::SetFace { name, spec }),
            Command::MapLanguage { name, language } => {
                response.events.push(Event::MapLanguage { name, language })
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
                    // A file to open goes to the new window, which takes
                    // focus for it, as `find-file-other-window`.
                    WindowCommand::Split(axis, path) => {
                        let follow = path.is_some();
                        response.commands.extend(path.map(Command::OpenPath));
                        Event::Split { axis, follow }
                    }
                    WindowCommand::CloseTab => match app.view(active) {
                        Some(view) => Event::CloseTab(view.document_id),
                        None => return Ok(super::InputResult::Handled(response)),
                    },
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
        replay_each(carets, None, &keys, document.history_depth())
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
/// Shows a document: focuses a view of it, or adds one.
pub fn show(app: &Application, document: crate::editor::DocumentId) -> Event {
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
            selected,
            text,
            snippet,
        } = accepted;
        let document = app.view(view).unwrap().document_id;
        let editor = app.workspace().editor(document).unwrap();
        let snapshot = editor.model().document().snapshot();
        let whole = snapshot.text();
        let before = whole[range.start..caret].chars().count();
        let after = whole[selected..range.end].chars().count();
        for key in std::iter::repeat_n(Key::Backspace, before)
            .chain(std::iter::repeat_n(Key::Delete, after))
        {
            self.modal
                .replay
                .record(UserInput::Key(KeyStroke::plain(key)));
        }
        // A snippet replays as one, so that its places are filled again.
        let typed = if snippet {
            let snippet = text.clone();
            self.expand_snippet(view, range, edits, &text, false, app, time, response);
            UserInput::Snippet(snippet)
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
            UserInput::Paste(text)
        };
        self.modal.replay.record(typed);
    }
    /// Expands a snippet in place of a range as one undoable step, with
    /// other edits. Lines after the first get the language's indentation.
    /// `selected` says the range is the selection, for `TM_SELECTED_TEXT`.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn expand_snippet(
        &mut self,
        view: crate::application::ViewId,
        range: std::ops::Range<usize>,
        edits: Vec<crate::core::Change>,
        body: &str,
        selected: bool,
        app: &Application,
        time: Duration,
        response: &mut Response,
    ) {
        use crate::core::{Change, Selection, Transaction};
        let document = app.view(view).unwrap().document_id;
        let model = app.workspace().editor(document).unwrap().model().document();
        let snapshot = model.snapshot();
        let line = snapshot.line_of(range.start).unwrap();
        let indent = snapshot.leading_whitespace(line).unwrap().to_string();
        let style = model.whitespace();
        let unit = crate::language::materialize(style.indent_width, 0, style.indent_width, &style);
        let values = super::snippet::variables(app, document, range.clone(), selected);
        let parsed = super::snippet::parse_with(body, &|name| values.get(name).cloned())
            .indented(&indent, &unit);
        let depth = model.history_depth();
        let first = parsed.stops[0].range.clone();
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
    }
}
