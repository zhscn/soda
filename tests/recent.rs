use soda::{
    interaction::{Command, KeyStroke, Layer, UserInput},
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
fn rows(r: &Runtime) -> Vec<String> {
    match r.layer() {
        Some(Layer::CommandLine(line)) => line
            .rows()
            .iter()
            .map(|row| row.candidate.label.clone())
            .collect(),
        _ => vec![],
    }
}
fn active(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app().document_name(view.document_id)
}
fn open(r: &mut Runtime, path: &Path) {
    r.command(Command::Named(format!("edit {}", path.display())));
    let name = path.display().to_string();
    wait(r, |r| active(r) == name);
}

#[test]
fn recent_files_come_newest_first_and_survive_the_session() {
    let dir = tempfile::tempdir().unwrap();
    let names = ["src/alpha.rs", "src/beta.rs", "gamma.txt"];
    std::fs::create_dir(dir.path().join("src")).unwrap();
    for name in names {
        std::fs::write(dir.path().join(name), name).unwrap();
    }
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.start(None);
    for name in names {
        open(&mut r, &dir.path().join(name));
    }
    keys(&mut r, "SPC r");
    assert_eq!(rows(&r), ["gamma.txt", "src/beta.rs", "src/alpha.rs"]);
    r.input(UserInput::Paste("alp".into()));
    assert_eq!(rows(&r), ["src/alpha.rs"]);
    keys(&mut r, "RET");
    wait(&mut r, |r| active(r).ends_with("alpha.rs"));
    // Another session starts from what this one left.
    let text = r.persist();
    let mut next = Runtime::new(dir.path().to_owned()).unwrap();
    next.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    next.restore(&text);
    next.start(None);
    keys(&mut next, "SPC r");
    assert_eq!(rows(&next), ["src/alpha.rs", "gamma.txt", "src/beta.rs"]);
}
