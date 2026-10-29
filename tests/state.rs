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
fn caret(r: &Runtime) -> Option<(String, usize)> {
    let view = r.app().view(r.app().active_view()?)?;
    let editor = r.app().workspace().editor(view.document_id)?;
    let head = editor.model().session(view.session_id)?.selection().head;
    Some((r.app().document_name(view.document_id), head))
}
fn open(r: &mut Runtime, path: &Path) {
    r.command(Command::Named(format!("edit {}", path.display())));
    let name = path.display().to_string();
    wait(r, |r| caret(r).is_some_and(|(n, _)| n == name));
}

#[test]
fn carets_and_histories_outlive_the_session() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.txt"), dir.path().join("b.txt"));
    std::fs::write(&a, "one\ntwo\nthree\n").unwrap();
    std::fs::write(&b, "x\ny\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    open(&mut r, &a);
    keys(&mut r, "2jll");
    keys(&mut r, ":close<ret>");
    // Within the session, a closed file opens where it was left.
    open(&mut r, &a);
    wait(&mut r, |r| caret(r).unwrap().1 == 10);
    open(&mut r, &b);
    keys(&mut r, "j/y<ret>");
    let text = r.persist();
    let mut next = Runtime::new(dir.path().to_owned()).unwrap();
    next.restore(&text);
    assert_eq!(next.command_history(), ["close"]);
    assert_eq!(next.search_history(), ["y"]);
    next.start(Some(a.clone()));
    wait(&mut next, |r| caret(r).is_some_and(|(_, head)| head == 10));
    open(&mut next, &b);
    wait(&mut next, |r| caret(r).unwrap().1 == 2);
}
