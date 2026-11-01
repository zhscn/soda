//! Structural editing through its keys: `lua/pairs.lua` over what each
//! language says about brackets and items. `|` marks the caret.
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
fn selection(r: &Runtime) -> Selection {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().session(view.session_id).unwrap().selection()
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn shown(r: &Runtime) -> String {
    let mut text = text(r);
    text.insert(selection(r).head, '|');
    text
}
/// A file of the given name holding `marked`, the caret at its `|`.
fn open(name: &str, marked: &str, mode: EditMode) -> (tempfile::TempDir, Runtime) {
    let at = marked.find('|').expect("a caret");
    let source = marked.replacen('|', "", 1);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(name);
    std::fs::write(&path, &source).unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.load_startup_lua();
    assert_eq!(r.message(), "");
    r.start(Some(path));
    let deadline = Instant::now() + Duration::from_secs(5);
    while r.app().active_view().is_none() || text(&r) != source {
        assert!(Instant::now() < deadline);
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    r.command(Command::SetMode(mode));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(at))));
    (dir, r)
}
#[track_caller]
fn check(name: &str, mode: EditMode, cases: &[(&str, &str, &str)]) {
    for (before, pressed, after) in cases {
        let (_dir, mut r) = open(name, before, mode);
        keys(&mut r, pressed);
        assert_eq!(&shown(&r), after, "{before:?} {pressed} ({})", r.message());
    }
}

