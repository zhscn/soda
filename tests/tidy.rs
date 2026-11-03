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
fn text(r: &Runtime) -> String {
    let Some(view) = r.app().active_view().and_then(|id| r.app().view(id)) else {
        return String::new();
    };
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn save(r: &mut Runtime, path: &Path, expected: &str) {
    keys(r, "M-x w RET");
    let deadline = Instant::now() + Duration::from_secs(2);
    while std::fs::read_to_string(path).unwrap() != expected {
        assert!(
            Instant::now() < deadline,
            "disk {:?} buffer {:?} messages {:?}",
            std::fs::read_to_string(path).unwrap(),
            text(r),
            r.messages().collect::<Vec<_>>()
        );
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    wait(r, |r| r.message().starts_with("Saved "));
}

#[test]
fn saving_trims_edited_lines_and_ends_with_a_line_break() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.txt");
    std::fs::write(&path, "keep  \nedit\nlast").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.start(Some(path.clone()));
    wait(&mut r, |r| text(r) == "keep  \nedit\nlast");
    // A tab character, which TAB would indent instead of typing.
    keys(&mut r, "j C-e a SPC");
    r.input(UserInput::Paste("\t".into()));
    keys(&mut r, "ESC");
    save(&mut r, &path, "keep  \nedit\nlast\n");
    assert_eq!(text(&r), "keep  \nedit\nlast\n");
    // Tidying is its own undo step.
    keys(&mut r, "u");
    assert_eq!(text(&r), "keep  \nedit \t\nlast");
    // A caret at the end keeps to its line after the break is added.
    keys(&mut r, "M-> C-e a! ESC");
    save(&mut r, &path, "keep  \nedit\nlast!\n");
    keys(&mut r, "a? ESC");
    assert_eq!(text(&r), "keep  \nedit\nlast!?\n");
    // Options turn either part off; lines already saved are left alone.
    r.command(Command::Named("set-local final-newline false".into()));
    r.command(Command::Named(
        "set-local trim-trailing-whitespace false".into(),
    ));
    keys(&mut r, "i");
    r.command(Command::Edit(soda::editor::Command::SelectAll));
    r.input(UserInput::Paste("keep \nend".into()));
    keys(&mut r, "ESC");
    save(&mut r, &path, "keep \nend");
    assert_eq!(text(&r), "keep \nend");
}
