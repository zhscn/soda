//! The client against a small fake server, and `lua/lsp.lua` over it.
use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::{
    path::PathBuf,
    process::Command as Process,
    time::{Duration, Instant},
};

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn wait(r: &mut Runtime, mut done: impl FnMut(&mut Runtime) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done(r) {
        assert!(
            Instant::now() < deadline,
            "timed out; message: {}",
            r.message()
        );
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
struct Fixture {
    dir: tempfile::TempDir,
    log: PathBuf,
    r: Runtime,
}
impl Fixture {
    fn log(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}
/// A C++ file open with the fake server in clangd's place, or `None`
/// without Python to run it.
fn open(source: &str) -> Option<Fixture> {
    if Process::new("python3").arg("--version").output().is_err() {
        return None;
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.cpp");
    std::fs::write(&path, source).unwrap();
    let log = dir.path().join("log");
    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_lsp.py");
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.load_startup_lua();
    r.enable_lsp();
    r.source_lua(
        "test",
        &format!(
            r#"soda.lsp.server("cpp", {{ "env", "FAKE_LSP_LOG={}", "python3", "{}" }})"#,
            log.display(),
            script.display()
        ),
    )
    .unwrap();
    r.start(Some(path));
    let mut fixture = Fixture { dir, log, r };
    wait(&mut fixture.r, |r| {
        r.app().active_view().is_some() && text(r) == source
    });
    let log = fixture.log.clone();
    wait(&mut fixture.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|log| log.contains("didOpen"))
    });
    Some(fixture)
}

#[test]
fn documents_reach_the_server_and_edits_follow() {
    let Some(mut f) = open("int a;\n") else {
        return;
    };
    assert!(
        f.log().contains(r#"didOpen 0 "int a;\n""#) || f.log().contains("didOpen"),
        "{}",
        f.log()
    );
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "x");
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).unwrap().contains("xint a;")
    });
}
#[test]
fn a_request_sends_pending_edits_first() {
    let Some(mut f) = open("é x\nsecond\n") else {
        return;
    };
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "y");
    f.r.command(Command::SetMode(EditMode::Normal));
    f.r.command(Command::Edit(Edit::SetSelection(Selection::caret(3))));
    keys(&mut f.r, "<a-.>");
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log)
            .unwrap()
            .contains("definition")
    });
    let log = f.log();
    let edit = log.find("y\\u00e9 x").expect("the edit");
    assert!(edit < log.find("definition").unwrap(), "{log}");
    // UTF-16: é is one unit, two bytes.
    assert!(log.contains(r#""character": 2"#), "{log}");
}
#[test]
fn going_to_a_definition_moves_and_comes_back() {
    let Some(mut f) = open("use\n  target\n") else {
        return;
    };
    keys(&mut f.r, "<a-.>");
    wait(&mut f.r, |r| {
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        let editor = r.app().workspace().editor(view.document_id).unwrap();
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head
            == 6
    });
    keys(&mut f.r, "<a-,>");
    let view = f.r.app().view(f.r.app().active_view().unwrap()).unwrap();
    let editor = f.r.app().workspace().editor(view.document_id).unwrap();
    assert_eq!(
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head,
        0
    );
}
#[test]
fn references_and_callers_are_results() {
    let Some(mut f) = open("one\n  two\n") else {
        return;
    };
    keys(&mut f.r, "<a-?>");
    wait(&mut f.r, |r| text(r).contains("a.cpp"));
    assert_eq!(text(&f.r), "a.cpp\n  1:1  one\n  2:3  two\n");
    let path = f.dir.path().join("a.cpp");
    f.r.command(Command::Named(format!("buffer {}", path.display())));
    wait(&mut f.r, |r| text(r).starts_with("one"));
    f.r.command(Command::Named("lsp-callers".into()));
    wait(&mut f.r, |r| text(r).contains("caller"));
    assert_eq!(text(&f.r), "a.cpp\n  2:3  caller\n");
}
#[test]
fn hover_shows_on_one_line() {
    let Some(mut f) = open("x\n") else { return };
    keys(&mut f.r, "K");
    wait(&mut f.r, |r| r.message() == "first second");
}
#[test]
fn the_server_completes_with_snippets() {
    let Some(mut f) = open("\n") else { return };
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "serv");
    wait(&mut f.r, |r| {
        r.completion_popup()
            .is_some_and(|popup| popup.rows.len() == 2)
    });
    let popup = f.r.completion_popup().unwrap();
    assert_eq!(popup.rows[0].label, "server_call(int a)");
    keys(&mut f.r, "<tab>");
    assert_eq!(text(&f.r), "server_call(int a)\n");
    keys(&mut f.r, "1");
    assert_eq!(text(&f.r), "server_call(1)\n");
}
#[test]
fn diagnostics_flag_lines_and_list() {
    let Some(mut f) = open("one\ntwo\n") else {
        return;
    };
    wait(&mut f.r, |r| {
        r.command(Command::Named("lsp-diagnostics".into()));
        text(r).contains("bad line")
    });
    assert_eq!(text(&f.r), "a.cpp\n  2:1  bad line\n");
    assert!(f.dir.path().exists());
}
#[test]
fn a_missing_server_is_said_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.cpp");
    std::fs::write(&path, "x\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.load_startup_lua();
    r.enable_lsp();
    r.source_lua("t", r#"soda.lsp.server("cpp", { "/no/such/server" })"#)
        .unwrap();
    r.start(Some(path));
    wait(&mut r, |r| r.message().contains("/no/such/server"));
    r.command(Command::Named("echo quiet".into()));
    for _ in 0..50 {
        r.poll();
    }
    assert_eq!(r.message(), "quiet");
    keys(&mut r, "K");
    assert_eq!(r.message(), "No language server for this document");
}
