//! Frontend-independent routing and built-in sessions. Layers own editing mode,
//! literal key sequences and session lifecycle;
//! feature reducers return transitions and Runtime executes their responses.
mod command_line;
pub use command_line::{CommandLine, Completion};
mod commands;
pub mod completion;
pub mod modal;
pub mod snippet;
pub use commands::{Command, Departure, WindowCommand, show};
mod departure;
pub use departure::SaveWait;
pub mod expand;
pub mod grep;
pub mod help;
pub mod history;
pub mod hooks;
pub mod labels;
pub use help::HelpSession;
mod input;
pub use input::{InputKey, InputMotion, InputUpdate, TextInput};
mod layer;
pub use layer::Layer;
pub mod picker;
pub mod shell;
use picker::{ListMotion, PickerCompletion, PickerEffect};
pub mod path;
mod pointer;
pub use pointer::Pointer;
mod routing;
pub use routing::{Key, KeyStroke, UserInput, emacs_notation, key_notation};
mod search;
pub use search::{SearchResults, SearchSession};
mod jumps;
mod keymap;
pub use keymap::{BindingError, Context, Keymap, KeypadStart, LineEdit, Scope};
use std::collections::HashMap;
mod registry;
pub use registry::{BUILTINS, Choice, CommandInfo, Registry, Slot, SlotKind};
mod resize;
mod session;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum EditMode {
    /// Typing inserts; the only mode unless `modal` is set.
    #[default]
    Insert,
    Normal,
    /// Many selections inside a grabbed range.
    Beacon,
}
impl EditMode {
    pub fn name(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Insert => "insert",
            Self::Beacon => "beacon",
        }
    }
}
use crate::{
    application::{Application, Event, Operation, Update},
    core::EditError,
};
use session::Transition;
use std::time::Duration;

#[derive(Clone, Debug)]
pub enum Input {
    Help,
    Text(InputKey),
    Paste(String),
    Confirm,
    ReplaceAll,
    Complete {
        backward: bool,
    },
    Cancel,
    Navigate {
        backward: bool,
    },
    Candidate {
        motion: ListMotion,
        wrap: bool,
    },
    /// Recall an older or newer line from the prompt's history.
    History {
        backward: bool,
    },
    Unrecognized,
}
pub enum InputResult {
    Pass,
    Blocked,
    Handled(Response),
}
pub struct Presentation {
    pub text: String,
    pub cursor: Option<usize>,
    pub selection: std::ops::Range<usize>,
}
#[derive(Default)]
pub enum Message {
    #[default]
    Keep,
    Clear,
    Set(String),
}
/// Events, then deferred commands execute after session reduction. Runtime
/// stops at the first failure and requests quit only after the batch succeeds.
#[derive(Default)]
pub struct Response {
    pub events: Vec<Event>,
    pub commands: Vec<Command>,
    pub message: Message,
    pub effects: Vec<PickerEffect>,
    pub path_requests: Vec<path::PathRequest>,
    pub shell: Option<Box<shell::ShellRequest>>,
    pub grep: Option<Box<grep::GrepRequest>>,
    /// A command for `run`, whose output streams into `*run*`.
    pub run: Option<Box<shell::ShellRequest>>,
    /// Stop background work.
    pub stop: bool,
    /// Show the message log in `*messages*`.
    pub messages: bool,
    /// Input to route again, after the rest of the response, for macros.
    pub replay: Vec<UserInput>,
    /// Lua to run once the rest of the response is done.
    pub lua: Vec<LuaRequest>,
    pub quit: bool,
    /// Give the terminal back to the shell, as Ctrl-Z in a shell job.
    pub suspend: bool,
    pub redraw: bool,
    /// A named command failed; the statements queued after it are dropped.
    pub failed: bool,
}

/// Work for the Lua host, which the runtime owns.
#[derive(Clone, Debug, PartialEq)]
pub enum LuaRequest {
    /// Code to run, named by where it came from for error messages.
    Chunk { origin: String, code: String },
    /// A function registered by `soda.hook` or `soda.define_command`.
    Call { id: u64, argument: String },
}

