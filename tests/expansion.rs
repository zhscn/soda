use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/project")).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn line(r: &mut Runtime, command: &str) {
    r.command(Command::Named(command.into()));
}
fn int(r: &Runtime, name: &str) -> u32 {
    let document = r
        .app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id;
    r.app().options().int(Some(document), name)
}

#[test]
fn options_and_values_expand_in_a_command_line() {
    let mut r = runtime("a\n\tbc\nd");
    line(&mut r, "set indent-width 6");
    line(&mut r, "set tab-width %opt{indent-width}");
    assert_eq!(int(&r, "tab-width"), 6);
    keys(&mut r, "jl");
    line(&mut r, "set scroll-lines %val{column}");
    assert_eq!(int(&r, "scroll-lines"), 7, "{}", r.message());
    line(&mut r, "set indent-width %val{line}");
    assert_eq!(int(&r, "indent-width"), 2);
}
#[test]
fn statements_expand_when_they_run() {
    let mut r = runtime("a\nb\nc\nd");
    line(
        &mut r,
        "define-command deep goto 4; set-local indent-width %val{line}",
    );
    line(&mut r, "deep");
    assert_eq!(int(&r, "indent-width"), 4, "{}", r.message());
    // Bodies keep their expansions until they run, here from a key.
    line(&mut r, "map normal Q set-local tab-width %val{line}");
    keys(&mut r, "<a-lt>jQ");
    assert_eq!(int(&r, "tab-width"), 2, "{}", r.message());
}
#[test]
fn a_failed_expansion_stops_the_statements_after_it() {
    let mut r = runtime("a");
    line(
        &mut r,
        "define-command bad set tab-width %val{nothing}; set indent-width 9",
    );
    line(&mut r, "bad");
    assert_eq!(r.message(), "%val{nothing}: unknown value");
    assert_eq!(int(&r, "indent-width"), 4);
    // A value of the wrong type is reported by the command it reaches.
    line(&mut r, "set tab-width %val{mode}");
    assert_eq!(r.message(), "set: tab-width takes a number from 1 to 16");
    line(&mut r, "set tab-width %opt{colour}");
    assert_eq!(r.message(), "%opt{colour}: unknown option");
    // Unknown commands are still found before anything runs.
    line(
        &mut r,
        "define-command typo set indent-width 3; frobnicate %val{line}",
    );
    line(&mut r, "typo");
    assert_eq!(r.message(), "unknown command: frobnicate");
    assert_eq!(int(&r, "indent-width"), 4);
}
#[test]
fn the_column_limit_comes_from_clang_format() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(".clang-format"), "ColumnLimit: 100\n").unwrap();
    std::fs::write(dir.path().join("a.cpp"), "int x;\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.source_lua(
        "init.lua",
        r#"assert(soda.command([[hook open .*\.cpp set-local ruler %val{column-limit}]]))"#,
    )
    .unwrap();
    r.start(Some(dir.path().join("a.cpp")));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while r.app().active_view().is_none() {
        assert!(std::time::Instant::now() < deadline);
        r.poll();
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    assert_eq!(int(&r, "ruler"), 100, "{}", r.message());
    r.command(Command::New);
    line(&mut r, "set-local ruler %val{column-limit}");
    assert_eq!(int(&r, "ruler"), 0);
}
