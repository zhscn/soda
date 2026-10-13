//! Owner-thread command loop shared by frontends. It owns application and modal
//! state, reduces every update in order, and executes bounded background tasks.
use crate::{
    application::{Application, Event, Operation, Update, ViewId},
    core::{ByteOffset, EditError},
    files::{FileCompletion, FileRunner},
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

pub struct Runtime {
    // Workers drop before the application so in-progress file writes can finish.
    files: FileRunner,
    picker: PickerRunner,
    app: Application,
    layers: Layers,
    file_root: PathBuf,
    message: String,
    epoch: Instant,
    quit: bool,
    dirty: bool,
}
impl Runtime {
    pub fn new(file_root: PathBuf) -> io::Result<Self> {
        Self::with_application(Application::default(), file_root)
    }
    pub fn with_application(app: Application, file_root: PathBuf) -> io::Result<Self> {
        if !file_root.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Runtime requires an absolute file root",
            ));
        }
        Ok(Self {
            files: FileRunner::new()?,
            picker: PickerRunner::new()?,
            app,
            layers: Layers::default(),
            file_root,
            message: String::new(),
            epoch: Instant::now(),
            quit: false,
            dirty: true,
        })
    }
    pub fn start(&mut self, path: Option<PathBuf>) {
        self.command(Command::New);
        if let Some(path) = path {
            self.dispatch(Event::Open(path));
        }
    }
    pub fn app(&self) -> &Application {
        &self.app
    }
    pub fn layer(&self) -> Option<&Layer> {
        self.layers.active()
    }
    pub fn message(&self) -> &str {
        &self.message
    }
    pub fn quit_requested(&self) -> bool {
        self.quit
    }
    pub fn take_redraw(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }
    pub fn resize(&mut self, editor_rows: usize, picker_rows: usize) {
        self.layers.set_page_rows(editor_rows);
        self.layers.resize_help(editor_rows);
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
        let result = self
            .layers
            .route_input(input, &self.app, time, &self.file_root);
        self.input_result(result, time);
    }
    pub fn command(&mut self, command: Command) {
        self.command_at(command, self.epoch.elapsed());
    }
    pub fn command_at(&mut self, command: Command, time: Duration) {
        let result = self
            .layers
            .execute(command, &self.app, time, &self.file_root);
        self.input_result(result, time);
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
        self.reduce(event, time)
    }
    fn reduce(&mut self, event: Event, time: Duration) -> bool {
        let operation = event.operation();
        match self.app.dispatch(event) {
            Ok(update) => self.accept(update, time),
            Err(error) => {
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
        self.dirty |= update.active_changed
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
        self.quit |= response.quit;
        true
    }
    fn interaction_failed(&mut self, error: EditError, time: Duration) {
        if let Ok(response) = self.layers.close(&self.app, time) {
            self.respond(response, time);
        }
        self.message = error.to_string();
        self.dirty = true;
    }
    /// Bounded completion reduction prevents workers from monopolizing input.
    pub fn poll(&mut self) {
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
        self.dispatch(Event::PollFiles);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::editor::Command;
    use crate::interaction::Command as Action;
    use crate::{
        editor::Language,
        interaction::{Key as KeyCode, KeyStroke, Layer as Prompt, UserInput as TerminalEvent},
    };
    struct KeyModifiers;
    impl KeyModifiers {
        const NONE: u8 = 0;
        const CONTROL: u8 = 1;
        const SHIFT: u8 = 2;
    }
    fn key_with(code: KeyCode, modifiers: u8) -> KeyStroke {
        KeyStroke {
            control: modifiers & 1 != 0,
            shift: modifiers & 2 != 0,
            ..KeyStroke::plain(code)
        }
    }
    fn host() -> Runtime {
        let mut runtime = Runtime::new(PathBuf::from("/")).unwrap();
        runtime.start(None);
        runtime
    }

    fn key(code: KeyCode) -> TerminalEvent {
        TerminalEvent::Key(key_with(code, KeyModifiers::NONE))
    }
    #[test]
    fn path_prompt_owns_input_and_stays_bound_to_original_document() {
        let mut host = host();
        let first = host.app.active_view().unwrap();
        let document = host.app.view(first).unwrap().document_id;
        host.command(Action::Save { choose_path: true });
        host.input(TerminalEvent::Paste("目录/file.txt".into()));
        host.dispatch(Event::NewDocument(Language::PlainText));
        let Some(Prompt::Save(target, field)) = host.layers.active() else {
            panic!()
        };
        assert_eq!(*target, document);
        assert_eq!(field.text(), "目录/file.txt");
        assert!(
            host.app
                .workspace()
                .editor(document)
                .unwrap()
                .state()
                .snapshot()
                .is_empty()
        );
        host.input(key(KeyCode::Esc));
        assert!(host.layers.active().is_none());
    }
    #[test]
    fn bracketed_paste_is_one_undoable_edit() {
        let mut host = host();
        host.input(TerminalEvent::Paste("a\r\n中🦀".into()));
        let document = host
            .app
            .view(host.app.active_view().unwrap())
            .unwrap()
            .document_id;
        assert_eq!(
            host.app
                .workspace()
                .editor(document)
                .unwrap()
                .state()
                .snapshot()
                .text(),
            "a\r\n中🦀"
        );
        host.command(Action::Edit(Command::Undo));
        assert!(
            host.app
                .workspace()
                .editor(document)
                .unwrap()
                .state()
                .snapshot()
                .is_empty()
        );
    }
    #[test]
    fn close_prompts_for_dirty_buffer_and_last_clean_buffer_can_close() {
        let mut host = host();
        host.command(Action::Close);
        assert!(host.app.active_view().is_none());
        host.command(Action::New);
        let view = host.app.active_view().unwrap();
        host.command(Action::Edit(Command::InsertText("unsaved".into())));
        host.command(Action::Close);
        assert_eq!(host.app.active_view(), Some(view));
        assert!(matches!(host.layers.active(), Some(Prompt::Exit(_))));
        host.input(key(KeyCode::Esc));
        host.command(Action::Edit(Command::Undo));
        host.command(Action::Close);
        assert!(host.app.active_view().is_none());
    }
    #[test]
    fn quit_checks_hidden_documents_and_waits_for_pending_saves() {
        let directory = tempfile::tempdir().unwrap();
        let mut host = host();
        host.command(Action::Edit(Command::InsertText("dirty".into())));
        let document = host
            .app
            .view(host.app.active_view().unwrap())
            .unwrap()
            .document_id;
        host.dispatch(Event::NewDocument(Language::PlainText));
        host.command(Action::Quit);
        assert!(matches!(host.layers.active(), Some(Prompt::Exit(_))));
        host.input(key(KeyCode::Esc));
        assert!(!host.quit);
        let update = host
            .app
            .dispatch(Event::Save {
                document,
                target: Some(directory.path().join("a.txt")),
            })
            .unwrap();
        host.command(Action::Quit);
        assert!(host.layers.active().is_none());
        assert!(!host.quit);
        assert!(host.message.contains("Save in progress"));
        drop(update);
        host.dispatch(Event::PollFiles);
        host.command(Action::Quit);
        host.input(key(KeyCode::Char('y')));
        assert!(host.quit);
    }
    #[test]
    fn search_input_is_modal_and_cancel_restores_selection() {
        let mut host = host();
        host.command(Action::Edit(Command::InsertText("one two one".into())));
        host.command(Action::Edit(Command::SetSelection(
            crate::core::Selection::caret(0),
        )));
        let view = host.app.active_view().unwrap();
        let state = |host: &Runtime| {
            let v = host.app.view(view).unwrap();
            host.app
                .workspace()
                .editor(v.document_id)
                .unwrap()
                .model()
                .session(v.session_id)
                .unwrap()
                .selection()
        };
        host.input(TerminalEvent::Key(key_with(
            KeyCode::Char('f'),
            KeyModifiers::CONTROL,
        )));
        host.input(TerminalEvent::Paste("one".into()));
        assert_eq!(state(&host), crate::core::Selection { anchor: 0, head: 3 });
        host.input(key(KeyCode::F(3)));
        assert_eq!(
            state(&host),
            crate::core::Selection {
                anchor: 8,
                head: 11
            }
        );
        host.input(TerminalEvent::Key(key_with(
            KeyCode::Char('z'),
            KeyModifiers::CONTROL,
        )));
        assert_eq!(
            state(&host),
            crate::core::Selection {
                anchor: 8,
                head: 11
            }
        );
        host.input(key(KeyCode::Esc));
        assert_eq!(state(&host), crate::core::Selection::caret(0));
        assert!(host.layers.active().is_none());
    }
    #[test]
    fn search_confirmation_repeats_in_editor_and_paste_replaces_match() {
        let mut host = host();
        host.command(Action::Edit(Command::InsertText("one two one".into())));
        host.command(Action::Edit(Command::SetSelection(
            crate::core::Selection::caret(0),
        )));
        host.command(Action::Search);
        host.input(TerminalEvent::Paste("one".into()));
        host.input(key(KeyCode::Enter));
        host.input(key(KeyCode::F(3)));
        host.input(TerminalEvent::Paste("中".into()));
        let view = host.app.view(host.app.active_view().unwrap()).unwrap();
        assert_eq!(
            host.app
                .workspace()
                .editor(view.document_id)
                .unwrap()
                .state()
                .snapshot()
                .text(),
            "one two 中"
        );
    }
    #[test]
    fn prompt_selection_cursor_and_modifier_events_have_distinct_effects() {
        let mut host = host();
        host.command(Action::Open);
        host.input(TerminalEvent::Paste("路径/file".into()));
        host.dirty = false;
        host.input(TerminalEvent::Key(key_with(
            KeyCode::Enter,
            KeyModifiers::CONTROL,
        )));
        assert!(host.layers.active().is_some());
        assert!(!host.dirty);
        host.input(TerminalEvent::Key(key_with(
            KeyCode::Left,
            KeyModifiers::SHIFT,
        )));
        assert!(host.dirty);
        let Some(Prompt::Open(field)) = host.layers.active() else {
            panic!()
        };
        assert_eq!(&field.text()[field.selection().range()], "e");
        host.input(TerminalEvent::Paste("X".into()));
        let Some(Prompt::Open(field)) = host.layers.active() else {
            panic!()
        };
        assert_eq!(field.text(), "路径/filX");
        host.dirty = false;
        let mut release = key_with(KeyCode::Char('a'), KeyModifiers::NONE);
        release.release = true;
        host.input(TerminalEvent::Key(release));
        assert!(!host.dirty);
        host.input(key(KeyCode::Esc));
        assert!(host.layers.active().is_none());
        assert!(host.dirty);
    }
    #[test]
    fn response_batch_stops_after_failure_and_does_not_quit() {
        let mut runtime = host();
        let view = runtime.app.active_view().unwrap();
        let document = runtime.app.view(view).unwrap().document_id;
        let response = Response {
            events: vec![
                Event::CloseDocument {
                    document,
                    discard: false,
                },
                Event::Edit {
                    view,
                    command: Command::TypeChar('x'),
                    time: Duration::ZERO,
                },
                Event::NewDocument(Language::PlainText),
            ],
            quit: true,
            ..Response::default()
        };
        assert!(!runtime.respond(response, Duration::ZERO));
        assert_eq!(runtime.app.workspace().documents().count(), 0);
        assert!(!runtime.quit_requested());
        assert!(runtime.message().contains("unknown view"));
    }
    #[test]
    fn help_resize_does_not_apply_editing_viewport_feedback() {
        let mut runtime = host();
        let view = runtime.app.active_view().unwrap();
        runtime.command(Action::Edit(Command::InsertText(
            "abcdefghijklmnopqrstuvwxyz".into(),
        )));
        let before = runtime.app.view(view).unwrap().viewport;
        runtime.command(Action::Help);
        runtime.resize(4, 4);
        runtime.update_viewport(view, before.anchor.offset, 20);
        assert_eq!(runtime.app.view(view).unwrap().viewport, before);
        runtime.input(key(KeyCode::Esc));
        runtime.update_viewport(view, before.anchor.offset, 20);
        assert_eq!(
            runtime.app.view(view).unwrap().viewport.horizontal_column,
            20
        );
    }
    #[test]
    fn new_help_session_inherits_geometry_before_first_render() {
        let mut runtime = host();
        runtime.resize(5, 3);
        runtime.command(Action::Help);
        let Some(Layer::Help(session)) = runtime.layer() else {
            panic!()
        };
        assert_eq!(session.lines().count(), 5);
    }
}
