use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
/// Types a command line; `<` in it is literal.
fn ex(r: &mut Runtime, line: &str) {
    keys(r, "<a-x>");
    r.input(UserInput::Paste(line.into()));
    keys(r, "<ret>");
}
fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}

#[test]
fn keys_replay_on_each_selected_line_and_undo_together() {
    let mut r = runtime("a\nb\nc\nd");
    keys(&mut r, "jee");
    ex(&mut r, "each-line <c-e>i;<esc>");
    assert_eq!(text(&r), "a\nb;\nc;\nd");
    keys(&mut r, "u");
    assert_eq!(text(&r), "a\nb\nc\nd");
    // Without a selection, only the caret's line; macros replay too.
    keys(&mut r, "<a-lt><f3><c-a>i- <esc><f4>");
    assert_eq!(text(&r), "- a\nb\nc\nd");
    keys(&mut r, "<a-gt>k");
    ex(&mut r, "each-line <f4>");
    assert_eq!(text(&r), "- a\nb\n- c\nd");
}
#[test]
fn keys_replay_at_each_match() {
    let mut r = runtime("foo x foo\nbar foo");
    ex(&mut r, "each-match foo ,wsbaz<esc>");
    assert_eq!(text(&r), "baz x baz\nbar baz");
    keys(&mut r, "u");
    assert_eq!(text(&r), "foo x foo\nbar foo");
    // In a selection, only its lines.
    keys(&mut r, "je");
    ex(&mut r, "each-match o s0<esc>");
    assert_eq!(text(&r), "foo x foo\nbar f00");
    r.command(Command::Named("each-match ( x".into()));
    assert!(r.message().contains("unclosed group"), "{}", r.message());
}
