//! Completion through its keys. `|` marks the caret.
use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::time::{Duration, Instant};

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn caret(r: &Runtime) -> usize {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    let session = editor.model().session(view.session_id).unwrap();
    session.selection().head
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn shown(r: &Runtime) -> String {
    let mut text = text(r);
    text.insert(caret(r), '|');
    text
}
fn open(marked: &str) -> (tempfile::TempDir, Runtime) {
    let at = marked.find('|').expect("a caret");
    let source = marked.replacen('|', "", 1);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.txt");
    std::fs::write(&path, &source).unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.start(Some(path));
    let deadline = Instant::now() + Duration::from_secs(5);
    while r.app().active_view().is_none() || text(&r) != source {
        assert!(Instant::now() < deadline);
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(at))));
    (dir, r)
}
fn labels(r: &Runtime) -> Vec<String> {
    r.completion_popup().map_or(vec![], |popup| {
        popup.rows.into_iter().map(|row| row.label).collect()
    })
}
/// Waits for the sources, until a list shows.
fn listed(r: &mut Runtime) -> Vec<String> {
    let deadline = Instant::now() + Duration::from_secs(5);
    while labels(r).is_empty() {
        assert!(Instant::now() < deadline, "no candidates");
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
    labels(r)
}

#[test]
fn typing_lists_words_nearest_first() {
    let (_dir, mut r) = open("wonder far\nwork\n|\nwool\n");
    keys(&mut r, "wo");
    assert_eq!(listed(&mut r), ["wool", "work", "wonder"]);
    keys(&mut r, "n");
    assert_eq!(labels(&r), ["wonder"]);
}
#[test]
fn one_letter_is_not_enough_but_the_key_asks_anyway() {
    let (_dir, mut r) = open("wonder\n|\n");
    keys(&mut r, "w");
    for _ in 0..20 {
        r.poll();
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(labels(&r).is_empty());
    keys(&mut r, "<a-/>");
    assert_eq!(listed(&mut r), ["wonder"]);
}
#[test]
fn the_text_stays_as_typed_until_a_candidate_is_taken() {
    let (_dir, mut r) = open("wonder\n|\n");
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, "<c-n>");
    assert_eq!(text(&r), "wonder\nwo\n");
    keys(&mut r, "<ret>");
    assert_eq!(shown(&r), "wonder\nwonder|\n");
}
#[test]
fn enter_breaks_the_line_until_something_is_chosen() {
    let (_dir, mut r) = open("wonder\n|\n");
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, "<ret>");
    assert_eq!(shown(&r), "wonder\nwo\n|\n");
    assert!(labels(&r).is_empty());
}
#[test]
fn tab_takes_the_first_and_replaces_the_word() {
    let (_dir, mut r) = open("wonder\n|der\n");
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, "<tab>");
    assert_eq!(shown(&r), "wonder\nwonder|\n");
}
#[test]
fn enter_keeps_the_rest_of_the_word() {
    let (_dir, mut r) = open("wonder\n|er\n");
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, "<c-n><ret>");
    assert_eq!(shown(&r), "wonder\nwonder|er\n");
}
#[test]
fn moving_inside_the_word_refilters_and_leaving_it_closes() {
    let (_dir, mut r) = open("wonder walrus\n|\n");
    keys(&mut r, "won");
    assert_eq!(listed(&mut r), ["wonder"]);
    keys(&mut r, "<left><left>");
    assert_eq!(labels(&r), ["walrus", "wonder"]);
    keys(&mut r, "<right>");
    assert_eq!(labels(&r), ["wonder"]);
    keys(&mut r, "<left><left>");
    assert!(!labels(&r).is_empty());
    keys(&mut r, "<left>");
    assert!(labels(&r).is_empty());
}
#[test]
fn a_character_outside_words_closes_and_is_typed() {
    let (_dir, mut r) = open("wonder\n|\n");
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, ";");
    assert_eq!(text(&r), "wonder\nwo;\n");
    assert!(labels(&r).is_empty());
}
#[test]
fn dismissing_lasts_until_the_word_ends() {
    let (_dir, mut r) = open("wonder wool\n|\n");
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, "<c-g>");
    assert!(labels(&r).is_empty());
    assert_eq!(r.edit_mode(), EditMode::Insert);
    keys(&mut r, "n");
    for _ in 0..20 {
        r.poll();
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(labels(&r).is_empty());
    keys(&mut r, " wo");
    listed(&mut r);
}
#[test]
fn esc_closes_and_leaves_insert() {
    let (_dir, mut r) = open("wonder\n|\n");
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, "<esc>");
    assert!(labels(&r).is_empty());
    assert_eq!(r.edit_mode(), EditMode::Normal);
}
#[test]
fn an_option_turns_the_list_off_and_asking_still_works() {
    let (_dir, mut r) = open("wonder\n|\n");
    r.command(Command::Named("set completion false".into()));
    keys(&mut r, "wo");
    for _ in 0..20 {
        r.poll();
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(labels(&r).is_empty());
    keys(&mut r, "<a-/>");
    listed(&mut r);
}
#[test]
fn file_names_replace_more_than_the_word() {
    let (dir, mut r) = open("|\n");
    std::fs::write(dir.path().join("notes.md"), "").unwrap();
    std::fs::create_dir(dir.path().join("nested")).unwrap();
    keys(&mut r, "./");
    assert_eq!(listed(&mut r), ["nested/", "a.txt", "notes.md"]);
    keys(&mut r, "no");
    assert_eq!(labels(&r), ["notes.md"]);
    keys(&mut r, "<tab>");
    assert_eq!(shown(&r), "./notes.md|\n");
}
#[test]
fn undoing_takes_back_the_candidate_then_the_typing() {
    let (_dir, mut r) = open("wonder\n|\n");
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, "<tab><esc>");
    assert_eq!(text(&r), "wonder\nwonder\n");
    keys(&mut r, "u");
    assert_eq!(text(&r), "wonder\nwo\n");
    keys(&mut r, "u");
    assert_eq!(text(&r), "wonder\n\n");
}
#[test]
fn repeating_types_what_was_taken() {
    let (_dir, mut r) = open("wonder\n|\n");
    r.command(Command::SetMode(EditMode::Normal));
    keys(&mut r, "owo");
    listed(&mut r);
    keys(&mut r, "<tab><esc>");
    assert_eq!(text(&r).matches("wonder").count(), 2, "{}", text(&r));
    keys(&mut r, ".");
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline {
        r.poll();
    }
    assert_eq!(text(&r).matches("wonder").count(), 3, "{}", text(&r));
    assert!(labels(&r).is_empty());
}

