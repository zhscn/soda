//! Enter in languages without a parser. `|` marks the caret.
use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::time::{Duration, Instant};

fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn shown(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    let head = editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head;
    let mut text = text(r);
    text.insert(head, '|');
    text
}
fn check(name: &str, cases: &[(&str, &str)]) {
    for (before, after) in cases {
        let at = before.find('|').expect("a caret");
        let source = before.replacen('|', "", 1);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(name);
        std::fs::write(&path, &source).unwrap();
        let mut r = Runtime::new(dir.path().to_owned()).unwrap();
        r.start(Some(path));
        let deadline = Instant::now() + Duration::from_secs(5);
        while r.app().active_view().is_none() || text(&r) != source {
            assert!(Instant::now() < deadline);
            r.poll();
            std::thread::sleep(Duration::from_millis(2));
        }
        r.command(Command::SetMode(EditMode::Insert));
        r.command(Command::Edit(Edit::SetSelection(Selection::caret(at))));
        for key in KeyStroke::parse_sequence("<ret>").unwrap() {
            r.input(UserInput::Key(key));
        }
        assert_eq!(&shown(&r), after, "{before}");
    }
}

#[test]
fn brackets_indent_a_level() {
    check(
        "a.rs",
        &[
            ("fn f() {|\n", "fn f() {\n    |\n"),
            ("    if x {|\n", "    if x {\n        |\n"),
            ("foo(|\n", "foo(\n    |\n"),
            ("let a = [  |\n", "let a = [  \n    |\n"),
            // Anything else inherits.
            ("    let x = 1;|\n", "    let x = 1;\n    |\n"),
            ("fn f() {}|\n", "fn f() {}\n|\n"),
            // Brackets in literals are text.
            ("// see {|\n", "// see {\n|\n"),
            ("let s = \"{|\n", "let s = \"{\n|\n"),
        ],
    );
}
#[test]
fn a_split_pair_opens_a_line() {
    check(
        "a.rs",
        &[
            ("fn f() {|}\n", "fn f() {\n    |\n}\n"),
            ("    g(|);\n", "    g(\n        |\n    );\n"),
            ("if x { | }\n", "if x { \n    |\n}\n"),
            ("{|)\n", "{\n    |)\n"),
        ],
    );
}
#[test]
fn plain_text_only_inherits() {
    check(
        "a.txt",
        &[("  see (|\n", "  see (\n  |\n"), ("a {|}\n", "a {\n|}\n")],
    );
}