/// Owns editing input state and one modal layer. Read-only access keeps transitions inside
/// this manager; callers must execute responses and observe resulting updates.
///
/// ```compile_fail
/// let mut layers = soda::interaction::Layers::default();
/// layers.active = None;
/// ```
#[derive(Default)]
pub struct Layers {
    active: Option<Layer>,
    mode: EditMode,
    sequence: keymap::Sequence,
    keymap: Keymap,
    modal: modal::State,
    completion: completion::State,
    retype: Option<KeyStroke>,
    snippet: snippet::State,
    /// The input being routed comes from a macro.
    replaying: bool,
    jumps: jumps::Jumps,
    registry: Registry,
    hooks: hooks::Hooks,
    /// Recently used files, newest first, for `recent`.
    recent_files: Vec<std::path::PathBuf>,
    /// The Lua function and the items of the question last offered.
    offer: Option<(u64, Vec<String>)>,
    /// The Lua function a line of text is asked for.
    question: Option<u64>,
    /// Command line and search histories.
    history: [history::History; 2],
    /// The results document `]q` and `[q` step through: the latest filled.
    results: String,
    /// `]q` has not stepped through these results yet.
    results_fresh: bool,
    page_rows: usize,
    window_rows: Vec<(crate::application::ViewId, usize)>,
    help_rows: usize,
    picker_rows: usize,
    /// A command failed since this was last taken; replays stop.
    failed: bool,
    /// The parameter of the event whose hooks are running, `%val{hook}`.
    hook: Option<String>,
    /// The names of the language servers serving each document, for the
    /// keymaps of servers.
    servers: HashMap<crate::editor::DocumentId, Vec<String>>,
    /// The `modal` option as last seen.
    modal_seen: bool,
}
impl Layers {
    /// Whether a command failed since `clear_failed`.
    pub fn failed(&self) -> bool {
        self.failed
    }
    /// Removes the hooks that run exactly this command, as a Lua hook is
    /// removed by its function; whether any went.
    pub fn remove_hook_command(&mut self, command: &str) -> bool {
        self.hooks.remove_command(command)
    }
    /// Adds a hook by event name, as the `hook` command does.
    pub fn add_hook(&mut self, event: &str, filter: &str, command: String) -> Result<(), String> {
        let event = registry::hook_event(event)?;
        self.configure(Command::Hook {
            event,
            filter: filter.to_owned(),
            command,
        })
    }
    /// Sets what `%val{hook}` expands to while a hook runs.
    pub fn set_hook(&mut self, parameter: Option<String>) {
        self.hook = parameter;
    }
    /// Expands `%opt{}` and `%val{}` as a command line running now would.
    pub fn expand(
        &self,
        text: &str,
        app: &crate::application::Application,
        file_root: &std::path::Path,
    ) -> Result<String, String> {
        expand::expand(text, &self.expansion(app, file_root))
    }
    fn expansion<'a>(
        &'a self,
        app: &'a crate::application::Application,
        file_root: &'a std::path::Path,
    ) -> expand::State<'a> {
        expand::State {
            app,
            mode: self.mode,
            root: file_root,
            hook: self.hook.as_deref(),
        }
    }
    pub fn clear_failed(&mut self) {
        self.failed = false;
    }
    /// The register a macro is being recorded into.
    /// Commands of the hooks for an event whose parameter they match.
    pub fn hooks(&self, event: &str, parameter: &str) -> Vec<String> {
        self.hooks.matching(event, parameter)
    }
    pub fn recording(&self) -> bool {
        self.modal.replay.recording()
    }
    pub fn edit_mode(&self) -> EditMode {
        self.mode
    }
    /// Makes a key after `,` and `.` select a kind of thing, by its name in
    /// `Thing::NAMES`; `None` takes the key's thing away.
    pub fn define_thing(&mut self, key: char, kind: Option<&str>) -> Result<(), String> {
        let thing = match kind {
            Some(name) => Some(modal::Thing::parse(name).ok_or_else(|| {
                let names: Vec<_> = modal::Thing::NAMES.iter().map(|(word, _)| *word).collect();
                format!("no thing kind {name}; one of {}", names.join(", "))
            })?),
            None => None,
        };
        self.modal.things.set(key, thing);
        Ok(())
    }
    /// Follows the `modal` option when it changes: turned on, Insert
    /// becomes Normal; turned off, every mode becomes Insert.
    pub fn sync_modal(&mut self, app: &crate::application::Application) {
        let on = modal_on(app);
        if on == self.modal_seen {
            return;
        }
        self.modal_seen = on;
        self.modal.tag = None;
        if on {
            // An insertion under way ends as it would have.
            if self.mode == EditMode::Insert && self.modal.insert_view.is_none() {
                self.mode = EditMode::Normal;
            }
        } else if self.mode != EditMode::Insert {
            if self.mode == EditMode::Beacon {
                self.leave_beacon();
            }
            self.mode = EditMode::Insert;
        }
    }
    /// Keys typed toward an unfinished binding or command, if any.
    pub fn pending(&self) -> Option<String> {
        if self.sequence.active() {
            // The keys as Emacs writes them, `C-x`, and the modifiers the
            // keypad holds for the next key, `C-x M-`.
            let keys = emacs_notation(self.sequence.keys());
            let next = self.sequence.keypad_hint();
            Some(match (keys.is_empty(), next.is_empty()) {
                (true, _) => next.into(),
                (false, true) => keys,
                (false, false) => format!("{keys} {next}"),
            })
        } else if self.modal.active() {
            Some(self.modal.hint())
        } else {
            None
        }
    }
    /// The next keys of a pending multi-key binding, each with the
    /// documentation of its command, for a key hint popup.
    pub fn continuations(&self, app: &Application) -> Vec<(String, String)> {
        if !self.sequence.active() {
            return vec![];
        }
        let stack = self.stack(app);
        let next = if self.sequence.in_keypad() {
            self.sequence.keypad_continuations(&stack, &self.keymap)
        } else {
            self.keymap.continuations(&stack, self.sequence.keys())
        };
        next.into_iter()
            .map(|(key, label)| {
                // A binding with arguments says which, as `surround (`
                // and `surround [` share a description.
                let doc = self.registry.doc(&label);
                let args = label
                    .trim()
                    .split_once(char::is_whitespace)
                    .map(|(_, a)| a.trim());
                let text = match args {
                    _ if doc.is_empty() => label.clone(),
                    Some(args) if !args.is_empty() => format!("{doc}: {args}"),
                    _ => doc,
                };
                (key.emacs(), text)
            })
            .collect()
    }
    /// The next move is a jump, for `jump-back`.
    pub fn expect_jump(&mut self) {
        self.jumps.expect();
    }
    /// Brings completion in line with the caret; call after input settles.
    /// Returns a request for sources, and whether to redraw.
    pub fn completion_sync(&mut self, app: &Application) -> (Option<completion::Request>, bool) {
        let editing = self.mode == EditMode::Insert && self.active.is_none();
        self.snippet.sync(app, editing);
        if let Some(offer) = self.snippet.take_offer() {
            self.completion.offer(app, offer);
        }
        self.completion.sync(app, self.mode, self.active.is_some())
    }
    /// Paints the places of the snippet being filled in, when they changed.
    pub fn snippet_paint(&mut self, app: &Application) -> Vec<Event> {
        self.snippet.paint(app)
    }
    pub fn completion_results(
        &mut self,
        generation: u64,
        source: u64,
        items: Vec<completion::Item>,
        incomplete: bool,
        app: &Application,
    ) -> bool {
        self.completion
            .results(generation, source, items, incomplete, app)
    }
    /// Adds a source of candidates, asked also after these characters,
    /// with a function that tells more about a candidate.
    pub fn completion_source(&mut self, id: u64, triggers: Vec<char>, resolve: Option<u64>) {
        self.completion.register(id, triggers, resolve);
    }
    /// A key to route once more after the response it came with, as if
    /// typed then: the commit character after the candidate it accepted.
    pub fn take_retype(&mut self) -> Option<KeyStroke> {
        self.retype.take()
    }
    /// A question about the selected candidate, for its source.
    pub fn completion_resolve(&mut self) -> Option<completion::Resolve> {
        self.completion.resolve()
    }
    /// What a source told about a candidate; whether to redraw.
    pub fn completion_resolved(
        &mut self,
        source: u64,
        key: i64,
        detail: Option<String>,
        doc: Option<String>,
    ) -> bool {
        self.completion.resolved(source, key, detail, doc)
    }
    /// The list to show under the caret.
    pub fn completion_popup(&self) -> Option<completion::Popup> {
        self.completion.popup()
    }
    pub fn active(&self) -> Option<&Layer> {
        self.active.as_ref()
    }
    pub fn enter(
        &mut self,
        mut layer: Layer,
        app: &Application,
        time: Duration,
    ) -> Result<Response, EditError> {
        self.sequence.clear();
        self.modal.clear();
        let mut response = self.close(app, time)?;
        response.events.extend(self.end_insert_group(app, time));
        layer.resize(self.help_rows, self.picker_rows);
        self.history.iter_mut().for_each(history::History::reset);
        self.active = Some(layer);
        response.redraw = true;
        Ok(response)
    }
    pub fn close(&mut self, app: &Application, time: Duration) -> Result<Response, EditError> {
        self.sequence.clear();
        let Some(mut layer) = self.active.take() else {
            return Ok(Response::default());
        };
        if layer.asks() {
            self.forget_reply();
        }
        Ok(match layer.handle(Input::Cancel, app, time)? {
            Transition::Active(response) | Transition::Closed(response) => response,
            Transition::Blocked => Response::default(),
        })
    }
    fn forget_reply(&mut self) {
        self.offer = None;
        self.question = None;
    }
    fn transition(&mut self, transition: Transition) -> Option<Response> {
        match transition {
            Transition::Blocked => None,
            Transition::Active(response) => Some(response),
            Transition::Closed(response) => {
                self.active = None;
                Some(response)
            }
        }
    }
    pub fn handle(
        &mut self,
        input: Input,
        app: &Application,
        time: Duration,
    ) -> Result<InputResult, EditError> {
        if matches!(input, Input::Confirm)
            && let Some(Layer::Search(session)) = &self.active
            && !session.is_replacing()
            && session.query().is_valid()
        {
            {
                self.modal.set_search(session.query().clone());
                if let Some(range) = session.results().current.clone() {
                    self.modal.tag = Some(modal::Tag {
                        selection: crate::core::Selection {
                            anchor: range.start,
                            head: range.end,
                        },
                        kind: modal::Kind::Visit,
                        expand: false,
                    });
                }
            }
        }
        let Some(layer) = &mut self.active else {
            return Ok(InputResult::Pass);
        };
        let field = layer.history().map(|(kind, text)| (kind, text.to_owned()));
        if let Some((kind, text)) = &field {
            let lines = &mut self.history[*kind];
            // Search has no candidates, so Up and Down recall there; the
            // command line keeps them for its candidates.
            let backward = match input {
                Input::History { backward } => Some(backward),
                Input::Candidate {
                    motion: motion @ (ListMotion::Previous | ListMotion::Next),
                    ..
                } if *kind == history::SEARCH => Some(matches!(motion, ListMotion::Previous)),
                _ => None,
            };
            if let Some(entry) = backward.and_then(|backward| lines.recall(text, backward)) {
                let transition = layer.recall(&entry, app, time)?;
                return Ok(self
                    .transition(transition)
                    .map_or(InputResult::Blocked, InputResult::Handled));
            }
            if matches!(input, Input::History { .. }) {
                return Ok(InputResult::Blocked);
            }
        }
        let confirm = matches!(input, Input::Confirm);
        let asks = layer.asks();
        let searching = matches!(layer, Layer::Search(session) if !session.is_replacing());
        let labels = matches!(layer, Layer::Labels(_));
        let transition = layer.handle(input, app, time)?;
        if confirm
            && matches!(transition, Transition::Closed(_))
            && let Some((kind, text)) = field
        {
            self.history[kind].record(&text);
        }
        let closed = matches!(transition, Transition::Closed(_));
        // A question put aside goes unanswered: its Lua function is not
        // called, and its items do not linger in later command lines.
        if closed && asks && !confirm {
            self.forget_reply();
        }
        let result = self.transition(transition);
        if closed && labels {
            self.jumps.expect();
        } else if closed && searching && confirm {
            self.jumps.searched(app);
        }
        Ok(result.map_or(InputResult::Blocked, InputResult::Handled))
    }
    /// The bindings in force in a context, user ones over defaults: keys
    /// and what they show.
    pub fn bindings(&self, keymap: &str) -> Option<Vec<(Vec<KeyStroke>, String)>> {
        self.keymap.bindings_of(keymap)
    }
    /// Defines a keymap that holds in documents of its scope.
    pub fn define_keymap(&mut self, name: &str, scope: Scope, doc: String) -> Result<(), String> {
        self.keymap.define(name, scope, doc)
    }
    /// The names of the language servers serving each document, for the
    /// keymaps of servers; a document left out has none.
    pub fn set_servers(&mut self, servers: HashMap<crate::editor::DocumentId, Vec<String>>) {
        self.servers = servers;
    }
    /// Recently used files, newest first.
    pub fn set_recent_files(&mut self, files: Vec<std::path::PathBuf>) {
        self.recent_files = files;
    }
    /// Takes back histories from an earlier session, oldest first.
    pub fn restore_history(&mut self, commands: &[String], searches: &[String]) {
        for (history, entries) in self.history.iter_mut().zip([commands, searches]) {
            entries.iter().for_each(|entry| history.record(entry));
        }
    }
    /// Lines entered at the command line, oldest first.
    pub fn command_history(&self) -> &[String] {
        self.history[history::COMMAND].entries()
    }
    /// Searches entered, oldest first.
    pub fn search_history(&self) -> &[String] {
        self.history[history::SEARCH].entries()
    }
    /// Observe every successful application update, including other views.
    pub fn observe(
        &mut self,
        app: &Application,
        update: &Update,
        time: Duration,
    ) -> Result<Response, EditError> {
        self.completion.observe(update);
        // Mirrors follow their places in the same undo step.
        let mirrored = self.snippet.observe(app, update, time);
        let searching =
            matches!(&self.active, Some(Layer::Search(session)) if !session.is_replacing());
        self.jumps.observe(app, update, searching);
        let mut group_end: Vec<Event> = mirrored.into_iter().collect();
        if update.active_changed {
            group_end.extend(self.end_insert_group(app, time));
        }
        let active_document = app
            .active_view()
            .and_then(|id| app.view(id))
            .map(|view| view.document_id);
        if update.active_changed
            || update
                .edit
                .as_ref()
                .is_some_and(|edit| edit.text_changed && Some(edit.document_id) == active_document)
        {
            self.sequence.clear();
            self.modal.clear();
            // Earlier selections are offsets into the text before this edit.
            self.modal.history.clear();
        }
        if update.active_changed {
            self.modal.tag = None;
            self.modal.history.clear();
            if self.mode == EditMode::Beacon {
                self.leave_beacon();
            }
        }
        if let Some(edit) = update.edit.as_ref().and_then(|edit| edit.document.as_ref()) {
            let keep = |position: &mut crate::editor::DocumentPosition| {
                position
                    .map(edit, false)
                    .ok()
                    .flatten()
                    .map(|mapped| *position = mapped)
            };
            self.modal
                .beacons
                .retain_mut(|beacon| keep(&mut beacon.start).and(keep(&mut beacon.end)).is_some());
            if let Some(grab) = &mut self.modal.grab
                && keep(&mut grab.start).and(keep(&mut grab.end)).is_none()
            {
                self.modal.grab = None;
            }
        }
        if self.mode == EditMode::Beacon
            && update
                .edit
                .as_ref()
                .is_some_and(|edit| edit.selection_changed)
        {
            self.derive_beacons(app, time);
        }
        let Some(layer) = &mut self.active else {
            return Ok(Response {
                events: group_end,
                ..Response::default()
            });
        };
        let transition = layer.observe(app, update, time)?;
        let mut response = self.transition(transition).unwrap_or_default();
        response.events.extend(group_end);
        Ok(response)
    }
    fn end_insert_group(&mut self, app: &Application, time: Duration) -> Vec<Event> {
        let Some(view) = self.modal.insert_view.take().and_then(|id| app.view(id)) else {
            return vec![];
        };
        let selection = app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .session(view.session_id)
            .unwrap()
            .selection();
        vec![Event::Edit {
            view: view.id,
            command: crate::editor::Command::EndUndoGroup(selection),
            time,
        }]
    }
    pub fn application_failed(&mut self, operation: Operation, error: String) -> Response {
        let Some(Layer::Saving(wait)) = &self.active else {
            return Response::default();
        };
        wait.operation_failed(operation, error)
            .and_then(|transition| self.transition(transition))
            .unwrap_or_default()
    }
    pub fn picker_failed(&mut self, error: String) -> Response {
        let Some(Layer::CommandLine(session)) = &mut self.active else {
            return Response::default();
        };
        session.picker_failed(error);
        Response {
            redraw: true,
            ..Response::default()
        }
    }
    pub fn picker_finished(&mut self, completion: PickerCompletion) -> Response {
        match &mut self.active {
            Some(Layer::CommandLine(session)) => Response {
                redraw: session.picker_finished(completion),
                ..Response::default()
            },
            _ => Response::default(),
        }
    }
    pub fn path_finished(
        &mut self,
        completion: path::PathCompletion,
        app: &Application,
    ) -> Response {
        match &mut self.active {
            Some(Layer::CommandLine(session)) => {
                session.path_finished(completion, app).unwrap_or_default()
            }
            _ => Response::default(),
        }
    }
    pub fn resize_help(&mut self, rows: usize) {
        self.help_rows = rows;
        if let Some(layer) = &mut self.active {
            layer.resize(self.help_rows, self.picker_rows);
        }
    }
    pub fn resize_picker(&mut self, rows: usize) -> bool {
        self.picker_rows = rows;
        match &mut self.active {
            Some(Layer::CommandLine(session)) => {
                session.resize(rows);
                true
            }
            _ => false,
        }
    }
}

/// Whether editing is modal: Normal between insertions.
pub(crate) fn modal_on(app: &crate::application::Application) -> bool {
    app.options().bool(None, "modal")
}
