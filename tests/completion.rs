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
    keys(&mut r, "<f3>Awo");
    listed(&mut r);
    keys(&mut r, "<tab><esc><f4>");
    assert_eq!(text(&r).matches("wonder").count(), 2, "{}", text(&r));
    keys(&mut r, "<f4>");
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
fn edits_of_a_candidate_move_its_snippet() {
    let (_dir, mut r) = bundled("top\n|\n");
    lua(
        &mut r,
        r##"soda.completion.register({ complete = function(context, sink)
            sink:add({ { label = "fori", snippet = "for (${1:i}) {\n\t$0\n}",
                         edits = { { { 1, 1 }, { 1, 1 }, "#a\n#b\n" } } } })
            sink:done()
        end })"##,
    );
    keys(&mut r, "fo");
    listed(&mut r);
    keys(&mut r, "<tab>");
    assert_eq!(text(&r), "#a\n#b\ntop\nfor (i) {\n    \n}\n");
    keys(&mut r, "k");
    assert_eq!(shown(&r), "#a\n#b\ntop\nfor (k|) {\n    \n}\n");
    keys(&mut r, "<esc>uu");
    assert_eq!(text(&r), "top\nfo\n");
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
fn painted(r: &Runtime) -> Vec<String> {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let text = text(r);
    r.app()
        .paints(view.document_id)
        .into_iter()
        .map(|(range, _)| text[range].to_owned())
        .collect()
}
#[test]
fn copies_of_a_place_follow_it_as_it_is_typed() {
    let (_dir, mut r) = bundled("|\n");
    r.command(Command::SetMode(EditMode::Normal));
    r.command(Command::Named(
        "snippet for (${1:i} = 0; $1 < ${2:n}; ++$1) ${1/(.*)/${1:/upcase}/}".into(),
    ));
    assert_eq!(text(&r), "for (i = 0; i < n; ++i) I\n");
    keys(&mut r, "idx");
    assert_eq!(shown(&r), "for (idx| = 0; idx < n; ++idx) IDX\n");
    keys(&mut r, "<bs>");
    assert_eq!(text(&r), "for (id = 0; id < n; ++id) ID\n");
    keys(&mut r, "<tab>k<tab>");
    assert_eq!(shown(&r), "for (id = 0; id < k; ++id) ID|\n");
    // From Normal, the snippet, typing and copies are one step.
    keys(&mut r, "<esc>u");
    assert_eq!(text(&r), "\n");
}
#[test]
fn typing_at_the_edge_of_a_place_stays_in_it() {
    let (_dir, mut r) = bundled("|\n");
    r.command(Command::Named("snippet ${1:a}${2:b}$3".into()));
    keys(&mut r, "<right>x");
    assert_eq!(shown(&r), "ax|b\n");
    keys(&mut r, "<tab>");
    keys(&mut r, "y");
    assert_eq!(shown(&r), "axy|\n");
    keys(&mut r, "<tab>z");
    assert_eq!(shown(&r), "axyz|\n");
}
#[test]
fn places_left_to_fill_and_copies_are_painted_until_the_end() {
    let (_dir, mut r) = bundled("|\n");
    r.command(Command::Named("snippet ${1:a} ${2:b} $1".into()));
    assert_eq!(painted(&r), ["b", "a"]);
    keys(&mut r, "<tab>");
    assert_eq!(painted(&r), ["a", "a"]);
    keys(&mut r, "<tab>");
    assert!(painted(&r).is_empty());
}
#[test]
fn a_place_with_choices_lists_them() {
    let (_dir, mut r) = bundled("|\n");
    r.command(Command::Named("snippet ${1|yes,no,maybe|}; ${2:x}".into()));
    assert_eq!(text(&r), "yes; x\n");
    assert_eq!(listed(&mut r), ["yes", "no", "maybe"]);
    keys(&mut r, "<down><ret>");
    assert_eq!(text(&r), "no; x\n");
    // Typing narrows them; Tab goes on to the next place.
    keys(&mut r, "<s-tab>");
    keys(&mut r, "m");
    assert_eq!(labels(&r), ["maybe"]);
    keys(&mut r, "<tab>");
    keys(&mut r, "y");
    assert_eq!(shown(&r), "m; y|\n");
}
#[test]
fn a_snippet_in_a_place_goes_back_to_the_outer_one() {
    let (_dir, mut r) = bundled("|\n");
    r.command(Command::Named("snippet f(${1:a}, ${2:b})".into()));
    r.command(Command::Named("snippet g(${1:x}, ${2:y})".into()));
    assert_eq!(text(&r), "f(g(x, y), b)\n");
    keys(&mut r, "<tab>z<tab>");
    assert_eq!(shown(&r), "f(g(x, z)|, b)\n");
    keys(&mut r, "<tab>c");
    assert_eq!(shown(&r), "f(g(x, z), c|)\n");
}
#[test]
fn variables_take_the_file_and_the_selection() {
    let (_dir, mut r) = bundled("|body\n");
    r.command(Command::SetMode(EditMode::Normal));
    r.command(Command::Edit(Edit::SetSelection(Selection {
        anchor: 0,
        head: 4,
    })));
    r.command(Command::Named(
        "snippet // $TM_FILENAME_BASE\nif (${1:c}) { $TM_SELECTED_TEXT }".into(),
    ));
    assert_eq!(text(&r), "// a\nif (c) { body }\n");
    // The places are filled in Insert.
    keys(&mut r, "k");
    assert_eq!(text(&r), "// a\nif (k) { body }\n");
}
#[test]
fn a_macro_replays_a_snippet_with_what_filled_it() {
    let (_dir, mut r) = bundled("|\n");
    snippet_source(&mut r, "f(${1:a}, $1) $0;");
    keys(&mut r, "<esc><f3>i");
    keys(&mut r, "fo");
    listed(&mut r);
    keys(&mut r, "<tab>k<tab><esc><f4>");
    assert_eq!(text(&r), "f(k, k) ;\n");
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(
        text(&r).len(),
    ))));
    keys(&mut r, "<f4>");
    assert_eq!(text(&r), "f(k, k) ;\nf(k, k) ;");
}
#[test]
fn snippets_load_from_files_in_the_vscode_format() {
    let (dir, mut r) = bundled("|\n");
    let pack = dir.path().join("pack");
    std::fs::create_dir_all(pack.join("snippets")).unwrap();
    std::fs::write(
        pack.join("package.json"),
        r#"{ "contributes": { "snippets": [
             { "language": ["plaintext", "rust"], "path": "./snippets/text.json" } ] } }"#,
    )
    .unwrap();
    std::fs::write(
        pack.join("snippets/text.json"),
        r#"{
          // Comments and trailing commas, as VSCode allows.
          "Fori": { "prefix": ["fori", "loop"], "body": ["for ${1:i} {", "\t$0", "}"],
                    "description": "A loop", },
        }"#,
    )
    .unwrap();
    std::fs::write(
        dir.path().join("one.json"),
        r#"{ "x": { "prefix": "xyz", "body": "x($1)", "scope": "plaintext,c" } }"#,
    )
    .unwrap();
    let path = pack.to_string_lossy().into_owned();
    let one = dir.path().join("one.json").to_string_lossy().into_owned();
    lua(
        &mut r,
        &format!(
            r#"local s = require("snippets")
               assert(s.load("{path}") == 4, "directory")
               assert(s.load("{one}") == 2, "file")"#
        ),
    );
    assert_eq!(r.message(), "");
    keys(&mut r, "lo");
    assert_eq!(listed(&mut r), ["loop"]);
    keys(&mut r, "<tab>k");
    assert_eq!(text(&r), "for k {\n    \n}\n");
    keys(&mut r, "<esc>o");
    r.command(Command::SetMode(EditMode::Insert));
    keys(&mut r, "xy");
    assert_eq!(listed(&mut r), ["xyz"]);
}
