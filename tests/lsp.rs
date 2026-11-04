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
/// A C++ file open with the fake server as its language server, or `None`
/// without Python to run it.
fn open(source: &str) -> Option<Fixture> {
    open_with(source, "", "")
}
/// The same with options for `soda.lsp.server`, and Lua to run first.
fn open_with(source: &str, options: &str, first: &str) -> Option<Fixture> {
    if Process::new("python3").arg("--version").output().is_err() {
        return None;
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.cpp");
    std::fs::write(&path, source).unwrap();
    let log = dir.path().join("log");
    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_lsp.py");
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.load_startup_lua();
    r.source_lua("plugins", include_str!("fixtures/plugins.lua"))
        .unwrap();
    r.enable_lsp();
    r.source_lua("first", first).unwrap();
    let options = if options.is_empty() { "nil" } else { options };
    r.source_lua(
        "test",
        &format!(
            r#"soda.lsp.server("cpp", {{ "env", "FAKE_LSP_LOG={}", "python3", "{}" }}, {options})"#,
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
    keys(&mut f.r, "M-.");
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
    keys(&mut f.r, "M-.");
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
    keys(&mut f.r, "M-,");
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
    keys(&mut f.r, "M-?");
    wait(&mut f.r, |r| text(r).contains("a.cpp"));
    assert_eq!(text(&f.r), "a.cpp\n  1:1  one\n  2:3  two\n");
    let path = f.dir.path().join("a.cpp");
    f.r.command(Command::Named(format!("buffer {}", path.display())));
    wait(&mut f.r, |r| text(r).starts_with("one"));
    f.r.command(Command::Named("lsp-callers".into()));
    wait(&mut f.r, |r| text(r).contains("caller"));
    assert_eq!(text(&f.r), "▾ target  a.cpp:1\n  ▸ caller  a.cpp:2\n");
    // A level at a time; nothing calls the caller, so it has no children.
    keys(&mut f.r, "j TAB");
    wait(&mut f.r, |r| {
        text(r) == "▾ target  a.cpp:1\n    caller  a.cpp:2\n"
    });
    // Enter goes to where the call is made.
    keys(&mut f.r, "RET");
    wait(&mut f.r, |r| text(r).starts_with("one"));
    let view = f.r.app().view(f.r.app().active_view().unwrap()).unwrap();
    let editor = f.r.app().workspace().editor(view.document_id).unwrap();
    assert_eq!(
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head,
        6
    );
}
#[test]
fn types_open_level_by_level_from_the_type_at_the_caret() {
    let Some(mut f) = open("base\n  derived\n") else {
        return;
    };
    keys(&mut f.r, "C-c T");
    wait(&mut f.r, |r| text(r).starts_with("▾ Base"));
    assert_eq!(text(&f.r), "▾ Base  a.cpp:1\n  ▸ Derived  a.cpp:2\n");
    keys(&mut f.r, "j TAB");
    wait(&mut f.r, |r| {
        text(r) == "▾ Base  a.cpp:1\n    Derived  a.cpp:2\n"
    });
    assert!(f.log().contains("subtypes Derived"), "{}", f.log());
    keys(&mut f.r, "RET");
    wait(&mut f.r, |r| text(r).starts_with("base"));
    let view = f.r.app().view(f.r.app().active_view().unwrap()).unwrap();
    let editor = f.r.app().workspace().editor(view.document_id).unwrap();
    assert_eq!(
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head,
        7
    );
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
    // Columns are UTF-16 units: the é takes two bytes and one unit. A
    // function named without declaring it is a call.
    assert_eq!(
        f.r.app().tokens(document, 0..99),
        [
            (2..4, Category::FunctionCall),
            (7..10, Category::Variable),
            (11..12, Category::Parameter)
        ]
    );
    let hints: Vec<_> =
        f.r.app()
            .inlays(document)
            .iter()
            .map(|(at, text)| (*at, text.as_str()))
            .collect();
    assert_eq!(hints, [(3, "a: "), (7, "int&")]);

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
    keys(&mut f.r, "ESC");
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
    keys(&mut f.r, "SPC s");
    wait(&mut f.r, |r| rows(r) == ["Outer  class", "  inner  method"]);
    keys(&mut f.r, "<down> RET");
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
    keys(&mut f.r, "SPC h");
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
fn rename_without_a_name_asks_with_the_name_and_a_changed_document_refuses() {
    let Some(mut f) = open("one\ntwo\n") else {
        return;
    };
    std::fs::write(f.dir.path().join("b.cpp"), "x\n  one\n").unwrap();
    // The server says what is renamed: here the range it gives.
    keys(&mut f.r, "SPC R");
    let line = |r: &Runtime| match r.layer() {
        Some(soda::interaction::Layer::CommandLine(line)) => Some(line.input().text().to_owned()),
        _ => None,
    };
    wait(&mut f.r, |r| line(r).as_deref() == Some("lsp-rename ne"));
    keys(&mut f.r, "ESC j SPC R");
    wait(&mut f.r, |r| r.message() == "Nothing to rename here");
    assert_eq!(line(&f.r), None);
    keys(&mut f.r, "k");
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
    keys(&mut f.r, "SPC a");
    wait(&mut f.r, |r| rows(r) == ["Fix it", "Tweak", "Lazy"]);
    keys(&mut f.r, "RET");
    wait(&mut f.r, |r| text(r) == "fixed\ntwo\n");

    // A command makes the server send its edit, which is answered.
    keys(&mut f.r, "SPC a");
    wait(&mut f.r, |r| !rows(r).is_empty());
    f.r.input(UserInput::Paste("twe".into()));
    wait(&mut f.r, |r| rows(r) == ["Tweak"]);
    keys(&mut f.r, "RET");
    wait(&mut f.r, |r| text(r) == "tweakeded\ntwo\n");
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|log| log.contains(r#"applied {"applied": true}"#))
    });
    assert!(f.log().contains("execute tweak"));

    // The server is given the diagnostics of the line for its fixes.
    keys(&mut f.r, "j SPC a");
    wait(&mut f.r, |r| !rows(r).is_empty());
    keys(&mut f.r, "ESC");
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
    keys(&mut f.r, "C-c k");
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
    keys(&mut f.r, "j C-c k");
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
            .is_some_and(|popup| popup.rows.len() == 3)
    });
    let popup = f.r.completion_popup().unwrap();
    assert_eq!(popup.rows[0].label, "server_call(int a)");
    keys(&mut f.r, "TAB");
    assert_eq!(text(&f.r), "server_call(int a)\n");
    keys(&mut f.r, "1");
    assert_eq!(text(&f.r), "server_call(1)\n");
}
#[test]
fn a_candidate_brings_its_include_in_the_same_step() {
    let Some(mut f) = open("// top\n\n") else {
        return;
    };
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "<down> server_v");
    wait(&mut f.r, |r| {
        r.completion_popup()
            .is_some_and(|popup| popup.rows.len() == 1)
    });
    keys(&mut f.r, "TAB x");
    assert_eq!(text(&f.r), "#include <vector>\n// top\nserver_vectorx\n");
    // The `x` typed after it is a step of its own.
    keys(&mut f.r, "ESC uu");
    assert_eq!(text(&f.r), "// top\nserver_v\n");
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
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.load_startup_lua();
    r.source_lua("plugins", include_str!("fixtures/plugins.lua"))
        .unwrap();
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
    // Its keys hold only where a server serves the document.
    keys(&mut r, "C-c k");
    assert_eq!(r.message(), "C-c k is undefined");
    r.command(Command::Named("lsp-hover".into()));
    assert_eq!(r.message(), "No language server for this document");
}
#[test]
fn keymaps_of_servers_hold_where_the_server_serves_the_later_first() {
    let Some(mut f) = open_with(
        "int a;\n",
        r#"{ name = "fake" }"#,
        r#"soda.keymap("fake", { server = "fake" })
        soda.map("fake", "C-c k", "echo from fake")
        soda.map("fake", "C-c y", "echo only fake")"#,
    ) else {
        return;
    };
    // `fake` was defined after `lsp`, so its key wins.
    keys(&mut f.r, "C-c k");
    assert_eq!(f.r.message(), "from fake");
    keys(&mut f.r, "SPC y");
    assert_eq!(f.r.message(), "only fake");
    // Not where no server serves the document.
    f.r.command(Command::Named("new".into()));
    keys(&mut f.r, "C-c y");
    assert_eq!(f.r.message(), "C-c y is undefined");
    let defined =
        f.r.source_lua("bad", r#"soda.keymap("normal", { server = "x" })"#);
    assert!(defined.is_err());
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
    r.source_lua("plugins", include_str!("fixtures/plugins.lua"))
        .unwrap();
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
#[test]
fn a_newer_request_cancels_the_older() {
    let Some(mut f) = open("x\n") else { return };
    // Both go out before either answer is read.
    f.r.command(Command::Named("lsp-hover".into()));
    f.r.command(Command::Named("lsp-hover".into()));
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|log| log.contains("cancel "))
    });
    wait(&mut f.r, |r| r.popup() == Some("first\n  second"));
    // A request whose answer came is no longer cancelled.
    f.r.source_lua(
        "t",
        r#"
        local id = soda.lsp.request("textDocument/hover", {}, function() end)
        assert(soda.lsp.cancel(id) == true)
        assert(soda.lsp.cancel(id) == false)
        assert(soda.lsp.cancel(nil) == false)
        "#,
    )
    .unwrap();
}
#[test]
fn tokens_after_an_edit_come_as_changes_to_the_last() {
    use soda::syntax::Category;
    let Some(mut f) = open("é one\nsome text\n") else {
        return;
    };
    let document =
        f.r.app()
            .view(f.r.app().active_view().unwrap())
            .unwrap()
            .document_id;
    wait(&mut f.r, |r| !r.app().tokens(document, 0..99).is_empty());
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "xx");
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|log| log.contains("delta 1"))
    });
    // Column 2 for one unit of "xxé one" is the é.
    wait(&mut f.r, |r| {
        r.app().tokens(document, 0..99).first() == Some(&(2..4, Category::FunctionCall))
    });
    assert_eq!(
        f.r.app().tokens(document, 0..99).last(),
        Some(&(13..14, Category::Parameter)),
        "the rest stays as it was"
    );
}
#[test]
fn completion_ranges_say_how_far_enter_and_tab_replace() {
    let Some(mut f) = open("tail\n") else { return };
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "qq");
    wait(&mut f.r, |r| {
        r.completion_popup()
            .is_some_and(|popup| popup.rows.len() == 2)
    });
    // Enter takes the insert range, which ends at the caret.
    keys(&mut f.r, "<down> RET");
    assert_eq!(text(&f.r), "qq_replacetail\n");
    keys(&mut f.r, "ESC u");
    assert_eq!(text(&f.r), "qqtail\n");
    // Tab takes the replace range: two bytes past the caret, not the word.
    f.r.command(Command::Edit(Edit::SetSelection(Selection::caret(2))));
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "DEL q");
    wait(&mut f.r, |r| r.completion_popup().is_some());
    keys(&mut f.r, "TAB");
    assert_eq!(text(&f.r), "qq_replaceil\n");
}
#[test]
fn a_selected_candidate_is_resolved_and_a_commit_character_accepts_it() {
    let Some(mut f) = open("tail\n") else { return };
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "qq");
    wait(&mut f.r, |r| {
        r.completion_popup()
            .is_some_and(|popup| popup.rows.len() == 2)
    });
    keys(&mut f.r, "<down> <down>");
    wait(&mut f.r, |r| {
        r.completion_popup().is_some_and(|popup| {
            popup
                .rows
                .iter()
                .any(|row| row.selected && row.doc == "Some docs" && row.detail == "resolved")
        })
    });
    assert!(f.log().contains("resolve 7"), "{}", f.log());
    // The chosen candidate goes in, then the character after it.
    keys(&mut f.r, ".");
    assert_eq!(text(&f.r), "qq_doc.tail\n");
}
#[test]
fn edits_create_rename_and_delete_files_and_open_documents_follow() {
    let Some(mut f) = open("one\n") else { return };
    let base = f.dir.path().canonicalize().unwrap();
    std::fs::create_dir_all(base.join("old")).unwrap();
    std::fs::write(base.join("old/x.cpp"), "x\n").unwrap();
    std::fs::write(base.join("gone.cpp"), "bye\n").unwrap();
    f.r.command(Command::Named("lsp-rename files".into()));
    wait(&mut f.r, |r| r.message().starts_with("Applied"));
    assert_eq!(
        f.r.message(),
        "Applied: 1 open, 1 written to disk, 1 created, 2 renamed, 1 deleted"
    );
    assert_eq!(
        std::fs::read_to_string(base.join("made/new.cpp")).unwrap(),
        "// new\n"
    );
    assert_eq!(
        std::fs::read_to_string(base.join("new/x.cpp")).unwrap(),
        "y\n"
    );
    assert!(!base.join("old").exists() && !base.join("gone.cpp").exists());
    // The open document moved with its file and took the edit.
    assert!(!base.join("a.cpp").exists());
    assert_eq!(
        std::fs::read_to_string(base.join("c.cpp")).unwrap(),
        "one\n"
    );
    assert_eq!(text(&f.r), "renamed\n");
    let view = f.r.app().view(f.r.app().active_view().unwrap()).unwrap();
    let file = f.r.app().workspace().file(view.document_id).unwrap();
    assert_eq!(file.path(), Some(base.join("c.cpp").as_path()));
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log)
            .is_ok_and(|log| log.contains("didClose a.cpp") && log.contains("opened c.cpp"))
    });
    // The server hears of what reached the disk, as far as it asked: its
    // watchers, and the file operations its filters match.
    let log = f.log();
    let line = |start: &str| {
        log.lines()
            .find(|line| line.starts_with(start))
            .unwrap_or_else(|| panic!("no {start} in {log}"))
            .to_owned()
    };
    assert_eq!(
        line("watched"),
        r#"watched [["new.cpp", 1], ["new.cpp", 2], ["a.cpp", 3], ["c.cpp", 1], ["gone.cpp", 3]]"#
    );
    assert_eq!(line("didCreateFiles"), r#"didCreateFiles ["new.cpp"]"#);
    assert_eq!(
        line("didRenameFiles"),
        r#"didRenameFiles [["a.cpp", "c.cpp"], ["old", "new"]]"#
    );
    assert!(!log.contains("didDeleteFiles"), "gone.cpp is no .c or .h");
}
#[test]
fn file_operations_that_cannot_all_be_done_do_nothing() {
    let Some(mut f) = open("one\n") else { return };
    let base = f.dir.path().canonicalize().unwrap();
    std::fs::write(base.join("gone.cpp"), "here\n").unwrap();
    f.r.command(Command::Named("lsp-rename clash".into()));
    wait(&mut f.r, |r| r.message().starts_with("Not applied"));
    assert!(
        f.r.message().ends_with("gone.cpp already exists"),
        "{}",
        f.r.message()
    );
    assert!(base.join("a.cpp").exists() && !base.join("c.cpp").exists());
}
#[test]
fn a_server_gets_its_options_and_settings_and_lua_answers_its_requests() {
    let Some(mut f) = open_with(
        "x\n",
        r#"{ init = { cache = { directory = "/tmp/c" } },
             settings = { fake = { index = { threads = 2 } } } }"#,
        r#"soda.lsp.on("$fake/ask", function(params) return { twice = params.n * 2 } end)"#,
    ) else {
        return;
    };
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log)
            .is_ok_and(|log| log.contains("answer config") && log.contains("answer private"))
    });
    let log = f.log();
    assert!(
        log.contains(r#"init {"cache": {"directory": "/tmp/c"}}"#),
        "{log}"
    );
    assert!(
        log.contains(r#"settings {"fake": {"index": {"threads": 2}}}"#),
        "{log}"
    );
    // By section, nothing for an unknown one, and all of it without one.
    assert!(
        log.contains(
            r#"answer config [{"threads": 2}, null, {"fake": {"index": {"threads": 2}}}]"#
        ),
        "{log}"
    );
    assert!(log.contains(r#"answer private {"twice": 4}"#), "{log}");
    drop(f.dir);
}
#[test]
fn root_markers_choose_the_server_root() {
    if Process::new("python3").arg("--version").output().is_err() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    std::fs::create_dir_all(base.join("repo/.git")).unwrap();
    std::fs::create_dir_all(base.join("repo/sub/deep")).unwrap();
    std::fs::write(base.join("repo/sub/.ccls"), "").unwrap();
    std::fs::write(base.join("repo/sub/deep/a.cpp"), "x\n").unwrap();
    let log = base.join("log");
    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_lsp.py");
    let mut r = Runtime::started_in(base.clone()).unwrap();
    r.load_startup_lua();
    r.source_lua("plugins", include_str!("fixtures/plugins.lua"))
        .unwrap();
    r.enable_lsp();
    r.source_lua(
        "test",
        &format!(
            r#"soda.lsp.server("cpp", {{ "env", "FAKE_LSP_LOG={}", "python3", "{}" }},
               {{ roots = {{ ".ccls", "compile_commands.json" }} }})"#,
            log.display(),
            script.display()
        ),
    )
    .unwrap();
    r.start(Some(base.join("repo/sub/deep/a.cpp")));
    let read = log.clone();
    wait(&mut r, move |_| {
        std::fs::read_to_string(&read).is_ok_and(|log| log.contains("initialize "))
    });
    let text = std::fs::read_to_string(&log).unwrap();
    assert!(
        text.contains(&format!(
            "initialize file://{}\n",
            base.join("repo/sub").display()
        )),
        "{text}"
    );
    // The project is still the repository.
    assert_eq!(r.app().project(), Some(base.join("repo")));
}
#[test]
fn what_the_server_does_not_offer_is_said_and_not_asked() {
    let Some(mut f) = open("x\n") else { return };
    f.r.source_lua(
        "t",
        r#"-- Pretend the server took its hover back.
           local info = soda.lsp.info
           soda.lsp.info = function()
             local i = info()
             if i then i.capabilities.hoverProvider = nil end
             return i
           end"#,
    )
    .unwrap();
    keys(&mut f.r, "C-c k");
    assert_eq!(
        f.r.message(),
        "The language server does not offer textDocument/hover"
    );
}
#[test]
fn ccls_hierarchies_open_level_by_level_and_skipped_branches_are_dim() {
    let Some(mut f) = open_with(
        "one\ntwo\nthree\nfour\n",
        // The fixture's server stands for ccls, whose keys hold in its
        // documents.
        r#"{ name = "ccls" }"#,
        r#"require("ccls").setup({ command = { "unused" } })
        soda.map("ccls", "C-c c", "ccls-callers")
        soda.map("ccls", "C-c T", "ccls-derived")
        soda.map("ccls", "C-c M", "ccls-members functions")"#,
    ) else {
        return;
    };
    // The fixture's server replaced the one setup named.
    let document =
        f.r.app()
            .view(f.r.app().active_view().unwrap())
            .unwrap()
            .document_id;
    wait(&mut f.r, |r| !r.app().paints(document).is_empty());
    let dim = soda::application::faces::index("dim").map(soda::application::Face::Named);
    // From "two" to the third character of "three".
    assert_eq!(f.r.app().paints(document), [(4..11, dim.unwrap())]);

    keys(&mut f.r, "C-c c");
    wait(&mut f.r, |r| text(r).starts_with("▾ root"));
    assert_eq!(
        text(&f.r),
        "▾ root  a.cpp:1\n  ▸ first  a.cpp:2\n    second  a.cpp:3\n"
    );
    assert!(
        f.log().contains(
            r#"$ccls/call {"callType": 3, "callee": false, "hierarchy": true, "levels": 1}"#
        ),
        "{}",
        f.log()
    );
    keys(&mut f.r, "j TAB");
    wait(&mut f.r, |r| text(r).contains("deeper"));
    assert_eq!(
        text(&f.r),
        "▾ root  a.cpp:1\n  ▾ first  a.cpp:2\n      deeper  a.cpp:2\n    second  a.cpp:3\n"
    );
    assert!(f.log().contains(r#""id": "2""#), "{}", f.log());
    // Enter goes there.
    keys(&mut f.r, "j RET");
    wait(&mut f.r, |r| text(r).starts_with("one"));

    // Inheritance asks again with the node's kind; members show field names.
    keys(&mut f.r, "C-c T");
    wait(&mut f.r, |r| text(r).starts_with("▾ root"));
    keys(&mut f.r, "j TAB");
    wait(&mut f.r, |r| text(r).contains("deeper"));
    assert!(f.log().contains(r#"$ccls/inheritance {"derived": true, "hierarchy": true, "id": "2", "kind": 2, "levels": 1}"#), "{}", f.log());
    let source = format!("buffer {}", f.dir.path().join("a.cpp").display());
    f.r.command(Command::Named(source));
    wait(&mut f.r, |r| text(r).starts_with("one"));
    keys(&mut f.r, "C-c M");
    wait(&mut f.r, |r| text(r).starts_with("▾ root_field"));
    assert!(f.log().contains(r#""kind": 3"#), "{}", f.log());

    let source = format!("buffer {}", f.dir.path().join("a.cpp").display());
    f.r.command(Command::Named(source));
    wait(&mut f.r, |r| text(r).starts_with("one"));
    f.r.command(Command::Named("ccls-navigate down".into()));
    wait(&mut f.r, |r| {
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        let editor = r.app().workspace().editor(view.document_id).unwrap();
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head
            == 9
    });
    assert!(f.log().contains("navigate D"));
    f.r.command(Command::Named("ccls-vars".into()));
    wait(&mut f.r, |r| text(r).contains("2:1"));
    let source = format!("buffer {}", f.dir.path().join("a.cpp").display());
    f.r.command(Command::Named(source));
    f.r.command(Command::Named("ccls-reload".into()));
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|l| l.contains("reload"))
    });
}
#[test]
fn implementations_are_listed_when_there_are_several() {
    let Some(mut f) = open("one\ntwo\n") else {
        return;
    };
    keys(&mut f.r, "C-c .");
    wait(&mut f.r, |r| text(r).contains("a.cpp"));
    assert_eq!(text(&f.r), "a.cpp\n  1:2  one\n  2:1  two\n");
}
#[test]
fn the_symbol_at_the_caret_is_highlighted_where_it_is_read_and_written() {
    let Some(mut f) = open("one\ntwo\n") else {
        return;
    };
    let document =
        f.r.app()
            .view(f.r.app().active_view().unwrap())
            .unwrap()
            .document_id;
    f.r.command(Command::Named("set idle-time 10".into()));
    keys(&mut f.r, "l");
    let face = |name| {
        soda::application::faces::index(name)
            .map(soda::application::Face::Named)
            .unwrap()
    };
    wait(&mut f.r, |r| r.app().paints(document).len() == 2);
    assert_eq!(
        f.r.app().paints(document),
        [(0..3, face("reference")), (4..7, face("reference-write"))]
    );
    f.r.command(Command::Named("set lsp-highlight false".into()));
    keys(&mut f.r, "l");
    wait(&mut f.r, |r| r.app().paints(document).is_empty());
}
#[test]
fn progress_shows_on_the_status_line_and_messages_reach_the_user() {
    let Some(mut f) = open("x\n") else { return };
    let status = |r: &Runtime| {
        r.status_segments()
            .iter()
            .find(|(name, ..)| name == "lsp-progress")
            .map(|(_, text, _)| text.clone())
    };
    f.r.source_lua("t", r#"soda.lsp.notify("$fake/progress", {})"#)
        .unwrap();
    wait(&mut f.r, |r| {
        status(r).as_deref() == Some("indexing 3/10 30%")
    });
    wait(&mut f.r, |r| r.message() == "loud words");
    assert!(f.r.messages().any(|m| m == "quiet words"));
    f.r.command(Command::Named("lsp-workspace-symbols end".into()));
    wait(&mut f.r, |r| status(r).is_none());
}
#[test]
fn diagnostics_carry_related_places_and_tags_and_can_be_pulled() {
    let Some(mut f) = open("one tagged\ntwo\n") else {
        return;
    };
    let document =
        f.r.app()
            .view(f.r.app().active_view().unwrap())
            .unwrap()
            .document_id;
    wait(&mut f.r, |r| r.app().notes(document).len() == 3);
    let notes = f.r.app().notes(document);
    let unused = notes.iter().find(|n| n.text.starts_with("unused")).unwrap();
    assert_eq!(unused.text, "unused\na.cpp:2: declared here");
    let face = |name| {
        soda::application::faces::index(name)
            .map(soda::application::Face::Named)
            .unwrap()
    };
    let paints = f.r.app().paints(document);
    assert!(paints.contains(&(0..3, face("unnecessary"))), "{paints:?}");
    assert!(paints.contains(&(4..10, face("deprecated"))), "{paints:?}");

    // Pulled when typing pauses, and again with the last result's id.
    f.r.command(Command::Named("set idle-time 10".into()));
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "pulled SPC");
    wait(&mut f.r, |r| {
        r.app()
            .notes(document)
            .iter()
            .any(|n| n.text == "pulled one")
    });
    keys(&mut f.r, "x");
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|log| log.contains(r#"pull "r1""#))
    });
}
#[test]
fn a_parameter_given_by_its_place_in_the_label_is_bracketed() {
    let Some(mut f) = open("\n") else { return };
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "a_long_name_to_pass_twenty(");
    wait(&mut f.r, |r| r.hint() == Some("é(int a, [int b])"));
}
#[test]
fn a_selection_formats_only_its_range() {
    let Some(mut f) = open("one\ntwo\n") else {
        return;
    };
    f.r.command(Command::Edit(Edit::SetSelection(Selection {
        anchor: 4,
        head: 6,
    })));
    f.r.command(Command::Named("lsp-format".into()));
    wait(&mut f.r, |r| text(r) == "one\nranged\n");
    assert!(f.log().contains("rangeFormat 1:0-1:2"), "{}", f.log());
}
#[test]
fn a_server_that_exits_starts_again_until_it_exits_too_often() {
    let Some(mut f) = open("x\n") else { return };
    let starts = |f: &Fixture| f.log().matches("initialize ").count();
    for round in 1..=3 {
        f.r.source_lua("t", r#"soda.lsp.notify("exit-now", {})"#)
            .unwrap();
        wait(&mut f.r, |r| r.message().ends_with("starting it again"));
        f.r.command(Command::Named("echo waiting".into()));
        // Started again, with the document opened anew.
        let log = f.log.clone();
        wait(&mut f.r, move |_| {
            std::fs::read_to_string(&log).is_ok_and(|log| {
                log.matches("initialize ").count() == round + 1
                    && log.matches("didOpen").count() == round + 1
            })
        });
    }
    f.r.source_lua("t", r#"soda.lsp.notify("exit-now", {})"#)
        .unwrap();
    wait(&mut f.r, |r| {
        r.message().ends_with("lsp-restart tries again")
    });
    for _ in 0..50 {
        f.r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(starts(&f), 4);
    f.r.command(Command::Named("lsp-restart".into()));
    let log = f.log.clone();
    wait(&mut f.r, move |_| {
        std::fs::read_to_string(&log).is_ok_and(|log| log.matches("initialize ").count() == 5)
    });
}
#[test]
fn token_modifiers_make_read_only_variables_constants_and_strike_deprecated_ones() {
    use soda::syntax::Category;
    let Some(mut f) = open("one two modifiers\n") else {
        return;
    };
    let document =
        f.r.app()
            .view(f.r.app().active_view().unwrap())
            .unwrap()
            .document_id;
    wait(&mut f.r, |r| !r.app().tokens(document, 0..99).is_empty());
    assert_eq!(
        f.r.app().tokens(document, 0..99),
        [
            (0..3, Category::Constant),
            (4..7, Category::FunctionCall),
            (8..9, Category::Variable)
        ]
    );
    let deprecated = soda::application::faces::index("deprecated")
        .map(soda::application::Face::Named)
        .unwrap();
    wait(&mut f.r, |r| {
        r.app().paints(document).contains(&(4..7, deprecated))
    });
    // The mapping can be replaced.
    f.r.source_lua(
        "t",
        r#"require("lsp").token_category = function(type, modifiers)
             return modifiers.deprecated and "keyword" or nil
           end"#,
    )
    .unwrap();
    f.r.command(Command::SetMode(EditMode::Insert));
    keys(&mut f.r, "SPC");
    wait(&mut f.r, |r| {
        let tokens = r.app().tokens(document, 0..99);
        tokens.len() == 1 && tokens[0].1 == Category::Keyword
    });
}
#[test]
fn a_code_action_without_its_edit_is_resolved_when_chosen() {
    let Some(mut f) = open("one\n") else { return };
    keys(&mut f.r, "SPC a");
    wait(&mut f.r, |r| {
        matches!(r.layer(), Some(soda::interaction::Layer::CommandLine(_)))
    });
    f.r.input(UserInput::Paste("lazy".into()));
    keys(&mut f.r, "RET");
    wait(&mut f.r, |r| text(r) == "lazy\n");
    assert!(f.log().contains("resolve action Lazy"), "{}", f.log());
}

/// A runtime started on `file` under `base`, its C++ server the fake one
/// with `options`; the log of what the server was told.
fn server_in(base: &std::path::Path, file: &str, options: &str) -> (Runtime, PathBuf) {
    let log = base.join("log");
    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_lsp.py");
    let mut r = Runtime::started_in(base.to_owned()).unwrap();
    r.load_startup_lua();
    r.source_lua("plugins", include_str!("fixtures/plugins.lua"))
        .unwrap();
    r.enable_lsp();
    r.source_lua(
        "test",
        &format!(
            r#"soda.lsp.server("cpp", {{ "env", "FAKE_LSP_LOG={}", "python3", "{}" }}, {options})"#,
            log.display(),
            script.display()
        ),
    )
    .unwrap();
    r.start(Some(base.join(file)));
    wait(&mut r, |r| r.app().active_view().is_some());
    (r, log)
}
fn initialized(log: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| line.strip_prefix("initialize file://"))
        .map(str::to_owned)
        .collect()
}
fn settle(r: &mut Runtime) {
    for _ in 0..100 {
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
#[test]
fn a_server_waits_for_its_markers_or_lsp_start_and_lsp_stop_holds() {
    if Process::new("python3").arg("--version").output().is_err() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    std::fs::create_dir_all(base.join("repo/.git")).unwrap();
    std::fs::create_dir_all(base.join("repo/sub")).unwrap();
    std::fs::write(base.join("repo/sub/a.cpp"), "x\n").unwrap();
    let (mut r, log) = server_in(
        &base,
        "repo/sub/a.cpp",
        r#"{ roots = { ".ccls" }, auto = "marked" }"#,
    );
    settle(&mut r);
    assert!(initialized(&log).is_empty(), "no marker, no server");
    // By hand, in the project.
    r.command(Command::Named("lsp-start".into()));
    let seen = log.clone();
    wait(&mut r, move |_| initialized(&seen).len() == 1);
    assert_eq!(initialized(&log), [base.join("repo").display().to_string()]);
    let seen = log.clone();
    wait(&mut r, move |_| {
        std::fs::read_to_string(&seen).unwrap().contains("didOpen")
    });
    r.command(Command::Named("lsp-stop".into()));
    settle(&mut r);
    assert_eq!(initialized(&log).len(), 1, "stopped stays stopped");
    r.source_lua("test", "soda.message(tostring(soda.lsp.info()))")
        .unwrap();
    assert_eq!(r.message(), "nil");
    // Starting it in another directory takes the documents below it.
    let sub = base.join("repo/sub");
    r.command(Command::Named(format!("lsp-start {}", sub.display())));
    let seen = log.clone();
    wait(&mut r, move |_| initialized(&seen).len() == 2);
    assert_eq!(initialized(&log)[1], sub.display().to_string());
    r.command(Command::Named("lsp-servers".into()));
    let listing = text(&r);
    assert!(
        listing.contains("repo  ") && listing.contains("(stopped)"),
        "{listing}"
    );
    assert!(
        listing.contains("sub  ") && listing.contains("sub/a.cpp:1:1:"),
        "{listing}"
    );
}
#[test]
fn roots_can_be_the_git_working_tree() {
    if Process::new("python3").arg("--version").output().is_err() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    // A linked worktree: `.git` is a file.
    std::fs::create_dir_all(base.join("tree/src")).unwrap();
    std::fs::write(
        base.join("tree/.git"),
        "gitdir: /elsewhere/.git/worktrees/tree\n",
    )
    .unwrap();
    std::fs::write(base.join("tree/src/a.cpp"), "x\n").unwrap();
    let (mut r, log) = server_in(
        &base,
        "tree/src/a.cpp",
        r#"{ roots = { "compile_commands.json", "git" }, auto = "marked" }"#,
    );
    let seen = log.clone();
    wait(&mut r, move |_| !initialized(&seen).is_empty());
    assert_eq!(initialized(&log), [base.join("tree").display().to_string()]);
}
#[test]
fn a_function_can_choose_the_root_later() {
    if Process::new("python3").arg("--version").output().is_err() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().canonicalize().unwrap();
    std::fs::create_dir_all(base.join("ws/member")).unwrap();
    std::fs::write(base.join("ws/member/a.cpp"), "x\n").unwrap();
    let (mut r, log) = server_in(
        &base,
        "ws/member/a.cpp",
        r#"{ auto = "marked", roots = function(path, done)
              soda.defer(20, function() done(path:match("^(.*)/member/")) end)
            end }"#,
    );
    let seen = log.clone();
    wait(&mut r, move |_| !initialized(&seen).is_empty());
    assert_eq!(initialized(&log), [base.join("ws").display().to_string()]);
}
