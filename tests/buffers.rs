use soda::{
    application::Event,
    interaction::{Command, Key, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;
fn runtime() -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(soda::interaction::EditMode::Insert));
    r
}
fn key(r: &mut Runtime, code: Key) {
    r.input(UserInput::Key(KeyStroke::plain(code)));
}
#[test]
fn switch_reuses_a_view_without_preview_and_cancel_leaves_focus() {
    let mut r = runtime();
    let first = r.app().active_view().unwrap();
    r.command(Command::New);
    let second = r.app().active_view().unwrap();
    r.command(Command::Named("buffer".into()));
    assert_eq!(r.app().active_view(), Some(second));
    assert!(matches!(r.layer(), Some(Layer::CommandLine(s)) if s.rows().len() == 2));
    key(&mut r, Key::Esc);
    assert_eq!(r.app().active_view(), Some(second));
    r.command(Command::SetMode(soda::interaction::EditMode::Normal));
    r.command(Command::Named("commands".into()));
    key(&mut r, Key::Char('b'));
    key(&mut r, Key::Enter);
    key(&mut r, Key::Enter);
    assert_eq!(r.app().active_view(), Some(first));
    assert_eq!(r.app().views().count(), 2);
    assert!(r.layer().is_none());
}
#[test]
fn hidden_dirty_document_is_listed_and_confirm_creates_a_view() {
    let mut r = runtime();
    let first = r.app().active_view().unwrap();
    let document = r.app().view(first).unwrap().document_id;
    r.input(UserInput::Paste("unsaved".into()));
    r.dispatch(Event::CloseView(first));
    r.command(Command::Named("buffer".into()));
    assert!(
        matches!(r.layer(), Some(Layer::CommandLine(s)) if s.rows().len() == 1 && s.rows()[0].candidate.label.contains("[+]"))
    );
    key(&mut r, Key::Enter);
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    assert_eq!(view.document_id, document);
    assert_eq!(
        r.app()
            .workspace()
            .editor(document)
            .unwrap()
            .model()
            .document()
            .snapshot()
            .text(),
        "unsaved"
    );
}
#[test]
fn filtering_no_matches_and_external_document_changes_are_safe() {
    let mut r = runtime();
    let view = r.app().active_view().unwrap();
    let document = r.app().view(view).unwrap().document_id;
    r.command(Command::New);
    r.command(Command::Named("buffer".into()));
    r.input(UserInput::Paste("no such buffer".into()));
    key(&mut r, Key::Enter);
    assert!(r.layer().is_some());
    key(&mut r, Key::Esc);
    // Fuzzy, smart-case matching: lowercase letters in order.
    r.command(Command::Ex("buffer untld".into()));
    assert!(matches!(r.layer(), Some(Layer::CommandLine(s)) if s.rows().len() == 2));
    r.dispatch(Event::CloseDocument {
        document,
        discard: false,
    });
    assert!(matches!(r.layer(), Some(Layer::CommandLine(s)) if s.rows().len() == 1));
    key(&mut r, Key::Enter);
    assert!(r.layer().is_none());
    assert_eq!(r.app().views().count(), 1);
}
#[test]
fn multiple_views_produce_one_candidate_and_empty_updates_do_not_redraw() {
    let mut r = runtime();
    let doc = r
        .app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id;
    r.dispatch(Event::AddView(doc));
    let active = r.app().active_view().unwrap();
    r.command(Command::Named("buffer".into()));
    assert!(matches!(r.layer(), Some(Layer::CommandLine(s)) if s.rows().len() == 1));
    r.take_redraw();
    r.poll();
    assert!(!r.take_redraw());
    key(&mut r, Key::Enter);
    assert_eq!(r.app().active_view(), Some(active));
    assert_eq!(r.app().views().count(), 2);
}
fn documents(r: &Runtime) -> Vec<soda::editor::DocumentId> {
    r.app().workspace().documents().collect()
}
fn current(r: &Runtime) -> soda::editor::DocumentId {
    r.app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id
}
#[test]
fn kill_buffer_asks_which_and_enter_alone_takes_the_current_one() {
    let mut r = runtime();
    let first = current(&r);
    r.command(Command::New);
    assert_ne!(current(&r), first);
    // C-x k, as Emacs: the list opens on the current buffer.
    for key in KeyStroke::parse_sequence("C-x k").unwrap() {
        r.input(UserInput::Key(key));
    }
    let Some(Layer::CommandLine(line)) = r.layer() else {
        panic!("kill-buffer asks which buffer");
    };
    assert_eq!(line.input().text(), "kill-buffer ");
    let selected = &line.rows()[line.list().index(line.rows()).unwrap()];
    assert!(
        selected.candidate.label.starts_with("* "),
        "{}",
        selected.candidate.label
    );
    key(&mut r, Key::Enter);
    assert!(r.layer().is_none());
    assert_eq!(documents(&r), [first]);

    // Another buffer goes without the current one moving.
    r.command(Command::New);
    let third = current(&r);
    r.command(Command::Named("kill-buffer".into()));
    key(&mut r, Key::Up);
    key(&mut r, Key::Enter);
    assert_eq!(documents(&r), [third]);
    assert_eq!(current(&r), third);
}
#[test]
fn killing_an_unsaved_buffer_elsewhere_shows_it_and_asks() {
    let mut r = runtime();
    let first = current(&r);
    r.input(UserInput::Paste("unsaved".into()));
    r.command(Command::New);
    let second = current(&r);
    let name = r.app().document_name(first);
    r.command(Command::Named(format!("kill-buffer {name}")));
    assert_eq!(current(&r), first, "the unsaved document comes forward");
    let Some(Layer::CommandLine(line)) = r.layer() else {
        panic!("close asks about the unsaved changes");
    };
    assert_eq!(line.input().text(), "close ");
    for key in KeyStroke::parse_sequence("d").unwrap() {
        r.input(UserInput::Key(key));
    }
    assert_eq!(documents(&r), [second]);
    // A saved one goes at once, from wherever it is.
    r.command(Command::New);
    let name = r.app().document_name(second);
    let third = current(&r);
    r.command(Command::Named(format!("kill-buffer {name}")));
    assert!(r.layer().is_none());
    assert_eq!(documents(&r), [third]);
}
