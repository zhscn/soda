use soda::{
    interaction::{Command, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::time::{Duration, Instant};

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
fn scratch(r: &Runtime, name: &str) -> String {
    let document = r.app().workspace().scratch(name).unwrap();
    r.app()
        .workspace()
        .editor(document)
        .unwrap()
        .model()
        .document()
        .snapshot()
        .text()
        .to_owned()
}
fn active_name(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app().document_name(view.document_id)
}
fn caret_line(r: &Runtime) -> usize {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    let head = editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head;
    editor.model().document().snapshot().line_of(head).unwrap()
}

#[test]
fn run_streams_output_and_steps_through_its_locations() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "one\ntwo\nthree\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    line(
        &mut r,
        "run printf 'building\\na.txt:3: warning: x\\n' >&2; echo a.txt:2:2: error: y; exit 3",
    );
    assert!(r.run_running());
    assert_eq!(active_name(&r), "*run*");
    wait(&mut r, |r| !r.run_running());
    let text = scratch(&r, "*run*");
    assert!(text.starts_with("$ printf"), "{text}");
    assert!(text.ends_with("\n\n[exited 3]"), "{text}");
    for expected in [
        "\nbuilding\n",
        "\na.txt:3: warning: x\n",
        "\na.txt:2:2: error: y\n",
    ] {
        assert!(text.contains(expected), "{text}");
    }
    assert!(r.message().ends_with(": exited 3"), "{}", r.message());
    // The view kept to the end while output arrived.
    assert_eq!(caret_line(&r), text.lines().count() - 1);
    keys(&mut r, "gg]q");
    wait(&mut r, |r| active_name(r).ends_with("a.txt"));
    let first = caret_line(&r);
    keys(&mut r, "]q");
    wait(&mut r, |r| caret_line(r) != first);
    assert_eq!((first, caret_line(&r)), (2, 1));
}
#[test]
fn stop_ends_runs_and_shell_commands() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    line(&mut r, "stop");
    assert_eq!(r.message(), "");
    let started = Instant::now();
    line(&mut r, "run sleep 30");
    line(&mut r, "run echo second");
    wait(&mut r, |r| !r.run_running());
    let text = scratch(&r, "*run*");
    assert_eq!(text, "$ echo second\nsecond\n\n[exited 0]");
    line(&mut r, "run sh -c 'sleep 30; echo late'");
    line(&mut r, "stop");
    assert!(!r.run_running());
    assert_eq!(r.message(), "Stopped");
    line(&mut r, "shell sleep 30");
    assert!(r.shell_running());
    keys(&mut r, "<c-c>");
    wait(&mut r, |r| !r.shell_running());
    assert_eq!(r.message(), "sleep 30: was stopped");
    assert!(started.elapsed() < Duration::from_secs(10));
}
#[test]
fn stepping_starts_at_the_first_result() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "x needle\nx\nneedle\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    line(&mut r, "grep needle");
    wait(&mut r, |r| r.message().starts_with("2 matches"));
    keys(&mut r, "]q");
    wait(&mut r, |r| active_name(r).ends_with("a.txt"));
    assert_eq!(caret_line(&r), 0);
    keys(&mut r, "]q");
    wait(&mut r, |r| caret_line(r) != 0);
    assert_eq!(caret_line(&r), 2);
    keys(&mut r, "[q");
    wait(&mut r, |r| caret_line(r) == 0);
}
