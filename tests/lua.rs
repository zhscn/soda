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
#[test]
fn buffers_read_text_by_line_and_column() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        assert(buf == soda.buffer())
        assert(buf:line_count() == 3)
        assert(buf:line(2) == "two")
        assert(buf:text() == "one\ntwo\nthree")
        assert(buf:text({1, 2}, {2, 3}) == "ne\ntw")
        assert(buf:text({2, 1}, {2, 4}) == "two")
        assert(buf:offset({2, 1}) == 5)
        local at = buf:point(5)
        assert(at[1] == 2 and at[2] == 1)
        assert(not pcall(buf.line, buf, 9))
        assert(not pcall(buf.text, buf, {1, 9}, {2, 1}))
        assert(not pcall(buf.text, buf, {2, 1}, {1, 1}))
        "#,
    );
}
#[test]
fn buffers_rejects_positions_inside_a_character() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        buf:edit({{{1, 1}, {1, 1}, "é"}})
        assert(buf:line(1) == "éone")
        assert(buf:text({1, 1}, {1, 3}) == "é")
        local ok, message = pcall(buf.text, buf, {1, 2}, {1, 3})
        assert(not ok and tostring(message):find("inside a character"), message)
        "#,
    );
}
#[test]
fn buffer_edits_in_a_request_undo_as_one_step() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        buf:edit({{{1, 1}, {1, 4}, "ONE"}, {{3, 1}, {3, 6}, "THREE"}})
        buf:edit({{{2, 1}, {2, 4}, "TWO"}})
        assert(buf:text() == "ONE\nTWO\nTHREE")
        "#,
    );
    keys(&mut r, "u");
    lua(
        &mut r,
        r#"assert(soda.buffer():text() == "one\ntwo\nthree")"#,
    );
    keys(&mut r, "<c-r>");
    lua(
        &mut r,
        r#"assert(soda.buffer():text() == "ONE\nTWO\nTHREE")"#,
    );
    // A later request is a step of its own.
    lua(&mut r, r#"soda.buffer():edit({{{1, 1}, {1, 1}, "x"}})"#);
    keys(&mut r, "u");
    lua(
        &mut r,
        r#"assert(soda.buffer():text() == "ONE\nTWO\nTHREE")"#,
    );
}
#[test]
fn buffer_edits_refuse_a_stale_revision() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        local revision = buf:revision()
        local after = buf:edit({{{1, 1}, {1, 1}, "x"}}, revision)
        assert(after ~= revision and after == buf:revision())
        local ok, message = pcall(buf.edit, buf, {{{1, 1}, {1, 1}, "y"}}, revision)
        assert(not ok and tostring(message):find("changed since"), message)
        assert(buf:line(1) == "xone")
        "#,
    );
}
#[test]
fn buffer_selection_reads_and_moves() {
    let mut r = runtime();
    // Normal mode keeps a caret, so a range collapses to its start.
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        buf:set_selection({2, 2}, {2, 4})
        local anchor, head = buf:selection()
        assert(anchor[1] == 2 and anchor[2] == 2 and head[2] == 2)
        "#,
    );
    keys(&mut r, "i");
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        buf:set_selection({2, 2}, {2, 4})
        local anchor, head = buf:selection()
        assert(anchor[1] == 2 and anchor[2] == 2 and head[2] == 4)
        "#,
    );
}
#[test]
fn buffer_selection_in_visual_mode() {
    let mut r = runtime();
    keys(&mut r, "gg0vl");
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        local anchor, head = buf:selection()
        assert(buf:text(anchor, head) == soda.val("selection"))
        assert(buf:text(anchor, head) == "on")
        "#,
    );
    assert_eq!(r.edit_mode(), EditMode::Visual);
}
#[test]
fn buffer_edits_in_a_hook_undo_apart_from_what_insert_mode_types() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        soda.hook("mode", "insert", function()
          soda.buffer():edit({{{3, 6}, {3, 6}, "!"}})
        end)
        "#,
    );
    keys(&mut r, "ggIab<esc>");
    lua(
        &mut r,
        r#"assert(soda.buffer():text() == "abone\ntwo\nthree!", soda.buffer():text())"#,
    );
    keys(&mut r, "u");
    lua(
        &mut r,
        r#"assert(soda.buffer():text() == "one\ntwo\nthree!", soda.buffer():text())"#,
    );
    keys(&mut r, "u");
    lua(
        &mut r,
        r#"assert(soda.buffer():text() == "one\ntwo\nthree", soda.buffer():text())"#,
    );
}
#[test]
fn buffer_handles_outlive_requests_until_the_document_closes() {
    let mut r = runtime();
    lua(&mut r, "kept = soda.buffer()");
    r.command(Command::New);
    lua(
        &mut r,
        r#"
        assert(kept ~= soda.buffer())
        assert(kept:line(1) == "one")
        kept:edit({{{1, 1}, {1, 1}, "x"}})
        assert(kept:line(1) == "xone")
        assert(soda.buffer():text() == "")
        "#,
    );
}
#[test]
fn buffer_indent_asks_the_language() {
    let mut r = runtime();
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        assert(buf:indent(1) == nil or type(buf:indent(1)) == "string")
        assert(not pcall(buf.indent, buf, 99))
        "#,
    );
}
/// Runs the example extension against the real program, where installed.
fn format_buffer(r: &mut Runtime, wait_for: &str) {
    r.command(Command::Named("clang-format".into()));
    for _ in 0..400 {
        r.poll();
        if text(r) == wait_for || r.message().starts_with("clang-format") {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
#[test]
fn clang_format_extension_replaces_only_changed_lines() {
    if std::process::Command::new("clang-format")
        .arg("--version")
        .output()
        .is_err()
    {
        return;
    }
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.input(UserInput::Paste(
        "int  a;\nint b;\nint   c;\nint d;\n".into(),
    ));
    r.command(Command::SetMode(EditMode::Normal));
    lua(&mut r, include_str!("../lua/clang-format.lua"));
    keys(&mut r, "ggjjjl");
    let formatted = "int a;\nint b;\nint c;\nint d;\n";
    format_buffer(&mut r, formatted);
    assert_eq!(text(&r), formatted, "{}", r.message());
    lua(
        &mut r,
        r#"
        local _, head = soda.buffer():selection()
        assert(head[1] == 4 and head[2] == 2, head[1] .. ":" .. head[2])
        "#,
    );
    keys(&mut r, "u");
    assert_eq!(text(&r), "int  a;\nint b;\nint   c;\nint d;\n");
}
#[test]
fn clang_format_extension_formats_only_the_visual_lines() {
    if std::process::Command::new("clang-format")
        .arg("--version")
        .output()
        .is_err()
    {
        return;
    }
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.input(UserInput::Paste("int  a;\nint  b;\nint  c;\n".into()));
    r.command(Command::SetMode(EditMode::Normal));
    lua(&mut r, include_str!("../lua/clang-format.lua"));
    keys(&mut r, "ggjV");
    let formatted = "int  a;\nint b;\nint  c;\n";
    format_buffer(&mut r, formatted);
    assert_eq!(text(&r), formatted, "{}", r.message());
}
#[test]
fn clang_format_extension_drops_output_when_the_buffer_changed() {
    if std::process::Command::new("clang-format")
        .arg("--version")
        .output()
        .is_err()
    {
        return;
    }
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.input(UserInput::Paste("int  a;\n".into()));
    r.command(Command::SetMode(EditMode::Normal));
    lua(&mut r, include_str!("../lua/clang-format.lua"));
    r.command(Command::Named("clang-format".into()));
    keys(&mut r, "ggix<esc>");
    for _ in 0..400 {
        r.poll();
        if r.message().starts_with("clang-format") {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(text(&r), "xint  a;\n");
    assert!(r.message().contains("dropped"), "{}", r.message());
}
