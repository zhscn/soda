//! Enter and typing in languages other than C++: Rust by its structure,
//! others by their brackets. `|` marks the caret.
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
    press(name, "<ret>", cases);
}
#[track_caller]
fn press(name: &str, keys: &str, cases: &[(&str, &str)]) {
    for (before, after) in cases {
        let at = before.find('|').expect("a caret");
        let source = before.replacen('|', "", 1);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(name);
        std::fs::write(&path, &source).unwrap();
        let mut r = Runtime::new(dir.path().to_owned()).unwrap();
        r.source_lua("auto-pairs", r#"soda.set("auto-pairs", true)"#)
            .unwrap();
        r.start(Some(path));
        let deadline = Instant::now() + Duration::from_secs(5);
        while r.app().active_view().is_none() || text(&r) != source {
            assert!(Instant::now() < deadline);
            r.poll();
            std::thread::sleep(Duration::from_millis(2));
        }
        r.command(Command::SetMode(EditMode::Insert));
        r.command(Command::Edit(Edit::SetSelection(Selection::caret(at))));
        for key in KeyStroke::parse_sequence(keys).unwrap() {
            r.input(UserInput::Key(key));
        }
        assert_eq!(&shown(&r), after, "{before} {keys}");
    }
}

#[test]
fn brackets_indent_a_level() {
    check(
        "a.go",
        &[
            ("func f() {|\n", "func f() {\n    |\n"),
            ("    if x {|\n", "    if x {\n        |\n"),
            ("foo(|\n", "foo(\n    |\n"),
            ("a := [  |\n", "a := [  \n    |\n"),
            // Anything else inherits.
            ("    x := 1|\n", "    x := 1\n    |\n"),
            ("func f() {}|\n", "func f() {}\n|\n"),
            // Brackets in literals are text.
            ("// see {|\n", "// see {\n|\n"),
            ("s := \"{|\n", "s := \"{\n|\n"),
        ],
    );
}
#[test]
fn a_split_pair_opens_a_line() {
    check(
        "a.go",
        &[
            ("func f() {|}\n", "func f() {\n    |\n}\n"),
            ("    g(|)\n", "    g(\n        |\n    )\n"),
            ("if x { | }\n", "if x { \n    |\n}\n"),
            ("{|)\n", "{\n    |)\n"),
        ],
    );
}
#[test]
fn rust_lines_go_where_rustfmt_puts_them() {
    check(
        "a.rs",
        &[
            ("fn f() {|}\n", "fn f() {\n    |\n}\n"),
            ("    g(|);\n", "    g(\n        |\n    );\n"),
            (
                "fn f() {\n    let x = 1;|\n}\n",
                "fn f() {\n    let x = 1;\n    |\n}\n",
            ),
            // A statement left open continues a level in.
            (
                "fn f() {\n    let x =|\n}\n",
                "fn f() {\n    let x =\n        |\n}\n",
            ),
            (
                "fn f() {\n    let v = xs\n        .iter()|\n}\n",
                "fn f() {\n    let v = xs\n        .iter()\n        |\n}\n",
            ),
            // After a block, a new statement.
            (
                "fn f() {\n    if a {\n    }|\n}\n",
                "fn f() {\n    if a {\n    }\n    |\n}\n",
            ),
            // An arm's body after its arrow, the next arm after the comma.
            (
                "match x {\n    A =>|\n}\n",
                "match x {\n    A =>\n        |\n}\n",
            ),
            (
                "match x {\n    A => 1,|\n}\n",
                "match x {\n    A => 1,\n    |\n}\n",
            ),
            // An unclosed block still holds what follows.
            ("fn f() {|\n", "fn f() {\n    |\n"),
            // A multi-line string keeps its text as typed.
            ("let s = \"{|\n", "let s = \"{\n|\n"),
            ("/// doc|\nfn f() {}\n", "/// doc\n/// |\nfn f() {}\n"),
        ],
    );
}
#[test]
fn typing_moves_a_rust_line_that_its_first_token_places() {
    press(
        "a.rs",
        "}",
        &[("fn f() {\n    x();\n    |\n", "fn f() {\n    x();\n}|\n")],
    );
    // Enter after a block cannot know a chain comes; `.` tells.
    press(
        "a.rs",
        ".",
        &[(
            "fn f() {\n    let p = Point {\n        x: 1,\n    }\n    |\n}\n",
            "fn f() {\n    let p = Point {\n        x: 1,\n    }\n    .|\n}\n",
        )],
    );
    press(
        "a.rs",
        "{",
        &[(
            "fn f<T>()\nwhere\n    T: X,\n    |\n",
            "fn f<T>()\nwhere\n    T: X,\n{|}\n",
        )],
    );
    press(
        "a.rs",
        "else",
        &[(
            "fn f() {\n    if a {\n    }\n        |\n}\n",
            "fn f() {\n    if a {\n    }\n    else|\n}\n",
        )],
    );
    // Elsewhere typing leaves the line alone.
    press("a.rs", "x", &[("fn f() {\n|\n}\n", "fn f() {\nx|\n}\n")]);
}
#[test]
fn plain_text_only_inherits() {
    check(
        "a.txt",
        &[("  see (|\n", "  see (\n  |\n"), ("a {|}\n", "a {\n|}\n")],
    );
}
