//! Lua extensions: the soda table, hooks and commands as Lua functions,
//! background processes, errors and Lua started from Lua.
use soda::{
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::{path::PathBuf, time::Duration};

fn runtime() -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.input(UserInput::Paste("one\ntwo\nthree".into()));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn lua(r: &mut Runtime, code: &str) {
    r.source_lua("test", code).unwrap();
}

#[test]
fn lua_runs_commands_and_reads_state() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        local ok = soda.command("set tab-width 3")
        assert(ok)
        local ok, message = soda.command("no-such-command")
        assert(not ok and message:find("unknown command"), message)
        soda.message(soda.val("line") .. ":" .. soda.option("tab-width"))
        "#,
    );
    assert_eq!(r.app().options().int(None, "tab-width"), 3);
    assert_eq!(r.message(), "3:3");
    // The command line runs Lua too.
    r.command(Command::Named("lua soda.message(soda.val('mode'))".into()));
    assert_eq!(r.message(), "normal");
}
#[test]
fn hooks_and_commands_call_lua_functions() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        soda.hook("mode", "insert", function(mode) soda.message("now " .. mode) end)
        soda.define_command("greet", function(who) soda.message("hello " .. who) end)
        "#,
    );
    keys(&mut r, "i");
    assert_eq!(r.message(), "now insert");
    keys(&mut r, "<esc>");
    r.command(Command::Named("greet two words".into()));
    assert_eq!(r.message(), "hello two words");
    // Lua that Lua starts runs after it returns.
    lua(
        &mut r,
        r#"
        soda.command("lua soda.message('inner')")
        soda.message("outer")
        "#,
    );
    assert_eq!(r.message(), "inner");
    // Keys can be mapped to Lua.
    lua(
        &mut r,
        r#"soda.command("map normal Q lua soda.message('mapped')")"#,
    );
    keys(&mut r, "Q");
    assert_eq!(r.message(), "mapped");
}
#[test]
fn lua_flags_lines_and_runs_processes() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        soda.flag("git", "mark2", "+", {1, 3})
        soda.spawn({"sh", "-c", "read x; echo got $x; exit 3"}, function(code, out, err)
          soda.unflag("git")
          soda.message(code .. " " .. out:gsub("\n", ""))
        end, "input")
        "#,
    );
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let flagged: Vec<_> = r.app().flags(view.document_id).into_keys().collect();
    assert_eq!(flagged, [0, 2]);
    for _ in 0..400 {
        r.poll();
        if r.message().starts_with('3') {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(r.message(), "3 got input");
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    assert!(r.app().flags(view.document_id).is_empty());
}
#[test]
fn lua_errors_are_reported_and_logged() {
    let mut r = runtime();
    let error = r
        .source_lua("init.lua", "soda.flag('g', 'teal', '+', {1})")
        .unwrap_err();
    assert!(
        error.starts_with("lua: ") && error.contains("unknown face teal"),
        "{error}"
    );
    assert_eq!(r.message(), error);
    assert!(r.messages().any(|m| m == error));
    let error = r.source_lua("init.lua", "this is not lua").unwrap_err();
    assert!(error.contains("init.lua"), "{error}");
    // A failing hook function reports and leaves the editor working.
    lua(
        &mut r,
        "soda.hook('mode', 'insert', function() error('boom') end)",
    );
    keys(&mut r, "i");
    assert!(r.message().contains("boom"), "{}", r.message());
    assert_eq!(r.edit_mode(), EditMode::Insert);
}
#[test]
fn process_functions_act_where_the_process_started() {
    let mut r = runtime();
    let first = r
        .app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id;
    lua(
        &mut r,
        r#"
        soda.spawn({"sh", "-c", "sleep 0.05"}, function()
          soda.flag("build", "error", "x", {2})
          soda.message("flagged")
        end)
        "#,
    );
    r.command(Command::New);
    let second = r
        .app()
        .view(r.app().active_view().unwrap())
        .unwrap()
        .document_id;
    for _ in 0..400 {
        r.poll();
        if r.message() == "flagged" {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(r.message(), "flagged");
    assert_eq!(r.app().flags(first).into_keys().collect::<Vec<_>>(), [1]);
    assert!(r.app().flags(second).is_empty());
    assert_eq!(
        r.app()
            .view(r.app().active_view().unwrap())
            .unwrap()
            .document_id,
        second,
        "focus stays where the user is"
    );
}
