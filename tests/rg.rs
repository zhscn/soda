use soda::{
    interaction::{Command, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::{
    path::Path,
    time::{Duration, Instant},
};

fn runtime(root: &Path) -> Option<Runtime> {
    if std::process::Command::new("rg")
        .arg("--version")
        .output()
        .is_err()
    {
        return None;
    }
    let mut r = Runtime::new(root.to_owned()).unwrap();
    r.load_startup_lua();
    r.command(Command::New);
    Some(r)
}
fn wait(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done(r) {
        assert!(Instant::now() < deadline, "timed out: {}", r.message());
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn keys(r: &mut Runtime, keys: &str) {
    for key in KeyStroke::parse_sequence(keys).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn command(r: &mut Runtime, line: &str) {
    r.command(Command::Named(line.into()));
}
fn lua(r: &mut Runtime, source: &str) {
    r.source_lua("rg-test", source).unwrap();
}
fn results(r: &Runtime) -> String {
    let document = r.app().workspace().scratch("*rg*").unwrap();
    r.app()
        .workspace()
        .editor(document)
        .unwrap()
        .model()
        .document()
        .snapshot()
        .text()
        .into()
}
fn note(r: &Runtime) -> Option<&str> {
    match r.layer() {
        Some(Layer::CommandLine(line)) => line.note(),
        _ => None,
    }
}
fn finish(r: &mut Runtime) {
    wait(r, |r| !r.grep_running());
}

#[test]
fn interactive_rg_asks_query_files_and_directory_then_jumps() {
    let dir = tempfile::Builder::new()
        .prefix("soda rg ")
        .tempdir()
        .unwrap();
    std::fs::write(dir.path().join("a b.c"), "x\n  中 needle\n").unwrap();
    let Some(mut r) = runtime(dir.path()) else {
        return;
    };
    command(&mut r, "rg");
    assert_eq!(
        note(&r),
        Some("rg regexp"),
        "{} {:?}",
        r.message(),
        r.layer().map(|l| l.presentation().text)
    );
    r.input(UserInput::Paste("needle".into()));
    keys(&mut r, "RET");
    wait(&mut r, |r| note(r) == Some("rg files"));
    r.input(UserInput::Paste("everything".into()));
    keys(&mut r, "RET");
    assert_eq!(note(&r), Some("rg directory"));
    keys(&mut r, "RET");
    finish(&mut r);
    assert!(r.message().starts_with("1 matches"), "{}", r.message());
    assert!(
        results(&r).contains("a b.c\n  2:7  中 needle\n"),
        "{}",
        results(&r)
    );
    keys(&mut r, "M-g n");
    wait(&mut r, |r| {
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        r.app().document_name(view.document_id).ends_with("a b.c")
    });
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    assert_eq!(
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head,
        8
    );
}

#[test]
fn rg_refines_case_literal_hidden_and_ignore_rules() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.c"), "a.b\naxb\nA.B\n").unwrap();
    std::fs::write(dir.path().join(".hidden.c"), "a.b\n").unwrap();
    std::fs::write(dir.path().join(".ignore"), "ignored.c\n").unwrap();
    std::fs::write(dir.path().join("ignored.c"), "a.b\n").unwrap();
    let Some(mut r) = runtime(dir.path()) else {
        return;
    };
    lua(&mut r, "require('rg').search({pattern='a.b'})");
    finish(&mut r);
    assert!(
        r.message().starts_with("3 matches"),
        "{} {}",
        r.message(),
        results(&r)
    );
    command(&mut r, "rg-rerun-toggle-literal");
    finish(&mut r);
    assert!(r.message().starts_with("2 matches"), "{}", r.message());
    command(&mut r, "rg-rerun-toggle-case");
    finish(&mut r);
    assert!(r.message().starts_with("1 matches"), "{}", r.message());
    command(&mut r, "rg-rerun-toggle-hidden");
    finish(&mut r);
    assert!(r.message().starts_with("2 matches"), "{}", r.message());
    command(&mut r, "rg-rerun-toggle-ignore");
    finish(&mut r);
    assert!(r.message().starts_with("3 matches"), "{}", r.message());
    assert!(results(&r).contains("ignored.c\n"));
    assert!(
        results(&r).contains("# Mode: literal; case: sensitive; hidden: true; no-ignore: true")
    );
    command(&mut r, "rg-rerun-change-regexp");
    keys(&mut r, "C-a M-f C-f C-k");
    r.input(UserInput::Paste("nothing".into()));
    keys(&mut r, "RET");
    finish(&mut r);
    assert!(
        r.message().starts_with("0 matches"),
        "{} {:?}",
        r.message(),
        r.layer().map(|l| l.presentation().text)
    );
    assert!(!results(&r).contains("a.c\n"));
    command(&mut r, "rg-menu");
    assert_eq!(note(&r), Some("rg"));
    keys(&mut r, "C-g");
    command(&mut r, "rg-rerun");
    finish(&mut r);
    assert!(
        r.message().starts_with("0 matches"),
        "{} {:?}",
        r.message(),
        r.layer().map(|l| l.presentation().text)
    );
}

#[test]
fn rg_keeps_the_search_directory_when_rerun_from_results_and_filters_globs() {
    let dir = tempfile::tempdir().unwrap();
    let child = dir.path().join("sub dir");
    std::fs::create_dir(&child).unwrap();
    std::fs::write(child.join("a.txt"), "--flag $(touch marker)\n").unwrap();
    std::fs::write(child.join("a.c"), "--flag $(touch marker)\n").unwrap();
    let Some(mut r) = runtime(dir.path()) else {
        return;
    };
    lua(
        &mut r,
        "require('rg').search({pattern='--flag $(touch marker)', literal=true, files='glob:*.txt', directory='sub dir'})",
    );
    finish(&mut r);
    assert!(r.message().starts_with("1 matches"), "{}", r.message());
    assert!(!child.join("marker").exists());
    command(&mut r, "rg-rerun");
    finish(&mut r);
    assert!(results(&r).contains("a.txt\n"));
    keys(&mut r, "M-g n");
    wait(&mut r, |r| {
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        r.app().workspace().file(view.document_id).unwrap().path()
            == Some(child.join("a.txt").as_path())
    });
}

#[test]
fn rg_reports_errors_cancels_prompts_and_stops_background_work() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "needle\n").unwrap();
    let Some(mut r) = runtime(dir.path()) else {
        return;
    };
    command(&mut r, "rg");
    keys(&mut r, "C-g");
    assert!(!r.grep_running());
    lua(
        &mut r,
        "require('rg').search({pattern='needle', files='notarealtype'})",
    );
    finish(&mut r);
    assert!(r.message().starts_with("rg:"), "{}", r.message());
    assert!(r.message().contains("notarealtype"), "{}", r.message());
    lua(&mut r, "require('rg').search({pattern='['})");
    assert!(r.message().contains("regex parse error"), "{}", r.message());
    lua(&mut r, "require('rg').search({pattern='needle'})");
    assert!(r.grep_running());
    command(&mut r, "stop");
    assert!(!r.grep_running());
    assert_eq!(r.message(), "Stopped");
    for _ in 0..10 {
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(r.message(), "Stopped");
}

#[test]
fn rg_project_uses_type_completion_and_skips_the_directory_prompt() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.c"), "needle\n").unwrap();
    std::fs::write(dir.path().join("b.txt"), "needle\n").unwrap();
    let Some(mut r) = runtime(dir.path()) else {
        return;
    };
    command(&mut r, "rg-project needle");
    wait(&mut r, |r| note(r) == Some("rg files"));
    r.input(UserInput::Paste("c".into()));
    // Match the exact alias rather than a fuzzy name containing c.
    keys(&mut r, "RET");
    finish(&mut r);
    assert!(r.layer().is_none());
    assert!(r.message().starts_with("1 matches"), "{}", r.message());
    assert!(results(&r).contains("a.c\n"));
    assert!(!results(&r).contains("b.txt\n"));
}

#[test]
fn rg_caps_results_and_replaces_an_unfinished_search() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "needle\n".repeat(10_002)).unwrap();
    let Some(mut r) = runtime(dir.path()) else {
        return;
    };
    lua(&mut r, "require('rg').search({pattern='needle'})");
    finish(&mut r);
    assert_eq!(r.message(), "10000 matches for needle (stopped there)");
    assert_eq!(
        results(&r)
            .lines()
            .filter(|line| soda::interaction::grep::row(line).is_some())
            .count(),
        10_000
    );
    lua(&mut r, "require('rg').search({pattern='needle'})");
    lua(&mut r, "require('rg').search({pattern='missing'})");
    finish(&mut r);
    assert_eq!(r.message(), "0 matches for missing");
    assert!(!results(&r).contains("needle"));
}
