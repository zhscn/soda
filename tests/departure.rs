use soda::{
    application::{Application, Effect, Event},
    editor::{Command as Edit, DocumentId, Language},
    interaction::{
        Command, InputResult, Key, KeyStroke, Layer, Layers, Message, Response, UserInput,
    },
};
use std::{path::Path, time::Duration};

struct Driver {
    app: Application,
    layers: Layers,
    effects: Vec<Effect>,
    quit: bool,
    error: String,
}
impl Driver {
    fn new() -> Self {
        let mut driver = Self {
            app: Application::default(),
            layers: Layers::default(),
            effects: vec![],
            quit: false,
            error: String::new(),
        };
        driver.event(Event::NewDocument(Language::PlainText));
        driver.command(Command::Edit(Edit::InsertText("local".into())));
        driver
    }
    fn document(&self) -> DocumentId {
        self.app
            .view(self.app.active_view().unwrap())
            .unwrap()
            .document_id
    }
    fn event(&mut self, event: Event) {
        match self.app.dispatch(event) {
            Ok(update) => {
                let response = self
                    .layers
                    .observe(&self.app, &update, Duration::ZERO)
                    .unwrap();
                self.effects.extend(update.effects);
                self.respond(response);
            }
            Err(error) => {
                self.error = error.to_string();
                let response = self
                    .layers
                    .application_failed(&self.app, self.error.clone());
                self.respond(response);
            }
        }
    }
    fn respond(&mut self, response: Response) {
        assert!(response.effects.is_empty());
        self.quit |= response.quit;
        if let Message::Set(message) = response.message {
            self.error = message;
        }
        for event in response.events {
            self.event(event);
        }
    }
    fn command(&mut self, command: Command) {
        let result = self
            .layers
            .execute(command, &self.app, Duration::ZERO, Path::new("/"))
            .unwrap();
        if let InputResult::Handled(response) = result {
            self.respond(response);
        }
    }
    fn input(&mut self, input: UserInput) {
        let result = self
            .layers
            .route_input(input, &self.app, Duration::ZERO, Path::new("/"))
            .unwrap();
        if let InputResult::Handled(response) = result {
            self.respond(response);
        }
    }
    fn key(&mut self, key: Key) {
        self.input(UserInput::Key(KeyStroke::plain(key)));
    }
    fn path(&mut self, path: &Path) {
        self.input(UserInput::Paste(path.to_str().unwrap().into()));
        self.key(Key::Enter);
    }
    fn finish_save(&mut self) {
        let Effect::Save(request) = self.effects.remove(0) else {
            panic!()
        };
        let completion = self.app.workspace().service().write(*request);
        self.event(Event::SaveFinished(completion));
    }
    fn bind(&mut self, path: &Path) {
        self.event(Event::Save {
            document: self.document(),
            target: Some(path.to_owned()),
        });
        self.finish_save();
    }
    fn text(&self, document: DocumentId) -> &str {
        self.app
            .workspace()
            .editor(document)
            .unwrap()
            .model()
            .document()
            .snapshot()
            .text()
    }
}
#[test]
fn close_unnamed_document_saves_before_removing_view() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut driver = Driver::new();
    let document = driver.document();
    driver.command(Command::Close);
    driver.key(Key::Char('s'));
    driver.path(&path);
    assert!(driver.app.workspace().editor(document).is_some());
    assert!(driver.app.workspace().is_saving(document));
    driver.finish_save();
    assert!(driver.app.workspace().editor(document).is_none());
    assert!(driver.layers.active().is_none());
    assert_eq!(std::fs::read_to_string(path).unwrap(), "local");
}
#[test]
fn cancelling_departure_does_not_cancel_an_in_progress_save() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut driver = Driver::new();
    let document = driver.document();
    driver.command(Command::Close);
    driver.key(Key::Char('s'));
    driver.path(&path);
    driver.key(Key::Esc);
    driver.finish_save();
    assert!(driver.app.workspace().editor(document).is_some());
    assert!(driver.layers.active().is_none());
    assert_eq!(std::fs::read_to_string(path).unwrap(), "local");
}
#[test]
fn newer_edits_after_save_request_require_another_decision() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut driver = Driver::new();
    let view = driver.app.active_view().unwrap();
    let document = driver.document();
    driver.command(Command::Close);
    driver.key(Key::Char('s'));
    driver.path(&path);
    driver.event(Event::Edit {
        view,
        command: Edit::InsertText(" newer".into()),
        time: Duration::ZERO,
    });
    driver.finish_save();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "local");
    assert_eq!(driver.text(document), "local newer");
    assert!(
        driver
            .layers
            .active()
            .unwrap()
            .presentation()
            .text
            .contains("Newer edits remain")
    );
    driver.key(Key::Char('s'));
    driver.finish_save();
    assert!(driver.app.workspace().editor(document).is_none());
    assert_eq!(std::fs::read_to_string(path).unwrap(), "local newer");
}
#[test]
fn save_failure_keeps_document_and_dialog_available_for_retry_or_cancel() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut driver = Driver::new();
    driver.bind(&path);
    driver.command(Command::Edit(Edit::InsertText(" changed".into())));
    std::fs::write(&path, "external").unwrap();
    let document = driver.document();
    driver.command(Command::Close);
    driver.key(Key::Char('s'));
    driver.finish_save();
    assert_eq!(driver.text(document), "local changed");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "external");
    assert!(matches!(driver.layers.active(), Some(Layer::Exit(_))));
    assert!(
        driver
            .layers
            .active()
            .unwrap()
            .presentation()
            .text
            .contains("disk content changed")
    );
    driver.key(Key::Esc);
    assert!(!driver.quit);
    assert_eq!(driver.text(document), "local changed");
}
#[test]
fn quit_decisions_cover_hidden_documents_and_cancel_preserves_discarded_buffers() {
    let mut driver = Driver::new();
    let first = driver.document();
    driver.command(Command::New);
    driver.command(Command::Edit(Edit::InsertText("second".into())));
    let second = driver.document();
    driver.command(Command::Quit);
    driver.key(Key::Char('d'));
    let Some(Layer::Exit(session)) = driver.layers.active() else {
        panic!()
    };
    assert_eq!(session.document(), second);
    driver.key(Key::Esc);
    assert!(!driver.quit);
    assert_eq!(driver.text(first), "local");
    assert_eq!(driver.text(second), "second");
    driver.command(Command::Quit);
    driver.key(Key::Char('d'));
    driver.key(Key::Char('d'));
    assert!(driver.quit);
}
#[test]
fn edits_after_a_discard_decision_are_not_silently_discarded() {
    let mut driver = Driver::new();
    let first_view = driver.app.active_view().unwrap();
    let first = driver.document();
    driver.command(Command::New);
    driver.command(Command::Edit(Edit::InsertText("second".into())));
    driver.command(Command::Quit);
    driver.key(Key::Char('d'));
    driver.event(Event::Edit {
        view: first_view,
        command: Edit::InsertText(" newer".into()),
        time: Duration::ZERO,
    });
    driver.key(Key::Char('d'));
    assert!(!driver.quit);
    let Some(Layer::Exit(session)) = driver.layers.active() else {
        panic!()
    };
    assert_eq!(session.document(), first);
}
#[test]
fn reload_protects_local_edits_and_explicit_discard_loads_disk() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("new.txt");
    let mut driver = Driver::new();
    driver.bind(&path);
    driver.command(Command::Edit(Edit::InsertText(" changed".into())));
    let document = driver.document();
    std::fs::write(&path, "external").unwrap();
    driver.command(Command::Reload);
    driver.key(Key::Esc);
    assert_eq!(driver.text(document), "local changed");
    driver.command(Command::Reload);
    driver.key(Key::Char('d'));
    assert_eq!(driver.text(document), "external");
    assert!(driver.layers.active().is_none());
    driver.command(Command::Edit(Edit::Undo));
    assert_eq!(driver.text(document), "local changed");
}

