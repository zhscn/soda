use soda::{
    editor::DocumentId,
    interaction::{Command, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::{
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

fn wait(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done(r) {
        assert!(Instant::now() < deadline, "{}", r.message());
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn line(r: &mut Runtime, command: &str) {
    r.command(Command::Named(command.into()));
}
fn active(r: &Runtime) -> DocumentId {
    r.app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id
}
fn document_of(r: &Runtime, path: &Path) -> Option<DocumentId> {
    r.app()
        .workspace()
        .documents()
        .find(|id| r.app().workspace().file(*id).unwrap().path() == Some(path))
}

#[test]
fn hooks_from_configuration_shape_new_and_opened_documents() {
    let dir = tempfile::tempdir().unwrap();
    let python = dir.path().join("a.py");
    let text = dir.path().join("b.txt");
    std::fs::write(&python, "x").unwrap();
    std::fs::write(&text, "y").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.source_lua(
        "init.lua",
        r#"
        assert(soda.command("hook new file set-local indent-width 2"))
        assert(soda.command([[hook open .*\.py set-local expand-tab false]]))
        assert(not soda.command("hook open [ bad"))
        "#,
    )
    .unwrap();
    r.command(soda::interaction::Command::New);
    let untitled = active(&r);
    assert_eq!(r.app().options().int(Some(untitled), "indent-width"), 2);
    assert_eq!(r.app().options().int(None, "indent-width"), 4);
    line(&mut r, &format!("edit {}", python.display()));
    line(&mut r, &format!("edit {}", text.display()));
    wait(&mut r, |r| {
        document_of(r, &python).is_some() && document_of(r, &text).is_some()
    });
    let options = r.app().options();
    assert!(!options.bool(document_of(&r, &python), "expand-tab"));
    assert!(options.bool(document_of(&r, &text), "expand-tab"));
}
#[test]
fn hooks_follow_modes_focus_saves_and_closes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("f.txt");
    std::fs::write(&path, "").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
    line(&mut r, "hook mode insert set scroll-lines 9");
    line(&mut r, "hook mode normal set scroll-lines 5");
    keys(&mut r, "i");
    assert_eq!(r.app().options().int(None, "scroll-lines"), 9);
    keys(&mut r, "ESC");
    assert_eq!(r.app().options().int(None, "scroll-lines"), 5);
    line(&mut r, "hook focus .*f\\.txt set tab-width 3");
    line(&mut r, "hook save .* set tab-width 7");
    line(&mut r, "hook close .*f\\.txt set tab-width 1");
    line(&mut r, &format!("edit {}", path.display()));
    wait(&mut r, |r| r.app().options().int(None, "tab-width") == 3);
    keys(&mut r, "ihi ESC");
    line(&mut r, "write");
    wait(&mut r, |r| r.app().options().int(None, "tab-width") == 7);
    assert!(r.message().starts_with("Saved "), "{}", r.message());
    line(&mut r, "close");
    assert_eq!(r.app().options().int(None, "tab-width"), 1);
    // Removed hooks stay quiet.
    line(&mut r, "unhook mode insert");
    assert_eq!(r.message(), "");
    line(&mut r, "unhook mode");
    keys(&mut r, "i ESC");
    assert_eq!(r.app().options().int(None, "scroll-lines"), 5);
    line(&mut r, "unhook mode");
    assert_eq!(r.message(), "no mode hook to remove");
}
#[test]
fn hooks_that_fire_themselves_stop() {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
    line(&mut r, "hook new .* new");
    line(&mut r, "new");
    assert_eq!(r.message(), "Hooks stopped after 16 nested rounds");
    assert!(r.app().workspace().documents().count() < 40);
}
