//! Owner-thread command loop shared by frontends. It owns application and modal
//! state, reduces every update in order, and executes bounded background tasks.
use crate::{
    application::{Application, ClipboardAction, Event, Notice, Operation, Update, ViewId},
    core::{ByteOffset, EditError},
    files::{FileCompletion, FileRunner, paths::PathRunner},
    interaction::{
        Command, InputResult, Layer, Layers, Message, Response, UserInput,
        picker::{PickerEffect, PickerRunner},
    },
};
use std::{
    io,
    path::PathBuf,
    time::{Duration, Instant},
};

mod completion;
mod grep;
mod lsp;
mod lua;
mod process;
mod run;
mod shell;
mod state;

/// Messages the log keeps.
const MESSAGE_LIMIT: usize = 1000;
const MESSAGES: &str = "*messages*";
/// Rounds of hooks firing further hooks before they stop.
const MAX_HOOK_DEPTH: usize = 16;

/// The system clipboard as a frontend reaches it. Copies are stored after
/// they happen; pastes load first, and text that differs from the
/// application clipboard replaces it.
pub trait SystemClipboard {
    fn store(&mut self, text: &str);
    fn load(&mut self) -> Option<String>;
}
/// Whether a key pages a popup, and which way. These keys page the text
/// otherwise, and every other key closes the popup.
fn popup_page(key: &crate::interaction::KeyStroke) -> Option<bool> {
    use crate::interaction::Key;
    match (key.code, key.control, key.alt) {
        (Key::PageDown, false, false) | (Key::Char('v'), true, false) => Some(true),
        (Key::PageUp, false, false) | (Key::Char('v'), false, true) => Some(false),
        _ => None,
    }
}

