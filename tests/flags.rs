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
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
/// One-based lines with their signs and faces.
fn flags(r: &Runtime) -> Vec<(usize, String, Face)> {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app()
        .flags(view.document_id)
        .into_iter()
        .map(|(line, flag)| (line + 1, flag.sign.clone(), flag.face))
        .collect()
}

#[test]
fn flags_mark_lines_by_group_and_follow_edits() {
    let mut r = runtime("a\nb\nc\nd\ne\n");
    line(&mut r, "flag-lines git mark2 + 1 3-4 9");
    assert_eq!(
        flags(&r),
        [
            (1, "+".into(), Face::Mark(1)),
            (3, "+".into(), Face::Mark(1)),
            (4, "+".into(), Face::Mark(1)),
        ],
        "lines past the end are skipped"
    );
    // A later group wins where both flag a line.
    line(&mut r, "flag-lines build error ✗ %val{line}");
    assert_eq!(flags(&r)[0], (1, "✗".into(), Face::Error));
    // Lines opened above move the flags down with their text.
    keys(&mut r, "M-< Inew ESC");
    assert_eq!(flags(&r).iter().map(|f| f.0).collect::<Vec<_>>(), [2, 4, 5]);
    // Removing a group leaves the other.
    line(&mut r, "unflag-lines build");
    assert_eq!(flags(&r)[0], (2, "+".into(), Face::Mark(1)));
    line(&mut r, "unflag-lines");
    assert!(flags(&r).is_empty());
    line(&mut r, "unflag-lines");
    assert_eq!(r.message(), "no such flags");
}
#[test]
fn flag_lines_checks_its_arguments() {
    let mut r = runtime("a\n");
    for (command, error) in [
        ("flag-lines git mark + 1", "flags need a face"),
        ("flag-lines git teal + 1", "unknown face teal"),
        ("flag-lines git todo ++ 1", "a sign is one narrow character"),
        ("flag-lines git todo 界 1", "a sign is one narrow character"),
        ("flag-lines git todo + 0", "not a line or range: 0"),
        ("flag-lines git todo + 3-2", "not a line or range: 3-2"),
        ("flag-lines git todo +", "flag-lines needs"),
    ] {
        line(&mut r, command);
        assert!(r.message().contains(error), "{command}: {}", r.message());
    }
    assert!(flags(&r).is_empty());
}