fn lua(r: &mut Runtime, code: &str) {
    r.source_lua("test", code).unwrap();
}
#[test]
fn lua_sources_are_asked_with_the_words() {
    let (_dir, mut r) = open("wonder\n|\n");
    lua(
        &mut r,
        r#"soda.completion.register({
          complete = function(context, sink)
            sink:add({ { label = "work", detail = context.prefix .. context.line } })
            sink:done()
          end,
        })"#,
    );
    keys(&mut r, "wo");
    let deadline = Instant::now() + Duration::from_secs(5);
    while labels(&r).len() < 2 {
        assert!(Instant::now() < deadline);
        r.poll();
    }
    assert_eq!(labels(&r), ["work", "wonder"]);
    assert_eq!(r.completion_popup().unwrap().rows[0].detail, "wo2");
}
#[test]
fn a_source_can_answer_later() {
    let (_dir, mut r) = open("|\n");
    lua(
        &mut r,
        r#"soda.completion.register({
          complete = function(context, sink)
            soda.spawn({ "echo", "late" }, function(_, out)
              sink:add({ { label = out:match("%S+") } })
              sink:done()
            end)
          end,
        })"#,
    );
    keys(&mut r, "la");
    assert_eq!(listed(&mut r), ["late"]);
}
#[test]
fn a_trigger_character_asks_only_its_sources() {
    let (_dir, mut r) = open("member\n|\n");
    lua(
        &mut r,
        r#"soda.completion.register({
          triggers = { "." },
          complete = function(context, sink)
            sink:add({ { label = "field", detail = context.trigger } })
            sink:done()
          end,
        })"#,
    );
    keys(&mut r, "x.");
    assert_eq!(listed(&mut r), ["field"]);
    assert_eq!(r.completion_popup().unwrap().rows[0].detail, ".");
    keys(&mut r, "<tab>");
    assert_eq!(shown(&r), "member\nx.field|\n");
}
#[test]
fn an_incomplete_source_is_asked_again() {
    let (_dir, mut r) = open("|\n");
    lua(
        &mut r,
        r#"soda.completion.register({
          complete = function(context, sink)
            sink:add({ { label = "aa" .. context.prefix } })
            sink:done({ incomplete = true })
          end,
        })"#,
    );
    keys(&mut r, "aa");
    assert_eq!(listed(&mut r), ["aaaa"]);
    keys(&mut r, "x");
    let deadline = Instant::now() + Duration::from_secs(5);
    while labels(&r) != ["aaaax"] {
        assert!(Instant::now() < deadline, "{:?}", labels(&r));
        r.poll();
    }
}
#[test]
fn a_late_answer_for_an_old_list_is_dropped() {
    let (_dir, mut r) = open("|\n");
    lua(
        &mut r,
        r#"saved = {}
        soda.completion.register({
          complete = function(context, sink)
            table.insert(saved, sink)
          end,
        })"#,
    );
    keys(&mut r, "ab ");
    keys(&mut r, "cd");
    lua(&mut r, r#"saved[1]:add({ { label = "cde" } })"#);
    r.poll();
    assert!(labels(&r).is_empty());
    lua(&mut r, r#"saved[2]:add({ { label = "cde" } })"#);
    r.poll();
    assert_eq!(labels(&r), ["cde"]);
}

fn snippet_source(r: &mut Runtime, body: &str) {
    lua(
        r,
        &format!(r#"require("snippets").add("*", {{ fori = [==[{body}]==] }})"#),
    );
}
fn bundled(marked: &str) -> (tempfile::TempDir, Runtime) {
    let (dir, mut r) = open(marked);
    r.load_startup_lua();
    assert_eq!(r.message(), "");
    (dir, r)
}
#[test]
fn a_snippet_goes_through_its_places_with_tab() {
    let (_dir, mut r) = bundled("|\n");
    snippet_source(&mut r, "for (${1:i}; ${2:n}) $0;");
    keys(&mut r, "fo");
    assert_eq!(listed(&mut r), ["fori"]);
    keys(&mut r, "<tab>");
    assert_eq!(text(&r), "for (i; n) ;\n");
    keys(&mut r, "x");
    assert_eq!(shown(&r), "for (x|; n) ;\n");
    keys(&mut r, "y<tab>");
    keys(&mut r, "k");
    assert_eq!(shown(&r), "for (xy; k|) ;\n");
    keys(&mut r, "<backtab>z<tab><tab>");
    assert_eq!(shown(&r), "for (z; k) |;\n");
    keys(&mut r, "<tab>");
    assert_eq!(text(&r), "for (z; k)  ;\n");
}
#[test]
fn leaving_a_snippet_ends_it() {
    let (_dir, mut r) = bundled("|\nnext\n");
    r.command(Command::Named("snippet a${1:b} ${2:c}".into()));
    keys(&mut r, "<down><tab>");
    // Tab no longer belongs to the snippet: it goes in where the caret is.
    assert_eq!(text(&r).lines().next().unwrap(), "ab c");
    assert_ne!(text(&r).lines().nth(1).unwrap(), "next");
}
#[test]
fn going_to_normal_ends_a_snippet() {
    let (_dir, mut r) = bundled("|\n");
    r.command(Command::Named("snippet ${1:a} ${2:b}".into()));
    keys(&mut r, "<esc>i<tab>");
    assert!(text(&r).contains("    "), "{}", text(&r));
}
#[test]
fn a_snippet_is_one_undo_step_and_takes_the_line_indentation() {
    let (_dir, mut r) = bundled("  |\n");
    r.command(Command::Named("snippet if {\n\t${1:x}\n}".into()));
    assert_eq!(text(&r), "  if {\n      x\n  }\n");
    keys(&mut r, "<esc>u");
    assert_eq!(text(&r), "  \n");
}
#[test]
fn the_list_takes_tab_before_the_snippet() {
    let (_dir, mut r) = bundled("wonder\n|\n");
    r.command(Command::Named("snippet ${1:a} ${2:b}".into()));
    keys(&mut r, "wo");
    listed(&mut r);
    keys(&mut r, "<tab>");
    assert_eq!(shown(&r), "wonder\nwonder| b\n");
    keys(&mut r, "<tab>");
    keys(&mut r, "c");
    assert_eq!(shown(&r), "wonder\nwonder c|\n");
}