#[test]
fn path_preflight_failure_retains_input_for_correction() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("missing").join("file.txt");
    let mut driver = Driver::new();
    let document = driver.document();
    driver.command(Command::Close);
    driver.key(Key::Char('s'));
    driver.path(&path);
    assert!(driver.effects.is_empty());
    let presentation = driver.layers.active().unwrap().presentation();
    assert!(presentation.cursor.is_some());
    assert!(presentation.text.contains(path.to_str().unwrap()));
    assert_eq!(driver.text(document), "local");
    driver.key(Key::Esc);
    assert!(driver.layers.active().is_none());
}
#[test]
fn dropped_save_request_returns_to_decision_instead_of_closing() {
    let directory = tempfile::tempdir().unwrap();
    let mut driver = Driver::new();
    let document = driver.document();
    driver.command(Command::Close);
    driver.key(Key::Char('s'));
    driver.path(&directory.path().join("file.txt"));
    driver.effects.clear();
    driver.event(Event::PollFiles);
    assert!(driver.app.workspace().editor(document).is_some());
    let presentation = driver.layers.active().unwrap().presentation();
    assert!(
        presentation.cursor.is_some(),
        "cancelled save must return to the path prompt"
    );
    assert!(!presentation.text.starts_with("Saving "));
    driver.key(Key::Enter);
    driver.finish_save();
    assert!(driver.app.workspace().editor(document).is_none());
    assert!(!driver.quit);
}

#[test]
fn reload_undo_restores_the_initiating_views_directed_selection() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("file.txt");
    let mut driver = Driver::new();
    driver.bind(&path);
    let document = driver.document();
    let view = driver.app.active_view().unwrap();
    let original = soda::core::Selection { anchor: 3, head: 2 };
    driver.command(Command::Edit(Edit::SetSelection(original)));
    std::fs::write(path, "XYZ").unwrap();
    driver.command(Command::Reload);
    driver.command(Command::Edit(Edit::Undo));
    assert_eq!(driver.text(document), "local");
    let session = driver.app.view(view).unwrap().session_id;
    assert_eq!(
        driver
            .app
            .workspace()
            .editor(document)
            .unwrap()
            .model()
            .session(session)
            .unwrap()
            .selection(),
        original
    );
}
