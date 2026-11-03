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
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.load_startup_lua();
    r.source_lua("plugins", include_str!("fixtures/plugins.lua"))
        .unwrap();
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
            ("|foo(a, b).bar", "C-M-f", "foo|(a, b).bar"),
            ("foo|(a, b).bar", "C-M-f", "foo(a, b)|.bar"),
            ("foo(a, b)|.bar;", "C-M-f", "foo(a, b).bar|;"),
            ("foo(a, b)|.bar;", "C-M-b", "foo|(a, b).bar;"),
            // The ends of a group stop a move.
            ("f(a|)", "C-M-f", "f(a|)"),
            ("f(|a)", "C-M-b", "f(|a)"),
            ("f(a, g(|b))", "C-M-u", "f(a, g|(b))"),
            ("f(a, g|(b))", "C-M-u", "f|(a, g(b))"),
            // Comments are passed over.
            ("|/* x */ a;", "C-M-f", "/* x */ a|;"),
            // Brackets in a literal or a comment are text.
            ("|\"a)\" b", "C-M-f", "\"a)\"| b"),
            ("(a /* ) */ |b)", "C-M-u", "|(a /* ) */ b)"),
            ("void f() { |g(); }", "C-M-u", "void f() |{ g(); }"),
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
            ("vector|<map<a, b>> x;", "C-M-f", "vector<map<a, b>>| x;"),
            ("vector<map|<a, b>> x;", "C-M-f", "vector<map<a, b>|> x;"),
            ("vector<map<a, b>>| x;", "C-M-b", "vector|<map<a, b>> x;"),
            ("vector<map<a, |b>> x;", "C-M-u", "vector<map|<a, b>> x;"),
            ("int x = |a < b;", "C-M-f", "int x = a| < b;"),
            (
                "bool f() { return |x < y && y > z; }",
                "C-M-f C-M-f",
                "bool f() { return x < y| && y > z; }",
            ),
            (
                "bool b = x < y && |y > z;",
                "C-M-u",
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
            ("|foo(a,\n    b);\nnext", "C-k", "|;\nnext"),
            (
                "|if (x) {\n    a();\n} else {\n    b();\n}\n",
                "C-k",
                "| else {\n    b();\n}\n",
            ),
            // Inside a group the kill stops before its end.
            ("f(a|, b);\nc", "C-k", "f(a|);\nc"),
            ("f(a, |b\n);\nc", "C-k", "f(a, |\n);\nc"),
            // A line that closes nothing goes as usual.
            ("a| = 1; // note\nb", "C-k", "a|\nb"),
            ("a|\nb", "C-k", "a|b"),
            ("// a| b\nc", "C-k", "// a|\nc"),
            ("\"a| b\";\nc", "C-k", "\"a|\nc"),
            // No partner, no structure.
            ("|foo(a,\nb", "C-k", "|\nb"),
        ],
    );
}
#[test]
fn kill_puts_the_text_on_the_clipboard() {
    let (_dir, mut r) = open("a.cpp", "|foo(a,\n    b);\n", EditMode::Insert);
    keys(&mut r, "C-k ESC");
    assert_eq!(text(&r), ";\n");
    keys(&mut r, "u");
    assert_eq!(text(&r), "foo(a,\n    b);\n", "one undo step");
    let (_dir, mut r) = open("a.cpp", "|f(a,\nb);\n", EditMode::Normal);
    keys(&mut r, "C-k C-e p");
    assert_eq!(text(&r), ";f(a,\nb)\n");
}
#[test]
fn kills_go_to_the_kill_ring_and_join_one_after_another() {
    let (_dir, mut r) = open("a.cpp", "|f(a,\n  b);\nint x;\n", EditMode::Insert);
    // The expression past the line end, then what is left of the line:
    // one entry.
    keys(&mut r, "C-k C-k C-k");
    assert_eq!(shown(&r), "|int x;\n");
    assert_eq!(r.app().clipboard(), "f(a,\n  b);\n");
    // Words, forward and backward, join too.
    keys(&mut r, "M-f M-d M-DEL");
    assert_eq!(shown(&r), "|;\n");
    assert_eq!(r.app().clipboard(), "int x");
    assert_eq!(r.app().kill_ring().count(), 2);
    keys(&mut r, "C-y");
    assert_eq!(shown(&r), "int x|;\n");
    keys(&mut r, "M-y");
    assert_eq!(shown(&r), "f(a,\n  b);\n|;\n");
    // `C-w` cuts the selection, else a word backward.
    let (_dir, mut r) = open("a.cpp", "int |value = 1;\n", EditMode::Insert);
    keys(&mut r, "S-<right> S-<right> C-w");
    assert_eq!(shown(&r), "int |lue = 1;\n");
    assert_eq!(r.app().clipboard(), "va");
    keys(&mut r, "C-w");
    assert_eq!(shown(&r), "|lue = 1;\n");
    assert_eq!(r.app().clipboard(), "int va");
}
#[test]
fn backspace_keeps_pairs() {
    use EditMode::Insert as I;
    check(
        "a.cpp",
        I,
        &[
            ("f(a)|;", "DEL", "f(a|);"),
            ("f(|a);", "DEL", "f|(a);"),
            ("f(|);", "DEL", "f|;"),
            ("f(a|);", "DEL", "f(|);"),
            ("{ a; }|", "DEL", "{ a; |}"),
            ("x = \"ab\"|;", "DEL", "x = \"ab|\";"),
            ("x = \"|ab\";", "DEL", "x = |\"ab\";"),
            ("x = \"\"|;", "DEL", "x = |;"),
            // Text and strays go as usual.
            ("x = \"a(|b\";", "DEL", "x = \"a|b\";"),
            ("// (|a", "DEL", "// |a"),
            ("a)|", "DEL", "a|"),
            ("f(|a", "DEL", "f|a"),
        ],
    );
    check(
        "a.cpp",
        I,
        &[
            ("foo bar|", "C-w", "foo |"),
            // Word deletion takes Emacs words: punctuation goes with the word before.
            ("f(a, |b)", "C-w", "f(|b)"),
            ("f(a)  |", "C-w", "f(a)|"),
            ("f(a)|", "C-w", "f(a|)"),
        ],
    );
}
#[test]
fn soft_backspace_merges_like_the_built_in_one() {
    let (_dir, mut r) = open("a.cpp", "|", EditMode::Insert);
    keys(&mut r, "abc DEL DEL ESC");
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
            ("foo(|a), b;", "C-S-<right>", "foo(|a, b);"),
            ("foo(|a, b);", "C-S-<left>", "foo(|a), b;"),
            ("foo(|a);", "C-S-<left>", "foo()|a;"),
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
    keys(&mut r, "M-o");
    assert_eq!(selected(&r), "(b)", "{}", r.message());
    keys(&mut r, "M-o");
    assert_eq!(selected(&r), "(a, g(b), c)");
    keys(&mut r, "M-o");
    assert_eq!(selected(&r), "(a, g(b), c)", "nothing around it");
}
#[test]
fn other_languages_use_brackets_and_literals() {
    use EditMode::{Insert as I, Normal as N};
    check(
        "a.rs",
        N,
        &[
            ("|f(a, \")\").g", "C-M-f C-M-f", "f(a, \")\")|.g"),
            ("(a /* ) */ |b)", "C-M-u", "|(a /* ) */ b)"),
            ("|\"a b\" c", "C-M-f", "\"a b\"| c"),
        ],
    );
    check("a.rs", I, &[("|foo(a,\n  b);\nc", "C-k", "|;\nc")]);
    check(
        "a.txt",
        N,
        &[
            ("|f(a, b) c", "C-M-f C-M-f", "f(a, b)| c"),
            ("(a| b", "C-M-u", "(a| b"),
        ],
    );
    check("a.txt", I, &[("f(a)|", "DEL", "f(a|)")]);
}
#[test]
fn rust_generics_and_closures_are_groups() {
    use EditMode::Normal as N;
    check(
        "a.rs",
        N,
        &[
            (
                "let v: Vec|<HashMap<K, V>> = a;",
                "C-M-f",
                "let v: Vec<HashMap<K, V>>| = a;",
            ),
            (
                "let v: Vec<HashMap<K, V>>| = a;",
                "C-M-b",
                "let v: Vec|<HashMap<K, V>> = a;",
            ),
            ("x.collect::<Vec<|_>>()", "C-M-u", "x.collect::<Vec|<_>>()"),
            (
                "let b = |a < b && c > d;",
                "C-M-f C-M-f",
                "let b = a < b| && c > d;",
            ),
            // The caret is the first `|`; closure parameters are a group.
            (
                "let g = |move |a, b| a;",
                "C-M-f C-M-f",
                "let g = move |a, b|| a;",
            ),
            ("f(|a, |x| x)", "C-M-f C-M-f", "f(a, |x|| x)"),
            // Lifetimes are words, and a quoted brace is a literal.
            (
                "fn f<'a>(x: &|'a str) {}",
                "C-M-f",
                "fn f<'a>(x: &'a| str) {}",
            ),
            ("(a, '(' |b)", "C-M-u", "|(a, '(' b)"),
            ("(r#\")\"# |b)", "C-M-u", "|(r#\")\"# b)"),
        ],
    );
}
#[test]
fn a_group_split_by_conditional_compilation_is_not_a_group() {
    let source = "#if X\nvoid f() {\n#else\nvoid g() {\n#endif\n    |h();\n}\nz;\n";
    check("a.cpp", EditMode::Normal, &[(source, "C-M-u", source)]);
    let kill = "#if X\nvoid f() {\n#else\nvoid g() |{\n#endif\n    h();\n}\nz;\n";
    let killed = "#if X\nvoid f() {\n#else\nvoid g() |\n#endif\n    h();\n}\nz;\n";
    check("a.cpp", EditMode::Insert, &[(kill, "C-k", killed)]);
}
#[test]
fn a_user_binding_shadows_a_plugin_key_until_unmapped() {
    let (_dir, mut r) = open("a.cpp", "f(a)|;", EditMode::Insert);
    r.command(Command::Named("map insert DEL delete-backward".into()));
    keys(&mut r, "DEL");
    assert_eq!(shown(&r), "f(a|;");
    // puni's soft Backspace again, which leaves the pair whole.
    r.command(Command::Named("unmap insert DEL".into()));
    keys(&mut r, ") DEL");
    assert_eq!(shown(&r), "f(a|);");
}
#[test]
fn built_in_keys_reach_their_commands() {
    let (_dir, mut r) = open("a.cpp", "|ab;\n", EditMode::Normal);
    keys(&mut r, "M-;");
    assert_eq!(text(&r), "// ab;\n");
    keys(&mut r, "u");
    keys(&mut r, "LL C-c \"");
    assert_eq!(text(&r), "\"ab\";\n", "{}", r.message());
}
