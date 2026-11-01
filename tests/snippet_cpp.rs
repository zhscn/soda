//! A snippet in C++ takes its indentation from the language.
use soda::{
    interaction::{Command, EditMode},
    runtime::Runtime,
};
use std::time::{Duration, Instant};

#[test]
fn lines_follow_the_structure() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.cpp");
    std::fs::write(&path, "void f() {\n}\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(Some(path));
    let deadline = Instant::now() + Duration::from_secs(5);
    while r.app().active_view().is_none() {
        assert!(Instant::now() < deadline);
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Named("goto 1".into()));
    r.command(Command::Edit(soda::editor::Command::SetSelection(
        soda::core::Selection::caret(11),
    )));
    r.command(Command::Named("snippet if (a) {\nb;\n}\n$0".into()));
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    assert_eq!(
        editor.model().document().snapshot().text(),
        "void f() {\n  if (a) {\n    b;\n  }\n}\n"
    );
}
