//! Emacs keys alongside meow's. `|` marks the caret.
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
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn shown(r: &Runtime) -> String {
    let mut text = text(r);
    text.insert(caret(r), '|');
    text
}
fn open(marked: &str, mode: EditMode) -> (tempfile::TempDir, Runtime) {
    let at = marked.find('|').expect("a caret");
    let source = marked.replacen('|', "", 1);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.txt");
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
fn check(mode: EditMode, cases: &[(&str, &str, &str)]) {
    for (before, input, after) in cases {
        let (_dir, mut r) = open(before, mode);
        keys(&mut r, input);
        assert_eq!(&shown(&r), after, "{before} {input}");
    }
}

#[test]
fn motions_in_normal_are_emacs_motions() {
    check(
        EditMode::Normal,
        &[
            ("|ab\n", "<c-f>", "a|b\n"),
            ("a|b\n", "<c-b>", "|ab\n"),
            ("|a\nb\nc\n", "<c-n>", "a\n|b\nc\n"),
            ("a\nb\n|c\n", "<c-p>", "a\n|b\nc\n"),
            ("  a|b\n", "<c-a>", "|  ab\n"),
            ("|ab\n", "<c-e>", "ab|\n"),
            ("|ab cd\n", "<a-f>", "ab| cd\n"),
            ("ab| cd\n", "<a-b>", "|ab cd\n"),
            ("a\n|b\nc\n", "<a-gt>", "a\nb\nc\n|"),
            ("a\nb\n|c\n", "<a-lt>", "|a\nb\nc\n"),
            // A count works as with arrows, and a selection stays under them.
            ("|a\nb\nc\n", "2<c-n>", "a\nb\n|c\n"),
            ("|ab cd\n", "<c-space><a-f>d", "| cd\n"),
            ("a|b\n", "<c-space><c-e>d", "a|\n"),
        ],
    );
    check(EditMode::Insert, &[("  a|b\n", "<a-m>", "  |ab\n")]);
}
#[test]
fn edits_in_normal() {
    check(
        EditMode::Insert,
        &[
            ("|ab cd\n", "<a-d>", "| cd\n"),
            ("ab |cd\n", "<a-bs>", "|cd\n"),
        ],
    );
    check(
        EditMode::Normal,
        &[
            ("|ab cd\n", "<a-u>", "AB| cd\n"),
            ("|aB cd\n", "<a-c>", "Ab| cd\n"),
            ("|AB\n", "<a-l>", "ab|\n"),
            ("ab|  cd\n", "<a-\\>", "ab|cd\n"),
            ("a\n  |b\n", "<a-^>", "a| b\n"),
        ],
    );
}
#[test]
fn the_mark_selects_with_emacs_keys() {
    check(
        EditMode::Normal,
        &[
            ("|ab cd\n", "<c-space><a-f><c-w>", "| cd\n"),
            ("|ab cd\n", "<c-space>l<a-w>", "a|b cd\n"),
        ],
    );
    let (_dir, mut r) = open("|ab cd\n", EditMode::Normal);
    keys(&mut r, "<c-space>l<a-w><esc><c-e><c-y>");
    assert_eq!(text(&r), "ab cda\n");
}
#[test]
fn insert_keeps_editing() {
    check(
        EditMode::Insert,
        &[
            ("a\n|b\n", "<c-p>", "|a\nb\n"),
            ("|a\nb\n", "<c-n>", "a\n|b\n"),
            ("a\n|b\n", "<a-lt>", "|a\nb\n"),
            ("a|b\n", "<c-o>", "a|\nb\n"),
            ("  a|b\n", "<a-m>", "  |ab\n"),
            ("a|b\n", "<c-t>", "ba|\n"),
            ("ab|\n", "<c-t>", "ba|\n"),
            ("é|a\n", "<c-t>", "aé|\n"),
            ("ab |cd ef\n", "<a-t>", "cd ab| ef\n"),
            ("ab cd|\n", "<a-t>", "cd ab|\n"),
            ("ab  |  cd\n", "<a-space>", "ab |cd\n"),
            ("a|b cd\n", "<a-c>", "aB| cd\n"),
        ],
    );
}
#[test]
fn prefixes_reach_the_commands() {
    let (dir, mut r) = open("|a\n", EditMode::Insert);
    keys(&mut r, "x<c-x><c-s>");
    let deadline = Instant::now() + Duration::from_secs(5);
    while std::fs::read_to_string(dir.path().join("a.txt")).unwrap() != "xa\n" {
        assert!(Instant::now() < deadline);
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(r.edit_mode(), EditMode::Insert);
    keys(&mut r, "<c-x>2");
    assert_eq!(r.app().windows().len(), 2);
    keys(&mut r, "<c-x>0");
    keys(&mut r, "<c-x><c-g>");
    assert_eq!(r.edit_mode(), EditMode::Insert);
    assert_eq!(text(&r), "xa\n");
}
#[test]
fn undo_keys() {
    let (_dir, mut r) = open("|a\n", EditMode::Normal);
    keys(&mut r, "d");
    assert_eq!(text(&r), "\n");
    keys(&mut r, "<c-/>");
    assert_eq!(text(&r), "a\n");
    keys(&mut r, "<c-a-/>");
    assert_eq!(text(&r), "\n");
}
#[test]
fn search_from_insert_returns_to_insert() {
    let (_dir, mut r) = open("|a b a\n", EditMode::Insert);
    keys(&mut r, "<c-s>b<ret>");
    assert_eq!(caret(&r), 3);
    assert_eq!(r.edit_mode(), EditMode::Insert);
    keys(&mut r, "<c-r>a<ret>");
    assert_eq!(caret(&r), 1);
}
#[test]
fn angle_keys_print_as_they_parse() {
    let keys = KeyStroke::parse_sequence("<a-lt><a-gt>>").unwrap();
    assert_eq!(soda::interaction::key_notation(&keys), "<a-lt><a-gt>>");
}