#[test]
fn moves_step_over_whole_expressions() {
    use EditMode::Normal as N;
    check(
        "a.cpp",
        N,
        &[
            ("|foo(a, b).bar", "<a-f>", "foo|(a, b).bar"),
            ("foo|(a, b).bar", "<a-f>", "foo(a, b)|.bar"),
            ("foo(a, b)|.bar;", "<a-f>", "foo(a, b).bar|;"),
            ("foo(a, b)|.bar;", "<a-b>", "foo|(a, b).bar;"),
            // The ends of a group stop a move.
            ("f(a|)", "<a-f>", "f(a|)"),
            ("f(|a)", "<a-b>", "f(|a)"),
            ("f(a, g(|b))", "<a-u>", "f(a, g|(b))"),
            ("f(a, g|(b))", "<a-u>", "f|(a, g(b))"),
            // Comments are passed over.
            ("|/* x */ a;", "<a-f>", "/* x */ a|;"),
            // Brackets in a literal or a comment are text.
            ("|\"a)\" b", "<a-f>", "\"a)\"| b"),
            ("(a /* ) */ |b)", "<a-u>", "|(a /* ) */ b)"),
            ("void f() { |g(); }", "<a-u>", "void f() |{ g(); }"),
        ],
    );
}
#[test]
fn templates_are_groups_and_comparisons_are_not() {
    use EditMode::Normal as N;
    check(
        "a.cpp",
        N,
        &[
            ("vector|<map<a, b>> x;", "<a-f>", "vector<map<a, b>>| x;"),
            ("vector<map|<a, b>> x;", "<a-f>", "vector<map<a, b>|> x;"),
            ("vector<map<a, b>>| x;", "<a-b>", "vector|<map<a, b>> x;"),
            ("vector<map<a, |b>> x;", "<a-u>", "vector<map|<a, b>> x;"),
            ("int x = |a < b;", "<a-f>", "int x = a| < b;"),
            (
                "bool f() { return |x < y && y > z; }",
                "<a-f><a-f>",
                "bool f() { return x < y| && y > z; }",
            ),
            (
                "bool b = x < y && |y > z;",
                "<a-u>",
                "bool b = x < y && |y > z;",
            ),
        ],
    );
}
#[test]
fn kill_takes_the_expression_that_crosses_the_line() {
    use EditMode::Insert as I;
    check(
        "a.cpp",
        I,
        &[
            ("|foo(a,\n    b);\nnext", "<c-k>", "|;\nnext"),
            (
                "|if (x) {\n    a();\n} else {\n    b();\n}\n",
                "<c-k>",
                "| else {\n    b();\n}\n",
            ),
            // Inside a group the kill stops before its end.
            ("f(a|, b);\nc", "<c-k>", "f(a|);\nc"),
            ("f(a, |b\n);\nc", "<c-k>", "f(a, |\n);\nc"),
            // A line that closes nothing goes as usual.
            ("a| = 1; // note\nb", "<c-k>", "a|\nb"),
            ("a|\nb", "<c-k>", "a|b"),
            ("// a| b\nc", "<c-k>", "// a|\nc"),
            ("\"a| b\";\nc", "<c-k>", "\"a|\nc"),
            // No partner, no structure.
            ("|foo(a,\nb", "<c-k>", "|\nb"),
        ],
    );
}
#[test]
fn kill_puts_the_text_on_the_clipboard() {
    let (_dir, mut r) = open("a.cpp", "|foo(a,\n    b);\n", EditMode::Insert);
    keys(&mut r, "<c-k><esc>");
    assert_eq!(text(&r), ";\n");
    keys(&mut r, "u");
    assert_eq!(text(&r), "foo(a,\n    b);\n", "one undo step");
    let (_dir, mut r) = open("a.cpp", "|f(a,\nb);\n", EditMode::Normal);
    keys(&mut r, "<c-k>$p");
    assert_eq!(text(&r), ";f(a,\nb)\n");
}
#[test]
fn backspace_keeps_pairs() {
    use EditMode::Insert as I;
    check(
        "a.cpp",
        I,
        &[
            ("f(a)|;", "<bs>", "f(a|);"),
            ("f(|a);", "<bs>", "f|(a);"),
            ("f(|);", "<bs>", "f|;"),
            ("f(a|);", "<bs>", "f(|);"),
            ("{ a; }|", "<bs>", "{ a; |}"),
            ("x = \"ab\"|;", "<bs>", "x = \"ab|\";"),
            ("x = \"|ab\";", "<bs>", "x = |\"ab\";"),
            ("x = \"\"|;", "<bs>", "x = |;"),
            // Text and strays go as usual.
            ("x = \"a(|b\";", "<bs>", "x = \"a|b\";"),
            ("// (|a", "<bs>", "// |a"),
            ("a)|", "<bs>", "a|"),
            ("f(|a", "<bs>", "f|a"),
        ],
    );
    check(
        "a.cpp",
        I,
        &[
            ("foo bar|", "<c-w>", "foo |"),
            ("f(a, |b)", "<c-w>", "f(a|b)"),
            ("f(a)  |", "<c-w>", "f(a)|"),
            ("f(a)|", "<c-w>", "f(a|)"),
        ],
    );
}
#[test]
fn soft_backspace_merges_like_the_built_in_one() {
    let (_dir, mut r) = open("a.cpp", "|", EditMode::Insert);
    keys(&mut r, "abc<bs><bs><esc>");
    assert_eq!(text(&r), "a");
    keys(&mut r, "u");
    assert_eq!(text(&r), "abc", "deletions in a row are one step");
}
#[test]
fn closing_brackets_move_over_their_neighbours() {
    use EditMode::Normal as N;
    check(
        "a.cpp",
        N,
        &[
            ("foo(|a), b;", "<c-s-right>", "foo(|a, b);"),
            ("foo(|a, b);", "<c-s-left>", "foo(|a), b;"),
            ("foo(|a);", "<c-s-left>", "foo()|a;"),
        ],
    );
}
#[test]
fn expansion_selects_group_after_group() {
    let (_dir, mut r) = open("a.cpp", "f(a, g(|b), c)", EditMode::Normal);
    let selected = |r: &Runtime| {
        let s = selection(r);
        text(r)[s.anchor.min(s.head)..s.anchor.max(s.head)].to_owned()
    };
    keys(&mut r, "<a-o>");
    assert_eq!(selected(&r), "(b)", "{}", r.message());
    keys(&mut r, "<a-o>");
    assert_eq!(selected(&r), "(a, g(b), c)");
    keys(&mut r, "<a-o>");
    assert_eq!(selected(&r), "(a, g(b), c)", "nothing around it");
}
#[test]
fn other_languages_use_brackets_and_literals() {
    use EditMode::{Insert as I, Normal as N};
    check(
        "a.rs",
        N,
        &[
            ("|f(a, \")\").g", "<a-f><a-f>", "f(a, \")\")|.g"),
            ("(a /* ) */ |b)", "<a-u>", "|(a /* ) */ b)"),
            ("|\"a b\" c", "<a-f>", "\"a b\"| c"),
        ],
    );
    check("a.rs", I, &[("|foo(a,\n  b);\nc", "<c-k>", "|;\nc")]);
    check(
        "a.txt",
        N,
        &[
            ("|f(a, b) c", "<a-f><a-f>", "f(a, b)| c"),
            ("(a| b", "<a-u>", "(a| b"),
        ],
    );
    check("a.txt", I, &[("f(a)|", "<bs>", "f(a|)")]);
}
#[test]
fn a_group_split_by_conditional_compilation_is_not_a_group() {
    let source = "#if X\nvoid f() {\n#else\nvoid g() {\n#endif\n    |h();\n}\nz;\n";
    check("a.cpp", EditMode::Normal, &[(source, "<a-u>", source)]);
    let kill = "#if X\nvoid f() {\n#else\nvoid g() |{\n#endif\n    h();\n}\nz;\n";
    let killed = "#if X\nvoid f() {\n#else\nvoid g() |\n#endif\n    h();\n}\nz;\n";
    check("a.cpp", EditMode::Insert, &[(kill, "<c-k>", killed)]);
}
#[test]
fn unmapping_a_key_brings_back_the_built_in_one() {
    let (_dir, mut r) = open("a.cpp", "f(a)|;", EditMode::Insert);
    r.command(Command::Named("unmap insert <bs>".into()));
    keys(&mut r, "<bs>");
    assert_eq!(shown(&r), "f(a|;");
}
#[test]
fn built_in_keys_reach_their_commands() {
    let (_dir, mut r) = open("a.cpp", "|ab;\n", EditMode::Normal);
    keys(&mut r, "gc");
    assert_eq!(text(&r), "// ab;\n");
    keys(&mut r, "u");
    keys(&mut r, "vlS\"");
    assert_eq!(text(&r), "\"ab\";\n", "{}", r.message());
}
