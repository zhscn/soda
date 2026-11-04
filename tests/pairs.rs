use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::time::{Duration, Instant};

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
/// The text with `|` at the caret.
fn shown(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    let mut text = editor.model().document().snapshot().text().to_owned();
    let head = editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head;
    text.insert(head, '|');
    text
}
fn plain() -> (tempfile::TempDir, Runtime) {
    let dir = tempfile::tempdir().unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.source_lua("auto-pairs", r#"soda.set("auto-pairs", true)"#)
        .unwrap();
    r.command(soda::interaction::Command::New);
    (dir, r)
}
fn cpp() -> (tempfile::TempDir, Runtime) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.cpp");
    std::fs::write(&path, "").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.source_lua("auto-pairs", r#"soda.set("auto-pairs", true)"#)
        .unwrap();
    r.start(Some(path));
    let deadline = Instant::now() + Duration::from_secs(5);
    while r.app().active_view().is_none() {
        assert!(Instant::now() < deadline);
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    (dir, r)
}

#[test]
fn brackets_pair_step_over_and_delete_together() {
    let (_dir, mut r) = plain();
    keys(&mut r, "i(");
    assert_eq!(shown(&r), "(|)");
    keys(&mut r, "a)");
    assert_eq!(shown(&r), "(a)|");
    keys(&mut r, "SPC [ DEL");
    assert_eq!(shown(&r), "(a) |");
    // Before a word, an opener comes alone.
    keys(&mut r, "x <left> [");
    assert_eq!(shown(&r), "(a) [|x");
    // Plain text keeps quotes single.
    keys(&mut r, "ESC C-e a SPC \"");
    assert_eq!(shown(&r), "(a) [x \"|");
    r.command(Command::Named("set auto-pairs false".into()));
    keys(&mut r, "(");
    assert_eq!(shown(&r), "(a) [x \"(|");
}
#[test]
fn selections_are_wrapped() {
    let (_dir, mut r) = plain();
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText("abc".into())));
    r.command(Command::Edit(Edit::SetSelection(Selection {
        anchor: 0,
        head: 3,
    })));
    r.command(Command::Edit(Edit::TypeChar('[')));
    assert_eq!(shown(&r), "[abc|]");
}
#[test]
fn cpp_pairs_quotes_outside_literals_and_opens_blocks() {
    let (_dir, mut r) = cpp();
    keys(&mut r, "iif SPC (x) SPC { RET");
    assert_eq!(shown(&r), "if (x) {\n  |\n}");
    keys(&mut r, "s SPC = SPC \"");
    assert_eq!(shown(&r), "if (x) {\n  s = \"|\"\n}");
    // Inside the string, brackets are text; the closing quote steps over.
    keys(&mut r, "(\"");
    assert_eq!(shown(&r), "if (x) {\n  s = \"(\"|\n}");
    keys(&mut r, "; SPC // SPC don't SPC (");
    assert_eq!(shown(&r), "if (x) {\n  s = \"(\"; // don't (|\n}");
    keys(&mut r, "ESC M-< Ic SPC = SPC x'");
    assert_eq!(shown(&r), "c = x'|\nif (x) {\n  s = \"(\"; // don't (\n}");
    keys(&mut r, "DEL SPC '");
    assert_eq!(shown(&r), "c = x '|'\nif (x) {\n  s = \"(\"; // don't (\n}");
    keys(&mut r, "DEL");
    assert_eq!(shown(&r), "c = x |\nif (x) {\n  s = \"(\"; // don't (\n}");
}
