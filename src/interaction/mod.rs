//! Frontend-independent routing and built-in sessions. Layers own editing mode,
//! literal key sequences and session lifecycle;
//! feature reducers return transitions and Runtime executes their responses.
mod command_line;
pub use command_line::{CommandLine, Completion};
mod commands;
pub mod vim;
pub use commands::{Command, Departure, Sourced, WindowCommand};
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
mod replace;
pub use replace::{ReplacePhase, ReplaceSession};
mod routing;
pub use routing::{Key, KeyStroke, UserInput, key_notation};
mod search;
pub use search::{SearchResults, SearchSession};
mod keymap;
pub use keymap::{BindingError, Context, Keymap, LineEdit};
mod registry;
pub use registry::{BUILTINS, Choice, CommandHandler, CommandInfo, Registry, Slot, SlotKind};
mod session;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum EditMode {
    Insert,
    #[default]
    Normal,
    Visual,
    VisualLine,
}
impl EditMode {
    pub fn name(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Insert => "insert",
            Self::Visual => "visual",
            Self::VisualLine => "visual-line",
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
    /// Input to route again, after the rest of the response, for `.` and
    /// macros.
    pub replay: Vec<UserInput>,
    pub quit: bool,
    pub redraw: bool,
    /// A named command failed; the statements queued after it are dropped.
    pub failed: bool,
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
    vim: vim::State,
    registry: Registry,
    hooks: hooks::Hooks,
    /// Command line and search histories.
    history: [history::History; 2],
    /// The results document `]q` and `[q` step through: the latest filled.
    results: &'static str,
    page_rows: usize,
    help_rows: usize,
    picker_rows: usize,
    /// A Vim command failed since this was last taken; replays stop.
    failed: bool,
}
impl Layers {
    pub fn bind(
        &mut self,
        mode: EditMode,
        keys: &[KeyStroke],
        command: Command,
    ) -> Result<(), BindingError> {
        let label = match &command {
            Command::Named(line) => line.clone(),
            command => format!("{command:?}"),
        };
        self.keymap.bind(mode.into(), keys, command, label)?;
        self.sequence.clear();
        self.vim.clear();
        Ok(())
    }
    pub fn unbind_input(&mut self, key: KeyStroke) -> Result<(), BindingError> {
        self.keymap.unbind(Context::Prompt, &[key])
    }
    pub fn bind_input(&mut self, key: KeyStroke, input: Input) -> Result<(), BindingError> {
        let label = format!("{input:?}");
        self.keymap.bind_input(key, input, label)
    }
    pub fn unbind(&mut self, mode: EditMode, keys: &[KeyStroke]) -> Result<(), BindingError> {
        self.sequence.clear();
        self.vim.clear();
        self.keymap.unbind(mode.into(), keys)
    }
    /// Registers a Rust command under a name that is not built in.
    pub fn register_command(
        &mut self,
        name: impl Into<String>,
        handler: CommandHandler,
    ) -> Result<(), String> {
        self.registry.register(name, handler)
    }
    pub fn keymap(&self) -> &Keymap {
        &self.keymap
    }
    pub fn registry(&self) -> &Registry {
        &self.registry
    }
    /// Whether a Vim command failed since `clear_failed`.
    pub fn failed(&self) -> bool {
        self.failed
    }
    pub fn clear_failed(&mut self) {
        self.failed = false;
    }
    /// The register a macro is being recorded into.
    /// Commands of the hooks for an event whose parameter they match.
    pub fn hooks(&self, event: &str, parameter: &str) -> Vec<String> {
        self.hooks.matching(event, parameter)
    }
    pub fn recording(&self) -> Option<char> {
        self.vim.replay.recording()
    }
    pub fn editor_caret(&self) -> Option<usize> {
        self.vim.caret()
    }
    pub fn edit_mode(&self) -> EditMode {
        self.mode
    }
    pub fn input_hint(&self) -> String {
        if self.sequence.active() {
            self.sequence.hint()
        } else if self.vim.active() {
            self.vim.hint()
        } else {
            format!("{:?}  {}", self.mode, help::HINT)
        }
    }
    /// Keys typed toward an unfinished binding or Vim command, if any.
    pub fn pending(&self) -> Option<String> {
        if self.sequence.active() {
            Some(key_notation(self.sequence.keys()))
        } else if self.vim.active() {
            Some(self.vim.hint())
        } else {
            None
        }
    }
    /// The next keys of a pending multi-key binding, each with the
    /// documentation of its command, for a key hint popup.
    pub fn continuations(&self) -> Vec<(String, String)> {
        if !self.sequence.active() {
            return vec![];
        }
        self.keymap
            .continuations(self.mode.into(), self.sequence.keys())
            .into_iter()
            .map(|(key, label)| {
                let doc = self.registry.doc(&label);
                let text = if doc.is_empty() { label } else { doc };
                (key_notation(&[key]), text)
            })
            .collect()
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
        self.vim.clear();
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
        Ok(match layer.handle(Input::Cancel, app, time)? {
            Transition::Active(response) | Transition::Closed(response) => response,
            Transition::Blocked => Response::default(),
        })
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
            && let Some(Layer::Search { session, .. }) = &self.active
        {
            if let Some(backward) = session.vim_direction() {
                self.vim.search_backward = backward;
            }
            if session.query().is_valid() {
                self.vim.last_search = Some(session.query().clone());
            }
        }
        let Some(layer) = &mut self.active else {
            return Ok(InputResult::Pass);
        };
        let field = layer.history().map(|(kind, text)| (kind, text.to_owned()));
        if let Some((kind, text)) = &field {
            let lines = &mut self.history[*kind];
            // Up and Down recall in search, and at the command line while it
            // is empty or shows a recalled line; elsewhere they move through
            // candidates.
            let backward = match input {
                Input::History { backward } => Some(backward),
                Input::Candidate {
                    motion: motion @ (ListMotion::Previous | ListMotion::Next),
                    ..
                } if *kind == history::SEARCH || text.is_empty() || lines.showing(text) => {
                    Some(matches!(motion, ListMotion::Previous))
                }
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
        let transition = layer.handle(input, app, time)?;
        if confirm
            && matches!(transition, Transition::Closed(_))
            && let Some((kind, text)) = field
        {
            self.history[kind].record(&text);
        }
        Ok(self
            .transition(transition)
            .map_or(InputResult::Blocked, InputResult::Handled))
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
        self.vim.marks.observe(update);
        let group_end = if update.active_changed {
            self.end_insert_group(app, time)
        } else {
            vec![]
        };
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
            self.vim.clear();
            if update.active_changed || matches!(self.mode, EditMode::Visual | EditMode::VisualLine)
            {
                self.vim.reset();
                if matches!(self.mode, EditMode::Visual | EditMode::VisualLine) {
                    self.mode = EditMode::Normal;
                }
            }
        }
        if matches!(self.mode, EditMode::Visual | EditMode::VisualLine)
            && update
                .edit
                .as_ref()
                .is_some_and(|edit| edit.selection_changed)
            && !self.vim_visual_valid(app)
        {
            self.mode = EditMode::Normal;
            self.vim.reset();
        }
        let Some(layer) = &mut self.active else {
            let mut response = self.vim_normalize(app, time);
            response.events.extend(group_end);
            return Ok(response);
        };
        let transition = layer.observe(app, update, time)?;
        let mut response = self.transition(transition).unwrap_or_default();
        response.events.extend(group_end);
        Ok(response)
    }
    fn end_insert_group(&mut self, app: &Application, time: Duration) -> Vec<Event> {
        let Some(view) = self.vim.insert_view.take().and_then(|id| app.view(id)) else {
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
