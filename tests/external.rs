use soda::{
    interaction::{Command, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::{
    path::Path,
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
fn text_of(r: &Runtime, path: &Path) -> Option<String> {
    let document = r
        .app()
        .workspace()
        .documents()
        .find(|id| r.app().workspace().file(*id).unwrap().path() == Some(path))?;
    let editor = r.app().workspace().editor(document).unwrap();
    Some(editor.model().document().snapshot().text().to_owned())
}
fn open(r: &mut Runtime, path: &Path) {
    r.command(Command::Named(format!("edit {}", path.display())));
    wait(r, |r| text_of(r, path).is_some());
}

#[test]
fn regaining_focus_reloads_clean_files_and_reports_the_rest() {
    let dir = tempfile::tempdir().unwrap();
    let (clean, edited, kept, gone) = (
        dir.path().join("clean.txt"),
        dir.path().join("edited.txt"),
        dir.path().join("kept.txt"),
        dir.path().join("gone.txt"),
    );
    for path in [&clean, &edited, &kept, &gone] {
        std::fs::write(path, "old\n").unwrap();
    }
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    for path in [&clean, &kept, &gone, &edited] {
        open(&mut r, path);
    }
    // Nothing changed yet: focus leaves the message alone.
    r.report("hello".into());
    r.input(UserInput::FocusGained);
    assert_eq!(r.message(), "hello");
    for path in [&clean, &edited] {
        std::fs::write(path, "new\n").unwrap();
    }
    std::fs::remove_file(&gone).unwrap();
    keys(&mut r, "ix<esc>");
    r.input(UserInput::FocusGained);
    assert_eq!(text_of(&r, &clean).unwrap(), "new\n");
    assert_eq!(text_of(&r, &edited).unwrap(), "xold\n");
    assert_eq!(
        r.message(),
        "gone.txt was deleted; edited.txt changed on disk"
    );
    // A file whose option turns reloading off is only reported.
    std::fs::write(&kept, "new\n").unwrap();
    r.command(Command::Named(
        "buffer ".to_owned() + &kept.display().to_string(),
    ));
    r.command(Command::Named("set-local auto-reload false".into()));
    r.command(Command::Named("checktime".into()));
    assert_eq!(text_of(&r, &kept).unwrap(), "old\n");
    assert!(
        r.message().contains("kept.txt changed on disk"),
        "{}",
        r.message()
    );
}
