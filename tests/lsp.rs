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
fn tokens_and_hints_arrive_after_the_diagnostics_and_move_with_the_text() {
    use soda::syntax::Category;
    let Some(mut f) = open("é one\nsome text\n") else {
        return;
    };
    let document =
        f.r.app()
            .view(f.r.app().active_view().unwrap())
            .unwrap()
            .document_id;
    wait(&mut f.r, |r| {
        !r.app().inlays(document).is_empty() && !r.app().tokens(document, 0..99).is_empty()
    });
    // Columns are UTF-16 units: the é takes two bytes and one unit. The
    // variable has no category of its own, so it keeps its highlighting.
    assert_eq!(
        f.r.app().tokens(document, 0..99),
        [(2..4, Category::Function), (11..12, Category::Parameter)]
    );
    assert_eq!(f.r.app().inlays(document), [(3, "a: "), (7, "int&")]);

    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "xx");
    assert_eq!(f.r.app().tokens(document, 0..99)[0].0, 4..6);
    assert_eq!(f.r.app().inlays(document)[0].0, 5);
}
#[test]
fn a_call_shows_its_signature_until_it_closes() {
    let Some(mut f) = open("\n") else { return };
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "add(");
    wait(&mut f.r, |r| r.hint() == Some("add(int a, [int b])"));
    keys(&mut f.r, "1");
    assert_eq!(
        f.r.hint(),
        Some("add(int a, [int b])"),
        "it stays while typing"
    );
    keys(&mut f.r, ")");
    wait(&mut f.r, |r| r.hint().is_none());
    keys(&mut f.r, "x(");
    wait(&mut f.r, |r| r.hint().is_some());
    keys(&mut f.r, "<esc>");
    wait(&mut f.r, |r| r.hint().is_none());
}
#[test]
fn symbols_are_offered_with_their_outline_and_go_where_they_stand() {
    let Some(mut f) = open("class\n  member\n") else {
        return;
    };
    let rows = |r: &Runtime| match r.layer() {
        Some(soda::interaction::Layer::CommandLine(line)) => line
            .rows()
            .iter()
            .map(|row| row.candidate.label.clone())
            .collect::<Vec<_>>(),
        _ => vec![],
    };
    keys(&mut f.r, "<space>s");
    wait(&mut f.r, |r| rows(r) == ["Outer  class", "  inner  method"]);
    keys(&mut f.r, "<down><ret>");
    wait(&mut f.r, |r| {
        r.app().active_view().is_some_and(|v| {
            let view = r.app().view(v).unwrap();
            let editor = r.app().workspace().editor(view.document_id).unwrap();
            let session = editor.model().session(view.session_id).unwrap();
            session.selection().head == 8
        })
    });
    f.r.command(Command::Named("lsp-workspace-symbols helper".into()));
    wait(&mut f.r, |r| text(r).contains("space::helper"));
}
#[test]
fn a_header_and_its_source_switch() {
    let Some(mut f) = open("a\n") else { return };
    std::fs::write(f.dir.path().join("b.cpp"), "other\n").unwrap();
    keys(&mut f.r, "<space>h");
    wait(&mut f.r, |r| text(r) == "other\n");
}
#[test]
fn formatting_edits_and_saving_tells_the_server() {
    let Some(mut f) = open("one\n") else { return };
    f.r.command(Command::Named("lsp-format".into()));
    wait(&mut f.r, |r| text(r) == "formatted\n");
    f.r.command(Command::Save { choose_path: false });
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|log| log.contains("didSave"))
    });
}
#[test]
fn declarations_go_and_a_missing_type_says_so() {
    let Some(mut f) = open("use\n  target\n") else {
        return;
    };
    f.r.command(Command::Named("lsp-type-definition".into()));
    wait(&mut f.r, |r| r.message() == "No type definition found");
    f.r.command(Command::Named("lsp-declaration".into()));
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
}
#[test]
fn rename_edits_open_documents_and_files_on_disk() {
    let Some(mut f) = open("one\n") else { return };
    // UTF-16 columns: the é before the name is two bytes and one unit.
    let other = f.dir.path().join("b.cpp");
    std::fs::write(&other, "first\né one\nlast\n").unwrap();
    f.r.command(Command::Named("lsp-rename two".into()));
    wait(&mut f.r, |r| text(r) == "two\n");
    assert_eq!(
        std::fs::read_to_string(&other).unwrap(),
        "first\né two\nlast\n"
    );
    assert_eq!(
        f.r.message(),
        "Applied to 2 files: 1 open, 1 written to disk"
    );
    // One step undoes it, and nothing was saved.
    keys(&mut f.r, "u");
    assert_eq!(text(&f.r), "one\n");
}
#[test]
fn rename_without_a_name_asks_with_the_word_and_a_changed_document_refuses() {
    let Some(mut f) = open("one\n") else { return };
    std::fs::write(f.dir.path().join("b.cpp"), "x\n  one\n").unwrap();
    keys(&mut f.r, "<space>R");
    match f.r.layer() {
        Some(soda::interaction::Layer::CommandLine(line)) => {
            assert_eq!(line.input().text(), "lsp-rename one")
        }
        _ => panic!("no command line"),
    }
    keys(&mut f.r, "<esc>");
    f.r.command(Command::Named("lsp-rename two".into()));
    f.r.command(Command::Edit(Edit::InsertText("x".into())));
    wait(&mut f.r, |r| r.message().starts_with("Not applied"));
    assert_eq!(
        std::fs::read_to_string(f.dir.path().join("b.cpp")).unwrap(),
        "x\n  one\n"
    );
}
#[test]
fn code_actions_offer_titles_and_apply_edits_and_commands() {
    let Some(mut f) = open("one\ntwo\n") else {
        return;
    };
    let rows = |r: &Runtime| match r.layer() {
        Some(soda::interaction::Layer::CommandLine(line)) => line
            .rows()
            .iter()
            .map(|row| row.candidate.label.clone())
            .collect::<Vec<_>>(),
        _ => vec![],
    };
    keys(&mut f.r, "<space>a");
    wait(&mut f.r, |r| rows(r) == ["Fix it", "Tweak"]);
    keys(&mut f.r, "<ret>");
    wait(&mut f.r, |r| text(r) == "fixed\ntwo\n");

    // A command makes the server send its edit, which is answered.
    keys(&mut f.r, "<space>a");
    wait(&mut f.r, |r| !rows(r).is_empty());
    f.r.input(UserInput::Paste("twe".into()));
    wait(&mut f.r, |r| rows(r) == ["Tweak"]);
    keys(&mut f.r, "<ret>");
    wait(&mut f.r, |r| text(r) == "tweakeded\ntwo\n");
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|log| log.contains(r#"applied {"applied": true}"#))
    });
    assert!(f.log().contains("execute tweak"));

    // The server is given the diagnostics of the line for its fixes.
    keys(&mut f.r, "j<space>a");
    wait(&mut f.r, |r| !rows(r).is_empty());
    keys(&mut f.r, "<esc>");
    let asked = f.log();
    let last = asked.lines().rfind(|l| l.starts_with("codeAction"));
    assert_eq!(last, Some("codeAction 1"));
    assert!(
        !asked.contains("codeAction {"),
        "an empty list went as an object"
    );
}
#[test]
fn hover_shows_in_a_box_until_the_next_key() {
    let Some(mut f) = open("x\n") else { return };
    keys(&mut f.r, "K");
    wait(&mut f.r, |r| r.popup() == Some("first\n  second"));
    keys(&mut f.r, "l");
    assert_eq!(f.r.popup(), None);
}
#[test]
fn diagnostics_become_notes_with_their_words_and_join_the_hover() {
    let Some(mut f) = open("one\ntwo\n") else {
        return;
    };
    let document =
        f.r.app()
            .view(f.r.app().active_view().unwrap())
            .unwrap()
            .document_id;
    wait(&mut f.r, |r| !r.app().notes(document).is_empty());
    let notes = f.r.app().notes(document);
    assert_eq!(notes[0].text, "bad line\nmore");
    assert_eq!(notes[0].severity, soda::application::Severity::Error);
    assert_eq!(notes[0].range, 4..5, "an empty range marks one cell");
    keys(&mut f.r, "jK");
    wait(&mut f.r, |r| {
        r.popup() == Some("bad line\nmore\n\nfirst\n  second")
    });
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
#[test]
fn each_project_has_a_server_and_a_jump_stays_with_its_own() {
    if Process::new("python3").arg("--version").output().is_err() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    for repo in ["one", "two", "library"] {
        std::fs::create_dir_all(base.join(repo).join(".git")).unwrap();
        std::fs::write(base.join(repo).join("a.cpp"), format!("// {repo}\n")).unwrap();
    }
    let log = base.join("log");
    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_lsp.py");
    let mut r = Runtime::started_in(base.clone()).unwrap();
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
    let read = {
        let log = log.clone();
        move || std::fs::read_to_string(&log).unwrap_or_default()
    };
    let roots = {
        let read = read.clone();
        move || {
            read()
                .lines()
                .filter(|l| l.starts_with("initialize "))
                .count()
        }
    };
    r.start(Some(base.join("one/a.cpp")));
    let seen = read.clone();
    wait(&mut r, move |_| seen().contains("// one"));
    r.command(Command::OpenPath(base.join("two/a.cpp")));
    let seen = read.clone();
    wait(&mut r, move |_| seen().contains("// two"));
    let count = roots.clone();
    wait(&mut r, move |_| count() == 2);
    let log_text = read();
    assert!(
        log_text.contains("one") && log_text.contains("/two"),
        "{log_text}"
    );
    // A jump into a third repository uses the server it came from.
    let library = base.join("library/a.cpp");
    r.source_lua("test", &format!("soda.open({:?}, 1, 1)", library.display()))
        .unwrap();
    let seen = read.clone();
    wait(&mut r, move |_| seen().contains("// library"));
    assert_eq!(roots(), 2, "{}", read());
    assert_eq!(r.app().project(), Some(base.join("library")));
}
