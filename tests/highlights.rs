use soda::{
    application::Face,
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn line(r: &mut Runtime, command: &str) {
    r.command(Command::Named(command.into()));
}
fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn shown(r: &Runtime) -> Vec<(String, Face)> {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app()
        .highlights(view.document_id)
        .map(|h| (h.pattern.as_str().to_owned(), h.face))
        .collect()
}

#[test]
fn patterns_highlight_globally_or_in_one_document() {
    let mut r = runtime("foo bar_baz 中文 x");
    r.source_lua(
        "init.lua",
        r#"
        assert(soda.command([[highlight todo \b(TODO|FIXME)\b]]))
        local ok, message = soda.command("highlight teal x")
        assert(not ok and message:find("unknown face teal"), message)
        "#,
    )
    .unwrap();
    assert_eq!(shown(&r), [("\\b(TODO|FIXME)\\b".into(), Face::Todo)]);
    // Marks of the word at the caret take the next colour each.
    line(
        &mut r,
        "define-command mark-here highlight-local mark \\b%val{word}\\b",
    );
    line(&mut r, "mark-here");
    keys(&mut r, "<a-f><c-f>");
    line(&mut r, "mark-here");
    keys(&mut r, "<a-f><c-f>");
    line(&mut r, "mark-here");
    assert_eq!(
        shown(&r)[1..],
        [
            ("\\bfoo\\b".into(), Face::Mark(0)),
            ("\\bbar_baz\\b".into(), Face::Mark(1)),
            ("\\b中文\\b".into(), Face::Mark(2)),
        ]
    );
    // Another document sees only the global highlight.
    r.command(Command::New);
    assert_eq!(shown(&r).len(), 1);
    line(&mut r, "mark-here");
    assert_eq!(r.message(), "%val{word}: no word at the caret");
    line(&mut r, "next-view");
    line(&mut r, "unhighlight \\bfoo\\b");
    assert_eq!(shown(&r).len(), 3);
    line(&mut r, "unhighlight");
    assert!(shown(&r).is_empty());
    line(&mut r, "unhighlight");
    assert_eq!(r.message(), "no such highlight");
    line(&mut r, "highlight error (");
    assert!(r.message().contains("unclosed group"), "{}", r.message());
}

#[test]
fn symbols_are_marked_in_turn_and_taken_off_without_touching_the_rest() {
    let mut r = runtime("alpha beta gamma\n");
    r.load_startup_lua();
    line(&mut r, "highlight todo TODO");
    keys(&mut r, "<space>i");
    line(&mut r, "goto 1:7");
    keys(&mut r, "<space>i");
    let marks = |r: &Runtime| {
        let mut words: Vec<_> = shown(r)
            .into_iter()
            .filter(|(_, face)| matches!(face, Face::Mark(_)))
            .collect();
        words.sort_by(|a, b| a.0.cmp(&b.0));
        words
    };
    assert_eq!(
        marks(&r),
        [
            (r"\balpha\b".to_owned(), Face::Mark(0)),
            (r"\bbeta\b".to_owned(), Face::Mark(1)),
        ]
    );
    // The same key takes one off.
    keys(&mut r, "<space>i");
    assert_eq!(marks(&r), [(r"\balpha\b".to_owned(), Face::Mark(0))]);
    keys(&mut r, "<space>I");
    assert!(marks(&r).is_empty());
    assert_eq!(shown(&r).len(), 1, "other highlights stay: {:?}", shown(&r));
}

fn head(r: &Runtime) -> usize {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head
}
fn text(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn indicator(r: &Runtime) -> Vec<String> {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    (0..8)
        .filter_map(|line| r.app().indicator(view.document_id, line))
        .map(str::to_owned)
        .collect()
}

#[test]
fn keys_on_a_mark_jump_between_its_occurrences_and_show_the_place() {
    // Offsets: foo 0, bar 4, foo 8, foobar 12 (not foo), foo 19.
    let mut r = runtime("foo bar foo foobar\nfoo end\n");
    r.load_startup_lua();
    keys(&mut r, "<space>i");
    assert_eq!(indicator(&r), ["[1/3]"]);
    keys(&mut r, "n");
    assert_eq!(head(&r), 8);
    assert_eq!(indicator(&r), ["[2/3]"]);
    keys(&mut r, "n");
    assert_eq!(head(&r), 19);
    keys(&mut r, "n");
    assert_eq!(head(&r), 0, "it wraps");
    keys(&mut r, "p");
    assert_eq!(head(&r), 19, "both ways");
    assert_eq!(indicator(&r), ["[3/3]"]);
    keys(&mut r, "<lt>");
    assert_eq!(head(&r), 0);
    keys(&mut r, "<gt>");
    assert_eq!(head(&r), 19);
    // The caret keeps its place in the symbol, and e goes back.
    keys(&mut r, "<lt>l");
    assert_eq!(head(&r), 1);
    keys(&mut r, "n");
    assert_eq!(head(&r), 9);
    keys(&mut r, "e");
    assert_eq!(head(&r), 1);
    assert!(indicator(&r).is_empty(), "the next key clears it");

    // i takes the mark off, and n is Vim's again.
    keys(&mut r, "i");
    assert!(shown(&r).is_empty());
    keys(&mut r, "i");
    assert_ne!(
        r.edit_mode(),
        EditMode::Normal,
        "off a mark, i is Insert again"
    );
}

#[test]
fn keys_mean_what_they_always_do_off_a_mark_and_in_a_count() {
    let mut r = runtime("foo bar foo\n");
    r.load_startup_lua();
    keys(&mut r, "<space>i");
    // w on the mark copies; h shows the keys and any key closes them.
    keys(&mut r, "h");
    assert!(r.popup().unwrap().contains("rename"));
    keys(&mut r, "w");
    assert!(r.popup().is_none());
    assert_eq!(r.message(), "Copied foo");
    // Off the mark, l and w move. From bar, d is delete again.
    keys(&mut r, "l");
    keys(&mut r, "l");
    keys(&mut r, "l");
    keys(&mut r, "l");
    assert_eq!(head(&r), 4);
    keys(&mut r, "wd");
    assert_eq!(text(&r), "foo  foo\n");
    // Part way through a count, n is the search and does not jump.
    keys(&mut r, "<a-lt>");
    keys(&mut r, "2n");
    assert_eq!(head(&r), 0);
    // The space after a symbol is not on it.
    keys(&mut r, "lll");
    assert_eq!(head(&r), 3);
    keys(&mut r, "i");
    assert_eq!(r.edit_mode(), EditMode::Insert);
}

#[test]
fn an_option_keeps_the_keys_of_normal_on_a_mark() {
    let mut r = runtime("foo bar foo\n");
    r.load_startup_lua();
    keys(&mut r, "<space>i");
    line(&mut r, "set mark-keys false");
    // On the mark, i is Insert, as with symbol-overlay-inhibit-map.
    keys(&mut r, "i");
    assert_eq!(r.edit_mode(), EditMode::Insert);
    assert!(!shown(&r).is_empty(), "the mark stays");
    keys(&mut r, "<esc>");
    line(&mut r, "set mark-keys true");
    keys(&mut r, "<a-lt>i");
    assert!(shown(&r).is_empty(), "i takes the mark off again");
}

#[test]
fn renaming_changes_every_occurrence_in_one_step_and_keeps_the_colour() {
    let mut r = runtime("foo bar foobar foo\n");
    r.load_startup_lua();
    keys(&mut r, "<space>i");
    keys(&mut r, "r");
    match r.layer() {
        Some(soda::interaction::Layer::CommandLine(line)) => {
            assert_eq!(line.input().text(), "symbol-rename foo")
        }
        _ => panic!("no prompt"),
    }
    keys(&mut r, "<esc>");
    line(&mut r, "symbol-rename baz");
    assert_eq!(text(&r), "baz bar foobar baz\n");
    assert_eq!(shown(&r), [(r"\bbaz\b".to_owned(), Face::Mark(0))]);
    keys(&mut r, "n");
    assert_eq!(head(&r), 15, "the mark goes on working under its new name");
    keys(&mut r, "<esc>u");
    assert_eq!(text(&r), "foo bar foobar foo\n", "one undo");
}

#[test]
fn switching_goes_to_the_nearest_other_marked_symbol() {
    let mut r = runtime("one two one three two\n");
    r.load_startup_lua();
    keys(&mut r, "<space>i");
    line(&mut r, "goto 1:5");
    keys(&mut r, "<space>i");
    assert_eq!(head(&r), 4);
    keys(&mut r, "<a-n>");
    assert_eq!(head(&r), 8);
    keys(&mut r, "<a-n>");
    assert_eq!(head(&r), 18);
    keys(&mut r, "<a-n>");
    assert_eq!(r.message(), "No more forward symbols");
    keys(&mut r, "<a-p>");
    assert_eq!(head(&r), 8);
}

#[test]
fn each_mark_takes_a_colour_nobody_is_using() {
    let mut r = runtime("aa bb cc\n");
    r.load_startup_lua();
    keys(&mut r, "<space>i");
    line(&mut r, "goto 1:4");
    keys(&mut r, "<space>i");
    line(&mut r, "goto 1:1");
    keys(&mut r, "i");
    line(&mut r, "goto 1:7");
    keys(&mut r, "<space>i");
    let colours: Vec<_> = shown(&r).into_iter().map(|(_, face)| face).collect();
    assert_eq!(colours.len(), 2);
    assert!(colours.contains(&Face::Mark(0)) && colours.contains(&Face::Mark(1)));
}

#[test]
fn no_symbol_here_says_so() {
    let mut r = runtime("   \n");
    r.load_startup_lua();
    keys(&mut r, "<space>i");
    assert_eq!(r.message(), "No symbol here");
}

#[test]
fn a_mark_opens_search_and_replace_with_its_symbol() {
    use soda::interaction::Layer;
    let mut r = runtime("foo bar foo\n");
    r.load_startup_lua();
    keys(&mut r, "<space>i");
    keys(&mut r, "s");
    match r.layer() {
        Some(Layer::Search { input, .. }) => assert_eq!(input.text(), "foo"),
        _ => panic!("no search: {}", r.message()),
    }
    keys(&mut r, "<esc>");
    keys(&mut r, "q");
    assert!(
        matches!(r.layer(), Some(Layer::Replace(session)) if session.search().query().text() == "foo"),
        "{}",
        r.message()
    );
    r.input(UserInput::Paste("baz".into()));
    keys(&mut r, "<ret><f4>");
    assert_eq!(text(&r), "baz bar baz\n");
}
