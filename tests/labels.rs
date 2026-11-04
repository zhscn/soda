use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
    r.set_page_rows(10);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn caret(r: &Runtime) -> usize {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head
}
fn labels(r: &Runtime) -> Vec<(String, Option<usize>)> {
    match r.layer() {
        Some(Layer::Labels(session)) => session
            .targets()
            .map(|(target, _)| (target.label.clone(), target.offset))
            .collect(),
        _ => vec![],
    }
}

#[test]
fn two_characters_then_a_label_move_the_caret() {
    let mut r = runtime("foo bar\nbaz Foo\nfoo");
    keys(&mut r, "SPC jfo");
    // Lowercase finds any case.
    assert_eq!(
        labels(&r),
        [
            ("a".into(), Some(0)),
            ("s".into(), Some(12)),
            ("d".into(), Some(16))
        ]
    );
    keys(&mut r, "s");
    assert!(r.layer().is_none());
    assert_eq!(caret(&r), 12);
    // Capitals match exactly; a single place is taken at once.
    keys(&mut r, "SPC jFo");
    assert_eq!(caret(&r), 12);
    keys(&mut r, "SPC jz SPC");
    assert_eq!(caret(&r), 10);
    keys(&mut r, "SPC jqq");
    assert_eq!(r.message(), "No qq on screen");
    keys(&mut r, "SPC jfo ESC");
    assert!(r.layer().is_none());
    assert_eq!(caret(&r), 10);
}
#[test]
fn windows_are_picked_by_label() {
    let mut r = runtime("x");
    let first = r.app().active_view().unwrap();
    keys(&mut r, "M-x vsplit RET");
    let second = r.app().active_view().unwrap();
    // With two windows, the other one is taken at once.
    keys(&mut r, "SPC w");
    assert_eq!(r.app().active_view(), Some(first));
    keys(&mut r, "M-x split RET");
    let third = r.app().active_view().unwrap();
    keys(&mut r, "SPC w");
    let shown = labels(&r);
    assert_eq!(shown.len(), 3);
    let label = r
        .app()
        .windows()
        .views()
        .iter()
        .position(|v| *v == second)
        .unwrap();
    keys(&mut r, &shown[label].0);
    assert_eq!(r.app().active_view(), Some(second));
    assert_ne!(second, third);
}