pub struct Runtime {
    // Workers drop before the application so in-progress file writes can finish.
    files: FileRunner,
    shell: shell::ShellRunner,
    grep: grep::GrepRunner,
    completions: completion::Completions,
    lsp: lsp::Lsp,
    run: run::RunRunner,
    picker: PickerRunner,
    paths: PathRunner,
    app: Application,
    layers: Layers,
    clipboard: Option<Box<dyn SystemClipboard>>,
    /// The application clipboard revision last stored or loaded.
    clipboard_revision: u64,
    message: String,
    epoch: Instant,
    /// Input `.` and macros still have to replay, next first, as Vim's
    /// typeahead: a replay started while replaying goes to the front.
    replay: std::collections::VecDeque<UserInput>,
    replaying: bool,
    /// Hook events waiting to run: the event, its parameter and the view
    /// its commands act on.
    notices: Vec<(&'static str, String, Option<ViewId>)>,
    hooking: bool,
    /// Recent messages, oldest first, and the one last recorded.
    messages: std::collections::VecDeque<String>,
    logged: String,
    /// Caret positions of files closed earlier, and of files just opened
    /// that should go back to them.
    state: state::State,
    restores: Vec<(ViewId, usize, usize)>,
    /// The mode and focused view hooks last saw.
    seen: (crate::interaction::EditMode, Option<ViewId>),
    quit: bool,
    suspend: bool,
    /// A command, or an event it produced, failed since this was cleared.
    failed: bool,
    lua: Option<lua::Host>,
    /// Lua work waiting for the host, which runs one request at a time.
    /// Each with the view it acts on: where it was asked for.
    lua_queue: std::collections::VecDeque<(lua::Request, Option<ViewId>)>,
    lua_running: bool,
    dirty: bool,
    /// Text in a box by the caret, until the next input.
    popup: Option<String>,
    /// How many lines of the popup are scrolled past; drawing keeps it in
    /// range, since only drawing knows how the text wraps.
    popup_scroll: std::cell::Cell<usize>,
    /// The lines of the popup in view when it was last drawn.
    popup_page: std::cell::Cell<usize>,
}
impl Runtime {
    /// A runtime with `root` as a project, whatever the directory holds.
    pub fn new(root: PathBuf) -> io::Result<Self> {
        Self::with_application(Application::default(), root)
    }
    /// A runtime started in `directory`, which is only where documents with
    /// nothing else to go by stand.
    pub fn started_in(directory: PathBuf) -> io::Result<Self> {
        Self::with_application_in(Application::default(), directory)
    }
    pub fn with_application(mut app: Application, root: PathBuf) -> io::Result<Self> {
        app.add_project(root.clone());
        Self::with_application_in(app, root)
    }
    fn with_application_in(mut app: Application, file_root: PathBuf) -> io::Result<Self> {
        if !file_root.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Runtime requires an absolute file root",
            ));
        }
        app.set_start(file_root);
        Ok(Self {
            files: FileRunner::new()?,
            shell: shell::ShellRunner::default(),
            grep: grep::GrepRunner::default(),
            completions: completion::Completions::default(),
            lsp: lsp::Lsp::default(),
            run: run::RunRunner::default(),
            picker: PickerRunner::new()?,
            paths: PathRunner::new()?,
            app,
            layers: Layers::default(),
            clipboard: None,
            clipboard_revision: 0,
            message: String::new(),
            epoch: Instant::now(),
            replay: Default::default(),
            replaying: false,
            notices: vec![],
            hooking: false,
            messages: Default::default(),
            logged: String::new(),
            state: Default::default(),
            restores: vec![],
            seen: Default::default(),
            quit: false,
            suspend: false,
            failed: false,
            lua: None,
            lua_queue: Default::default(),
            lua_running: false,
            dirty: true,
            popup: None,
            popup_scroll: Default::default(),
            popup_page: Default::default(),
        })
    }
    /// Opens the file given on the command line, or an untitled document.
    pub fn start(&mut self, path: Option<PathBuf>) {
        match path {
            Some(path) => {
                self.dispatch(Event::Open(path));
            }
            None => self.command(Command::New),
        }
    }
    pub fn set_system_clipboard(&mut self, clipboard: Box<dyn SystemClipboard>) {
        self.clipboard = Some(clipboard);
        self.clipboard_revision = self.app.clipboard_revision();
    }
    pub fn app(&self) -> &Application {
        &self.app
    }
    pub fn layer(&self) -> Option<&Layer> {
        self.layers.active()
    }
    pub fn bind(
        &mut self,
        mode: crate::interaction::EditMode,
        keys: &[crate::interaction::KeyStroke],
        command: Command,
    ) -> Result<(), crate::interaction::BindingError> {
        self.layers.bind(mode, keys, command)?;
        self.dirty = true;
        Ok(())
    }
    pub fn unbind_input(
        &mut self,
        key: crate::interaction::KeyStroke,
    ) -> Result<(), crate::interaction::BindingError> {
        self.layers.unbind_input(key)
    }
    pub fn bind_input(
        &mut self,
        key: crate::interaction::KeyStroke,
        input: crate::interaction::Input,
    ) -> Result<(), crate::interaction::BindingError> {
        self.layers.bind_input(key, input)
    }
    pub fn unbind(
        &mut self,
        mode: crate::interaction::EditMode,
        keys: &[crate::interaction::KeyStroke],
    ) -> Result<(), crate::interaction::BindingError> {
        self.layers.unbind(mode, keys)?;
        self.dirty = true;
        Ok(())
    }
    pub fn register_command(
        &mut self,
        name: impl Into<String>,
        handler: crate::interaction::CommandHandler,
    ) -> Result<(), String> {
        self.layers.register_command(name, handler)
    }
    /// Applies configuration text; the first error is also shown as the
    /// status message, prefixed by `origin` and its line number.
    pub fn source(&mut self, origin: &str, text: &str) -> Vec<(usize, String)> {
        let crate::interaction::Sourced {
            mut errors,
            settings,
        } = self.layers.source(text);
        for (line, command) in settings {
            self.message.clear();
            self.command(command);
            if !self.message.is_empty() {
                errors.push((line, std::mem::take(&mut self.message)));
            }
        }
        errors.sort_by_key(|(line, _)| *line);
        for (line, error) in &errors {
            self.log(format!("{origin}:{line}: {error}"));
        }
        if let Some((line, error)) = errors.first() {
            self.message = format!("{origin}:{line}: {error}");
            self.dirty = true;
            // Every error is in the log already.
            self.logged = self.message.clone();
        }
        errors
    }
    pub fn report(&mut self, message: String) {
        self.message = message;
        self.dirty = true;
    }
    pub fn shell_running(&self) -> bool {
        self.shell.busy()
    }
    pub fn grep_running(&self) -> bool {
        self.grep.busy()
    }
    pub fn run_running(&self) -> bool {
        self.run.busy()
    }
    pub fn editor_caret(&self) -> Option<usize> {
        self.layers.editor_caret()
    }
    pub fn edit_mode(&self) -> crate::interaction::EditMode {
        self.layers.edit_mode()
    }
    pub fn command_history(&self) -> &[String] {
        self.layers.command_history()
    }
    pub fn search_history(&self) -> &[String] {
        self.layers.search_history()
    }
    /// The register a macro is being recorded into.
    pub fn recording(&self) -> Option<char> {
        self.layers.recording()
    }
    pub fn pending_keys(&self) -> Option<String> {
        self.layers.pending()
    }
    pub fn key_continuations(&self) -> Vec<(String, String)> {
        self.layers.continuations()
    }
    pub fn message(&self) -> &str {
        &self.message
    }
    pub fn quit_requested(&self) -> bool {
        self.quit
    }
    /// Whether `suspend` ran since the last call; the frontend stops the
    /// process and redraws when it continues.
    pub fn take_suspend(&mut self) -> bool {
        std::mem::take(&mut self.suspend)
    }
    pub fn take_redraw(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }
    /// The active window's text rows, for paging, when windows split the
    /// editing area; `resize` sets them to the whole area.
    /// The rows of text each window shows.
    pub fn set_window_rows(&mut self, rows: Vec<(ViewId, usize)>) {
        self.layers.set_window_rows(rows);
    }
    pub fn set_page_rows(&mut self, rows: usize) {
        self.layers.set_page_rows(rows);
    }
    /// The size of the editing area, for placing new side windows.
    pub fn set_editing_area(&mut self, width: u16, height: u16) {
        self.app.set_editing_area(width, height);
    }
    pub fn resize(&mut self, editor_rows: usize, picker_rows: usize) {
        self.layers.set_page_rows(editor_rows);
        // Help draws inside a bordered popup over the editing area.
        self.layers.resize_help(editor_rows.saturating_sub(2));
        self.layers.resize_picker(picker_rows);
        self.dirty = true;
    }
    /// Layout feedback is applied through the same update path as commands.
    /// Modal surfaces that hide the editing cursor preserve its viewport.
    pub fn update_viewport(&mut self, view: ViewId, anchor: ByteOffset, horizontal_column: usize) {
        if matches!(
            self.layer(),
            None | Some(Layer::Search { .. } | Layer::Replace(_))
        ) {
            self.dispatch(Event::SetViewport {
                view,
                anchor,
                horizontal_column,
            });
        }
    }
    pub fn input(&mut self, input: UserInput) {
        self.input_at(input, self.epoch.elapsed());
    }
    pub fn input_at(&mut self, input: UserInput, time: Duration) {
        if self.popup.is_some()
            && self.layer().is_none()
            && let UserInput::Key(key) = &input
            && let Some(forward) = popup_page(key)
        {
            let page = self.popup_page.get().max(1) as isize;
            self.scroll_popup(if forward { page } else { -page });
            return;
        }
        self.popup = None;
        let result = self
            .layers
            .route_input(input, &self.app, time, &self.app.root());
        self.input_result(result, time);
        self.settle(time);
        self.complete();
    }
    fn complete(&mut self) {
        let (request, changed) = self.layers.completion_sync(&self.app);
        if let Some(request) = request {
            self.ask_lua_sources(&request.asked);
            if request.asked.builtin {
                self.completions.request(request);
            }
        }
        self.dirty |= changed;
    }
    /// Lets documents start language servers.
    pub fn enable_lsp(&mut self) {
        self.lsp.enable();
    }
    /// The list of candidates to show under the caret.
    pub fn popup(&self) -> Option<&str> {
        self.popup.as_deref()
    }
    /// The popup's first line, for `page` lines in view out of `total`.
    pub fn popup_scroll(&self, page: usize, total: usize) -> usize {
        let scroll = self.popup_scroll.get().min(total.saturating_sub(page));
        self.popup_scroll.set(scroll);
        self.popup_page.set(page);
        scroll
    }
    pub fn scroll_popup(&mut self, lines: isize) {
        let scroll = self.popup_scroll.get().saturating_add_signed(lines);
        self.popup_scroll.set(scroll);
        self.dirty = true;
    }
    pub fn completion_popup(&self) -> Option<crate::interaction::completion::Popup> {
        self.layers.completion_popup()
    }
    pub fn command(&mut self, command: Command) {
        self.command_at(command, self.epoch.elapsed());
    }
    pub fn command_at(&mut self, command: Command, time: Duration) {
        let result = self
            .layers
            .execute(command, &self.app, time, &self.app.root());
        self.input_result(result, time);
        self.settle(time);
        self.complete();
    }
    fn input_result(&mut self, result: Result<InputResult, EditError>, time: Duration) {
        match result {
            Ok(InputResult::Handled(response)) => {
                self.respond(response, time);
            }
            Ok(InputResult::Pass | InputResult::Blocked) => {}
            Err(error) => self.interaction_failed(error, time),
        }
    }
    /// Returns false on failure. A response batch stops at its first failed
    /// event; preceding events are committed and their updates already observed.
    pub fn dispatch(&mut self, event: Event) -> bool {
        let time = match &event {
            Event::Edit { time, .. } | Event::Clipboard { time, .. } => *time,
            _ => self.epoch.elapsed(),
        };
        let done = self.reduce(event, time);
        self.settle(time);
        done
    }
    /// Buffer names and text of documents with unsaved edits.
    pub fn unsaved(&self) -> Vec<(String, String)> {
        let workspace = self.app.workspace();
        workspace
            .documents()
            .filter(|document| workspace.is_dirty(*document))
            .map(|document| {
                let editor = workspace.editor(document).unwrap();
                let text = editor.model().document().snapshot().text().to_owned();
                (self.app.document_name(document), text)
            })
            .collect()
    }
    /// Takes back what an earlier session left with `persist`.
    pub fn restore(&mut self, text: &str) {
        let mut state = state::State::parse(text);
        self.layers.restore_history(
            &std::mem::take(&mut state.commands),
            &std::mem::take(&mut state.searches),
        );
        self.state = state;
        self.layers.set_recent_files(self.state.recent());
    }
    /// What the next session should start from: histories and where the
    /// caret is in every file, the focused one most recent.
    pub fn persist(&mut self) -> String {
        let mut views: Vec<_> = self.app.views().map(|view| view.id).collect();
        let active = self.app.active_view();
        views.sort_by_key(|view| Some(*view) == active);
        for view in views {
            self.remember(view);
        }
        self.state.commands = self.layers.command_history().to_vec();
        self.state.searches = self.layers.search_history().to_vec();
        self.state.text()
    }
    /// Notes where a view of a file has its caret.
    fn remember(&mut self, view: ViewId) {
        let Some(view) = self.app.view(view) else {
            return;
        };
        let workspace = self.app.workspace();
        let Some(path) = workspace.file(view.document_id).and_then(|f| f.path()) else {
            return;
        };
        let editor = workspace.editor(view.document_id).unwrap();
        let document = editor.model().document();
        let head = editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head;
        let snapshot = document.snapshot();
        let line = snapshot.line_of(head).unwrap();
        let column = crate::core::logical_column_at(
            snapshot,
            ByteOffset(head),
            document.whitespace().tab_width,
        )
        .map_or(0, |column| column.0);
        self.state.remember(path.to_owned(), line, column);
        self.layers.set_recent_files(self.state.recent());
    }
    /// Ends an operation: runs hooks, then records a new message in the log.
    fn settle(&mut self, time: Duration) {
        if self.hooking {
            return;
        }
        for (view, line, column) in std::mem::take(&mut self.restores) {
            self.reduce(
                Event::Edit {
                    view,
                    command: crate::editor::Command::Goto { line, column },
                    time,
                },
                time,
            );
        }
        self.run_hooks(time);
        if self.message != self.logged {
            self.logged = self.message.clone();
            if !self.message.is_empty() {
                self.log(self.message.clone());
            }
        }
    }
    /// Keeps a message in the log and in `*messages*`, if it is open.
    fn log(&mut self, message: String) {
        if self.messages.len() == MESSAGE_LIMIT {
            self.messages.pop_front();
        }
        self.messages.push_back(message.clone());
        if self.app.workspace().scratch(MESSAGES).is_some() {
            let _ = self.app.dispatch(Event::AppendScratch {
                name: MESSAGES.into(),
                text: format!("\n{message}"),
            });
            self.dirty = true;
        }
    }
    /// Messages so far, oldest first.
    pub fn messages(&self) -> impl Iterator<Item = &str> {
        self.messages.iter().map(String::as_str)
    }
    /// Runs the hooks of the notices gathered so far, then of those their
    /// commands cause, up to a bound. Mode and focus are compared with what
    /// hooks last saw. A hook's command acts on the view that fired it and
    /// keeps the message it found unless it sets one.
    fn run_hooks(&mut self, time: Duration) {
        if self.hooking {
            return;
        }
        self.hooking = true;
        for round in 0.. {
            let now = (self.layers.edit_mode(), self.app.active_view());
            if now.0 != self.seen.0 {
                self.notices.push(("mode", now.0.name().into(), None));
            }
            if now.1 != self.seen.1
                && let Some(view) = now.1.and_then(|id| self.app.view(id))
            {
                let name = self.app.document_name(view.document_id);
                self.notices.push(("focus", name, None));
            }
            self.seen = now;
            if self.notices.is_empty() {
                break;
            }
            if round == MAX_HOOK_DEPTH {
                self.notices.clear();
                self.message = format!("Hooks stopped after {MAX_HOOK_DEPTH} nested rounds");
                self.dirty = true;
                break;
            }
            for (event, parameter, view) in std::mem::take(&mut self.notices) {
                for line in self.layers.hooks(event, &parameter) {
                    let _ = self.app.dispatch(Event::SetContext(view));
                    let message = std::mem::take(&mut self.message);
                    self.layers.set_hook(Some(parameter.clone()));
                    self.command_at(Command::Named(line), time);
                    self.layers.set_hook(None);
                    let _ = self.app.dispatch(Event::SetContext(None));
                    if self.message.is_empty() {
                        self.message = message;
                    }
                }
            }
        }
        self.hooking = false;
    }
    fn reduce(&mut self, event: Event, time: Duration) -> bool {
        let operation = event.operation();
        // Closing loses the caret; keep where it was for the next open.
        match &event {
            Event::CloseView(view) => self.remember(*view),
            Event::CloseDocument { document, .. } => {
                let views: Vec<_> = self
                    .app
                    .views()
                    .filter(|view| view.document_id == *document)
                    .map(|view| view.id)
                    .collect();
                views.into_iter().for_each(|view| self.remember(view));
            }
            _ => {}
        }
        // Named registers stay inside the editor.
        if let Event::Clipboard {
            action:
                ClipboardAction::Put {
                    register: None | Some('"' | '+' | '*'),
                    ..
                }
                | ClipboardAction::Paste,
            ..
        } = &event
        {
            self.load_clipboard();
        }
        match self.app.dispatch(event) {
            Ok(update) => {
                self.store_clipboard();
                self.accept(update, time)
            }
            Err(error) => {
                self.failed = true;
                if !matches!(
                    (&operation, &error),
                    (
                        Operation::Open { request: Some(_) },
                        crate::application::Error::File(crate::files::FileError::StaleCompletion)
                    )
                ) {
                    self.message = error.to_string();
                    let response = self
                        .layers
                        .application_failed(operation, self.message.clone());
                    self.respond(response, time);
                    self.dirty = true;
                }
                false
            }
        }
    }
    fn accept(&mut self, update: Update, time: Duration) -> bool {
        let response = self.layers.observe(&self.app, &update, time);
        for notice in &update.notices {
            let notice = match notice {
                Notice::Opened(view) => self.app.view(*view).map(|state| {
                    let document = state.document_id;
                    let editor = self.app.workspace().editor(document).unwrap();
                    let at_start = editor
                        .model()
                        .session(state.session_id)
                        .is_some_and(|session| session.selection().head == 0);
                    // A file opened at no particular place goes back to
                    // where its caret was.
                    if let Some((line, column)) = self
                        .app
                        .workspace()
                        .file(document)
                        .and_then(|file| file.path())
                        .and_then(|path| self.state.position(path))
                        .filter(|_| at_start)
                    {
                        self.restores.push((*view, line, column));
                    }
                    if let Some(path) = self.app.workspace().file(document).and_then(|f| f.path()) {
                        self.state.touch(path);
                        self.layers.set_recent_files(self.state.recent());
                    }
                    ("open", self.app.document_name(document), Some(*view))
                }),
                Notice::Created(view) => self.app.view(*view).map(|state| {
                    let kind = self.app.document_kind(state.document_id).to_owned();
                    ("new", kind, Some(*view))
                }),
                Notice::Closed(name) => Some(("close", name.clone(), None)),
            };
            self.notices.extend(notice);
        }
        self.dirty |= update.active_changed
            || update.windows_changed
            || update.options_changed
            || !update.changed_views.is_empty()
            || !update.closed_views.is_empty()
            || !update.files.is_empty()
            || !update.effects.is_empty();
        let reloaded = update
            .edit
            .as_ref()
            .and_then(|edit| edit.document.as_ref())
            .is_some_and(|document| document.origin == crate::editor::EditOrigin::Reload);
        for result in update.files {
            if let (Ok(file), false) = (&result.result, reloaded) {
                let view = self
                    .app
                    .active_view()
                    .filter(|id| self.app.view(*id).unwrap().document_id == file.document_id)
                    .or_else(|| {
                        let mut views = self.app.views();
                        views
                            .find(|view| view.document_id == file.document_id)
                            .map(|view| view.id)
                    });
                let path = file.path.to_string_lossy().into_owned();
                self.notices.push(("save", path, view));
            }
            self.message = match result.result {
                Ok(file) => format!(
                    "{} {}{}",
                    if reloaded { "Reloaded" } else { "Saved" },
                    file.path.display(),
                    if file.dirty {
                        " (newer edits remain)"
                    } else {
                        ""
                    }
                ),
                Err(error) => error.to_string(),
            };
        }
        for effect in update.effects {
            let operation = effect.key().into();
            if let Err(error) = self
                .files
                .submit(self.app.workspace().service().clone(), effect)
            {
                let error = error.to_string();
                let response = self.layers.application_failed(operation, error.clone());
                self.respond(response, time);
                self.dirty = true;
                // Rejected requests have been dropped and queued cancellation.
                self.reduce(Event::PollFiles, time);
                self.message = error;
            }
        }
        match response {
            Ok(response) => self.respond(response, time),
            Err(error) => {
                self.interaction_failed(error, time);
                false
            }
        }
    }
    fn respond(&mut self, response: Response, time: Duration) -> bool {
        match response.message {
            Message::Keep => {}
            Message::Clear => self.message.clear(),
            Message::Set(message) => self.message = message,
        }
        self.dirty |= response.redraw;
        for request in response.path_requests {
            self.paths.submit(request);
        }
        if let Some(request) = response.grep {
            self.message = match self.grep.submit(*request) {
                Ok(()) => "Searching…".into(),
                Err(error) => error,
            };
        }
        if let Some(request) = response.shell {
            self.message = match self.shell.submit(*request) {
                Ok(()) => "Running shell command…".into(),
                Err(error) => error,
            };
        }
        if response.messages {
            let text = self.messages.iter().cloned().collect::<Vec<_>>().join("\n");
            if self.reduce(
                Event::Scratch {
                    name: MESSAGES.into(),
                    text,
                    directory: self.app.directory(),
                },
                time,
            ) && let Some(view) = self.app.active_view()
            {
                // Start at the newest message, so that new ones are followed.
                let snapshot = self
                    .app
                    .workspace()
                    .editor(self.app.view(view).unwrap().document_id)
                    .unwrap()
                    .model()
                    .document()
                    .snapshot();
                let last = snapshot.line_start(snapshot.line_count() - 1).unwrap();
                self.reduce(
                    Event::Edit {
                        view,
                        command: crate::editor::Command::SetSelection(
                            crate::core::Selection::caret(last),
                        ),
                        time,
                    },
                    time,
                );
            }
        }
        if response.stop {
            let stopped = [self.run.stop(), self.shell.stop(), self.grep.stop()];
            // Quiet otherwise: Ctrl-C also cancels pending keys.
            if stopped.contains(&true) {
                self.message = "Stopped".into();
            }
        }
        if let Some(request) = response.run {
            let header = format!("$ {}", request.command);
            let cwd = request.cwd.clone();
            match self.run.submit(*request) {
                Ok(()) => {
                    self.reduce(
                        Event::Scratch {
                            name: crate::interaction::grep::RUN.into(),
                            text: header,
                            directory: cwd,
                        },
                        time,
                    );
                    self.message = "Running…".into();
                }
                Err(error) => self.message = error,
            }
        }
        for effect in response.effects {
            match effect {
                PickerEffect::Run(task) => {
                    if let Err(error) = self.picker.submit(task) {
                        let response = self.layers.picker_failed(error.to_string());
                        self.respond(response, time);
                    }
                }
                PickerEffect::Cancel(id) => self.picker.cancel(id),
            }
        }
        for event in response.events {
            if !self.reduce(event, time) {
                return false;
            }
        }
        if response.failed {
            self.failed = true;
            return false;
        }
        for command in response.commands {
            match self
                .layers
                .execute(command, &self.app, time, &self.app.root())
            {
                Ok(InputResult::Handled(response)) => {
                    if !self.respond(response, time) {
                        return false;
                    }
                }
                Ok(_) => return false,
                Err(error) => {
                    self.interaction_failed(error, time);
                    return false;
                }
            }
        }
        self.quit |= response.quit;
        self.suspend |= response.suspend;
        if !response.lua.is_empty() {
            let view = self.app.active_view();
            self.lua_queue.extend(
                response
                    .lua
                    .into_iter()
                    .map(|request| (lua::Request::from(request), view)),
            );
            self.run_lua();
        }
        for input in response.replay.into_iter().rev() {
            self.replay.push_front(input);
        }
        if !self.replaying && !self.replay.is_empty() {
            self.replay(time);
        }
        true
    }
    /// Routes `.` and macro input again. A failing command drops the rest,
    /// which is how a recursive macro ends; a bound on the number of inputs
    /// ends one that never fails.
    fn replay(&mut self, time: Duration) {
        self.replaying = true;
        self.layers.clear_failed();
        let mut budget = 1_000_000usize;
        while let Some(input) = self.replay.pop_front() {
            if budget == 0 {
                self.replay.clear();
                self.message = "Replay stopped after a million keys".into();
                break;
            }
            budget -= 1;
            let result = self
                .layers
                .route_replayed(input, &self.app, time, &self.app.root());
            self.input_result(result, time);
            if self.layers.failed() {
                self.replay.clear();
            }
        }
        self.replaying = false;
    }
    /// Whether copies and pastes go through the system clipboard.
    fn system_clipboard(&self) -> bool {
        self.app.options().choice(None, "clipboard") == "system"
    }
    fn load_clipboard(&mut self) {
        if !self.system_clipboard() {
            return;
        }
        let Some(text) = self.clipboard.as_mut().and_then(|system| system.load()) else {
            return;
        };
        if text.is_empty() || text == self.app.clipboard() {
            return;
        }
        // Text copied elsewhere pastes by line when it ends a line, as in Vim.
        let linewise = text.ends_with('\n');
        if self
            .app
            .dispatch(Event::SetClipboard { text, linewise })
            .is_ok()
        {
            self.clipboard_revision = self.app.clipboard_revision();
        }
    }
    fn store_clipboard(&mut self) {
        let revision = self.app.clipboard_revision();
        if revision == self.clipboard_revision {
            return;
        }
        self.clipboard_revision = revision;
        if !self.system_clipboard() {
            return;
        }
        if let Some(system) = &mut self.clipboard {
            system.store(self.app.clipboard());
        }
    }
    fn interaction_failed(&mut self, error: EditError, time: Duration) {
        self.failed = true;
        if let Ok(response) = self.layers.close(&self.app, time) {
            self.respond(response, time);
        }
        self.message = error.to_string();
        self.dirty = true;
    }
    /// Bounded completion reduction prevents workers from monopolizing input.
    pub fn poll(&mut self) {
        self.poll_lua();
        self.poll_lsp();
        for _ in 0..8 {
            match self.files.poll() {
                Ok(Some(FileCompletion::Open(completion))) => {
                    self.dispatch(Event::OpenFinished(completion));
                }
                Ok(Some(FileCompletion::Save(completion))) => {
                    self.dispatch(Event::SaveFinished(completion));
                }
                Ok(Some(FileCompletion::Failed { key, error })) => {
                    self.dispatch(Event::PollFiles);
                    let operation = key.into();
                    let response = self.layers.application_failed(operation, error.clone());
                    self.respond(response, self.epoch.elapsed());
                    self.message = error;
                    self.dirty = true;
                }
                Ok(None) => break,
                Err(error) => {
                    self.message = error.to_string();
                    self.dirty = true;
                    break;
                }
            }
        }
        for _ in 0..8 {
            match self.picker.poll() {
                Ok(Some(completion)) => {
                    let response = self.layers.picker_finished(completion);
                    self.respond(response, self.epoch.elapsed());
                }
                Ok(None) => break,
                Err(error) => {
                    let response = self.layers.picker_failed(error.to_string());
                    self.respond(response, self.epoch.elapsed());
                    break;
                }
            }
        }
        for _ in 0..8 {
            let Some(completion) = self.paths.poll() else {
                break;
            };
            let response = self.layers.path_finished(completion, &self.app);
            self.respond(response, self.epoch.elapsed());
        }
        if let Some((generation, items)) = self.completions.poll() {
            self.dirty |= self.layers.completion_results(
                generation,
                crate::interaction::completion::BUILTIN,
                items,
                false,
                &self.app,
            );
        }
        if let Some(completion) = self.shell.poll() {
            self.shell_finished(completion);
        }
        if let Some(completion) = self.grep.poll() {
            self.grep_finished(completion);
        }
        if let Some(output) = self.run.poll() {
            self.run_output(output);
        }
        self.dispatch(Event::PollFiles);
        self.settle(self.epoch.elapsed());
    }
    fn run_output(&mut self, output: run::RunOutput) {
        let mut text = String::new();
        for line in &output.lines {
            text.push('\n');
            text.push_str(line);
        }
        if let Some(exit) = &output.exit {
            text.push_str(&format!("\n\n[{exit}]"));
            self.message = format!("{}: {exit}", output.command);
            self.dirty = true;
        }
        self.dispatch(Event::AppendScratch {
            name: crate::interaction::grep::RUN.into(),
            text,
        });
    }
    fn grep_finished(&mut self, completion: grep::GrepCompletion) {
        self.dirty = true;
        let pattern = completion.pattern;
        match completion.result {
            Ok((_, 0, _)) => self.message = format!("No matches for {pattern}"),
            Ok((text, count, truncated)) => {
                let shown = self.dispatch(Event::Scratch {
                    name: crate::interaction::grep::SCRATCH.into(),
                    text,
                    directory: completion.root,
                });
                if shown {
                    if let Some(document) = self
                        .app
                        .workspace()
                        .scratch(crate::interaction::grep::SCRATCH)
                    {
                        let _ = self.app.dispatch(Event::GrepPattern {
                            document,
                            pattern: completion.regex,
                        });
                    }
                    self.message = format!(
                        "{count} matches for {pattern}{}",
                        if truncated { " (stopped there)" } else { "" }
                    );
                }
            }
            Err(error) => self.message = error,
        }
    }
    fn shell_finished(&mut self, completion: shell::ShellCompletion) {
        let name = completion.command;
        self.dirty = true;
        match (completion.result, completion.pipe) {
            (Ok(output), Some(target)) => {
                let tx = crate::core::Transaction::new(
                    target.version,
                    vec![crate::core::Change::new(target.range, output)],
                );
                let applied = self.dispatch(Event::Edit {
                    view: target.view,
                    command: crate::editor::Command::Apply(tx),
                    time: self.epoch.elapsed(),
                });
                self.message = if applied {
                    String::new()
                } else {
                    format!("{name}: document changed while it ran; output discarded")
                };
            }
            (Ok(output), None) => {
                let line = output.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
                self.message = if line.is_empty() {
                    format!("{name}: done")
                } else {
                    line.trim().to_owned()
                };
            }
            (Err(error), _) => self.message = format!("{name}: {error}"),
        }
    }
}

#[cfg(test)]
mod tests;
