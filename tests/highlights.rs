use soda::{
    application::Face,
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
fn line(r: &mut Runtime, command: &str) {
    r.command(Command::Named(command.into()));
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
fn shown(r: &Runtime) -> Vec<(String, Face)> {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app()
        .highlights(view.document_id)
        .map(|h| (h.pattern.as_str().to_owned(), h.face))
        .collect()
}

#[test]
fn patterns_highlight_globally_or_in_one_document() {
    let mut r = runtime("foo bar_baz 中文 x");
    let errors = r.source(
        "init",
        "highlight todo \\b(TODO|FIXME)\\b\nhighlight teal x\nhighlight-local mark x\n",
    );
    assert_eq!(errors.len(), 2, "{errors:?}");
    assert!(errors[0].1.contains("unknown face teal"));
    assert_eq!(shown(&r), [("\\b(TODO|FIXME)\\b".into(), Face::Todo)]);
    // Marks of the word at the caret take the next colour each.
    line(
        &mut r,
        "define-command mark-word highlight-local mark \\b%val{word}\\b",
    );
    line(&mut r, "mark-word");
    keys(&mut r, "w");
    line(&mut r, "mark-word");
    keys(&mut r, "w");
    line(&mut r, "mark-word");
    assert_eq!(
        shown(&r)[1..],
        [
            ("\\bfoo\\b".into(), Face::Mark(0)),
            ("\\bbar_baz\\b".into(), Face::Mark(1)),
            ("\\b中文\\b".into(), Face::Mark(2)),
        ]
    );
    // Another document sees only the global highlight.
    r.command(Command::New);
    assert_eq!(shown(&r).len(), 1);
    line(&mut r, "mark-word");
    assert_eq!(r.message(), "%val{word}: no word at the caret");
    line(&mut r, "next-view");
    line(&mut r, "unhighlight \\bfoo\\b");
    assert_eq!(shown(&r).len(), 3);
    line(&mut r, "unhighlight");
    assert!(shown(&r).is_empty());
    line(&mut r, "unhighlight");
    assert_eq!(r.message(), "no such highlight");
    line(&mut r, "highlight error (");
    assert!(r.message().contains("unclosed group"), "{}", r.message());
}
