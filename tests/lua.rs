//! Lua extensions: the soda table, hooks and commands as Lua functions,
//! background processes, errors and Lua started from Lua.
use soda::{
    application::Side,
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
    keys(&mut r, "U");
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
    // Normal mode holds a selection as it is given.
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        buf:set_selection({2, 2}, {2, 4})
        local anchor, head = buf:selection()
        assert(anchor[1] == 2 and anchor[2] == 2 and head[2] == 4)
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
fn buffer_selection_reads_what_is_selected() {
    let mut r = runtime();
    keys(&mut r, "<a-lt>LL");
    lua(
        &mut r,
        r#"
        local buf = soda.buffer()
        local anchor, head = buf:selection()
        assert(buf:text(anchor, head) == soda.val("selection"))
        assert(buf:text(anchor, head) == "on")
        "#,
    );
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
    keys(&mut r, "<a-lt>iab<esc>");
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
    keys(&mut r, "<a-lt>jjjl");
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
fn clang_format_extension_formats_only_the_selected_lines() {
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
    keys(&mut r, "<a-lt>je");
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
    keys(&mut r, "<a-lt>ix<esc>");
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
/// A runtime with these lines and the example extension loaded.
fn extension(lines: &str, source: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.input(UserInput::Paste(lines.into()));
    r.command(Command::SetMode(EditMode::Normal));
    lua(&mut r, source);
    r
}
#[test]
fn comment_extension_says_when_a_buffer_has_no_marker() {
    let comment = include_str!("../lua/comment.lua");
    let mut r = extension("one\n", comment);
    r.command(Command::Named("comment".into()));
    assert_eq!(text(&r), "one\n");
    assert!(r.message().contains("no line comments"), "{}", r.message());
}
#[test]
fn surround_extension_wraps_the_selection_from_a_key() {
    let surround = include_str!("../lua/surround.lua");
    let mut r = extension("one two\n", surround);
    keys(&mut r, "<a-lt>llll,w<c-c>(");
    assert_eq!(text(&r), "one (two)\n", "{}", r.message());
    assert_eq!(r.edit_mode(), EditMode::Normal);
    keys(&mut r, "u");
    assert_eq!(text(&r), "one two\n");
    keys(&mut r, "<a-lt>w<c-c>\"");
    assert_eq!(text(&r), "\"one\" two\n", "{}", r.message());
}
#[test]
fn surround_extension_takes_any_pair_and_needs_a_selection() {
    let surround = include_str!("../lua/surround.lua");
    let mut r = extension("word\n", surround);
    r.command(Command::Named("surround (".into()));
    assert!(r.message().contains("select text"), "{}", r.message());
    keys(&mut r, "<a-lt>w");
    r.command(Command::Named("surround <b> </b>".into()));
    assert_eq!(text(&r), "<b>word</b>\n", "{}", r.message());
}
/// A runtime on a file of `name` holding `lines`, with comments loaded.
fn commented(dir: &tempfile::TempDir, name: &str, lines: &str) -> Runtime {
    let path = dir.path().join(name);
    std::fs::write(&path, lines).unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(Some(path));
    for _ in 0..400 {
        r.poll();
        if r.app().active_view().is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(text(&r), lines);
    lua(&mut r, include_str!("../lua/comment.lua"));
    r
}
#[test]
fn comment_extension_toggles_the_line_of_the_caret() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = commented(&dir, "a.py", "x = 1\n    y = 2\n");
    lua(&mut r, r#"soda.command("map normal gc comment")"#);
    keys(&mut r, "ggjgc");
    assert_eq!(text(&r), "x = 1\n    # y = 2\n");
    r.command(Command::Named("comment".into()));
    assert_eq!(text(&r), "x = 1\n    y = 2\n");
}
#[test]
fn comment_extension_aligns_markers_and_skips_blank_lines() {
    let dir = tempfile::tempdir().unwrap();
    let source = "int f() {\n    int a;\n\n        int b;\n}\n";
    let mut r = commented(&dir, "a.cpp", source);
    keys(&mut r, "<a-lt>jeee<a-;>");
    let on = "int f() {\n    // int a;\n\n    //     int b;\n}\n";
    assert_eq!(text(&r), on, "{}", r.message());
    keys(&mut r, "u");
    assert_eq!(text(&r), source, "one undo step");
    keys(&mut r, "<a-lt>jeee<a-;>");
    keys(&mut r, "<a-lt>jeee<a-;>");
    assert_eq!(text(&r), source, "{}", r.message());
}
#[test]
fn comment_extension_leaves_out_the_line_a_selection_ends_before() {
    let dir = tempfile::tempdir().unwrap();
    let mut r = commented(&dir, "a.lua", "a()\nb()\nc()\n");
    keys(&mut r, "<a-lt>jJ<a-;>");
    assert_eq!(text(&r), "a()\n-- b()\nc()\n", "{}", r.message());
}
fn active_name(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app().document_name(view.document_id)
}
fn wait(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    for _ in 0..1000 {
        r.poll();
        if done(r) {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!("timed out: {}", r.message());
}
fn caret(r: &Runtime) -> usize {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head
}
#[test]
fn lua_results_step_with_the_built_in_keys() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "one\ntwo\nthree\n").unwrap();
    std::fs::write(dir.path().join("b.txt"), "four\nfive\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    lua(
        &mut r,
        r#"
        soda.results("lint", {
          "a.txt:2:2: first",
          "a heading",
          "b.txt:2: second",
        })
        "#,
    );
    assert_eq!(active_name(&r), "*lint*");
    let list = r.app().active_view().unwrap();
    assert_eq!(r.app().windows().side(list), Some(Side::Bottom));
    keys(&mut r, "<a-g>n");
    wait(&mut r, |r| active_name(r).ends_with("a.txt"));
    assert_eq!(caret(&r), 5);
    keys(&mut r, "<a-g>n");
    wait(&mut r, |r| active_name(r).ends_with("b.txt"));
    assert_eq!(caret(&r), 5);
    keys(&mut r, "<a-g>n");
    assert_eq!(r.message(), "At the last result");
}
#[test]
fn lua_results_follow_the_shape_of_the_largest_window() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "one\n").unwrap();
    let side = |width, height, setup: &str| {
        let mut r = Runtime::new(dir.path().to_owned()).unwrap();
        r.start(None);
        r.set_editing_area(width, height);
        if !setup.is_empty() {
            r.command(Command::Named(setup.into()));
        }
        lua(&mut r, r#"soda.results("lint", { "a.txt:1:1: first" })"#);
        let list = r.app().active_view().unwrap();
        r.app().windows().side(list)
    };
    // Wide and flat, as 256 by 29.
    assert_eq!(side(256, 26, ""), Some(Side::Right));
    // Tall enough that a list below costs little.
    assert_eq!(side(200, 120, ""), Some(Side::Bottom));
    assert_eq!(side(100, 26, ""), Some(Side::Bottom));
    // Two columns already: halving one would leave neither usable.
    assert_eq!(side(256, 26, "vsplit"), Some(Side::Bottom));
}
#[test]
fn lua_results_use_the_side_window_already_open() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "one\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    r.set_editing_area(256, 26);
    lua(&mut r, r#"soda.results("lint", { "a.txt:1:1: first" })"#);
    r.set_editing_area(100, 26);
    lua(&mut r, r#"soda.results("tidy", { "a.txt:1:1: first" })"#);
    assert_eq!(active_name(&r), "*tidy*");
    let list = r.app().active_view().unwrap();
    assert_eq!(r.app().windows().side(list), Some(Side::Right));
}
#[test]
fn lua_results_keep_a_configured_placement() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "one\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    lua(
        &mut r,
        r#"
        soda.command("display lint right 30")
        soda.results("lint", { "a.txt:1:1: first" })
        "#,
    );
    let list = r.app().active_view().unwrap();
    assert_eq!(r.app().windows().side(list), Some(Side::Right));
}
#[test]
fn lua_results_without_a_location_leave_the_list_alone() {
    let mut r = runtime();
    lua(&mut r, r#"soda.results("lint", {"nothing here"})"#);
    assert_eq!(r.message(), "lint: no results");
    assert!(r.app().workspace().scratch("*lint*").is_none());
    let error = r
        .source_lua("test", r#"soda.results("*x*", {})"#)
        .unwrap_err();
    assert!(error.contains("cannot name results"), "{error}");
}
#[test]
fn lua_opens_a_position_and_reports_a_bad_one() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.txt"), "one\ntwo\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    lua(&mut r, r#"soda.open("a.txt", 2, 3)"#);
    wait(&mut r, |r| active_name(r).ends_with("a.txt"));
    assert_eq!(caret(&r), 6);
    let error = r
        .source_lua("test", r#"soda.open("a.txt", 0)"#)
        .unwrap_err();
    assert!(error.contains("outside"), "{error}");
}
#[test]
fn git_changes_extension_lists_each_hunk() {
    let dir = tempfile::tempdir().unwrap();
    let git = |args: &[&str]| {
        let ok = std::process::Command::new("git")
            .args(args)
            .current_dir(dir.path())
            .output()
            .is_ok_and(|output| output.status.success());
        assert!(ok, "git {args:?}");
    };
    if std::process::Command::new("git")
        .arg("--version")
        .output()
        .is_err()
    {
        return;
    }
    git(&["init", "-q"]);
    let path = dir.path().join("a.txt");
    std::fs::write(&path, "a\nb\nc\nd\ne\n").unwrap();
    git(&["add", "."]);
    // A changed line, one that reads like a file header, and a removal.
    std::fs::write(&path, "a\nB\n++ b/fake\nc\ne\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(None);
    lua(&mut r, include_str!("../lua/git-changes.lua"));
    r.command(Command::Named("git-changes".into()));
    wait(&mut r, |r| {
        r.app().workspace().scratch("*changes*").is_some()
    });
    assert_eq!(active_name(&r), "*changes*");
    assert_eq!(
        text(&r),
        "a.txt:2: B\na.txt:4: (lines removed)\n",
        "{}",
        r.message()
    );
    keys(&mut r, "<a-g>n");
    wait(&mut r, |r| active_name(r).ends_with("a.txt"));
    assert_eq!(caret(&r), 2);
}

mod bundled {
    use super::*;

    #[test]
    fn startup_modules_add_their_commands_and_keys() {
        let mut r = runtime();
        r.load_startup_lua();
        assert_eq!(r.message(), "");
        for name in ["comment", "surround", "clang-format", "git-changes"] {
            lua(&mut r, &format!("assert(package.loaded[{name:?}])"));
        }
        lua(
            &mut r,
            r#"assert(not package.loaded["git-flags"])
            assert(require("git-flags"))"#,
        );
    }
    #[test]
    fn a_file_of_the_same_name_replaces_a_module() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("comment.lua"), "return 'mine'").unwrap();
        let mut r = runtime();
        r.add_lua_modules(directory.path());
        r.load_startup_lua();
        lua(&mut r, "assert(require('comment') == 'mine')");
    }
    #[test]
    fn modules_do_not_load_from_the_working_directory() {
        let mut r = runtime();
        lua(
            &mut r,
            r#"assert(not package.path:find("./?", 1, true))
            assert(not package.cpath:find("./?", 1, true))"#,
        );
    }
}
