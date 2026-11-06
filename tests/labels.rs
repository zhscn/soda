use soda::{
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::path::PathBuf;

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
    r.set_page_rows(10);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    r.command(Command::SetMode(EditMode::Normal));
    r
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
fn labels(r: &Runtime) -> Vec<(String, Option<usize>)> {
    match r.layer() {
        Some(Layer::Labels(session)) => session
            .targets()
            .map(|(target, _)| (target.label.clone(), target.offset))
            .collect(),
        _ => vec![],
    }
}

#[test]
fn two_characters_then_a_label_move_the_caret() {
    let mut r = runtime("foo bar\nbaz Foo\nfoo");
    keys(&mut r, "SPC jfo");
    // Lowercase finds any case.
    assert_eq!(
        labels(&r),
        [
            ("a".into(), Some(0)),
            ("s".into(), Some(12)),
            ("d".into(), Some(16))
        ]
    );
    keys(&mut r, "s");
    assert!(r.layer().is_none());
    assert_eq!(caret(&r), 12);
    // Capitals match exactly; a single place is taken at once.
    keys(&mut r, "SPC jFo");
    assert_eq!(caret(&r), 12);
    keys(&mut r, "SPC jz SPC");
    assert_eq!(caret(&r), 10);
    keys(&mut r, "SPC jqq");
    assert_eq!(r.message(), "No qq on screen");
    keys(&mut r, "SPC jfo ESC");
    assert!(r.layer().is_none());
    assert_eq!(caret(&r), 10);
}
#[test]
fn windows_are_picked_by_label() {
    let mut r = runtime("x");
    let first = r.app().active_view().unwrap();
    keys(&mut r, "M-x vsplit RET");
    let second = r.app().windows().views()[1];
    // With two windows, the other one is taken at once.
    keys(&mut r, "SPC w");
    assert_eq!(r.app().active_view(), Some(second));
    keys(&mut r, "SPC w");
    assert_eq!(r.app().active_view(), Some(first));
    keys(&mut r, "M-x split RET");
    let third = r.app().windows().views()[1];
    keys(&mut r, "SPC w");
    let shown = labels(&r);
    assert_eq!(shown.len(), 3);
    let label = r
        .app()
        .windows()
        .views()
        .iter()
        .position(|v| *v == second)
        .unwrap();
    keys(&mut r, &shown[label].0);
    assert_eq!(r.app().active_view(), Some(second));
    assert_ne!(second, third);
}
fn flash(r: &Runtime) -> Vec<(char, usize)> {
    match r.layer() {
        Some(Layer::Labels(session)) => session
            .flash_search()
            .unwrap()
            .matches()
            .iter()
            .filter_map(|m| Some((m.label?, m.range.start)))
            .collect(),
        _ => vec![],
    }
}
#[test]
fn flash_labels_matches_nearest_first_and_never_with_a_following_character() {
    let mut r = runtime("foo bar\nbaz fob\nfox");
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(9))));
    keys(&mut r, "M-x flash RET");
    assert!(flash(&r).is_empty());
    // Nearest the caret first, a line counting as the screen's width;
    // `o` follows `f` everywhere, so no label is o.
    keys(&mut r, "f");
    assert_eq!(flash(&r), [('a', 12), ('s', 16), ('d', 0)]);
    // Each match keeps its label as the query grows; `b` and `x` follow
    // now, and `o` no longer does.
    keys(&mut r, "o");
    assert_eq!(flash(&r), [('a', 12), ('s', 16), ('d', 0)]);
    keys(&mut r, "DEL o");
    assert_eq!(flash(&r), [('a', 12), ('s', 16), ('d', 0)]);
    keys(&mut r, "d");
    assert!(r.layer().is_none());
    assert_eq!(caret(&r), 0);
}
#[test]
fn flash_goes_on_with_the_query_rather_than_take_what_follows_a_match() {
    let mut r = runtime("ab ad\nab");
    keys(&mut r, "M-x flash RET a");
    // `b` and `d` follow `a`: typed, they narrow the search.
    let labels: Vec<char> = flash(&r).iter().map(|(label, _)| *label).collect();
    assert!(!labels.contains(&'b') && !labels.contains(&'d'));
    keys(&mut r, "d");
    assert_eq!(flash(&r).len(), 1);
    // Enter goes to the match after the caret.
    keys(&mut r, "RET");
    assert!(r.layer().is_none());
    assert_eq!(caret(&r), 3);
}
#[test]
fn flash_ends_when_nothing_matches_and_esc_stays() {
    let mut r = runtime("foo bar");
    keys(&mut r, "M-x flash RET q");
    assert!(r.layer().is_none());
    assert_eq!(caret(&r), 0);
    keys(&mut r, "M-x flash RET b ESC");
    assert!(r.layer().is_none());
    assert_eq!(caret(&r), 0);
    // Capitals match case.
    let mut r = runtime("Bar bar");
    keys(&mut r, "M-x flash RET B");
    assert_eq!(flash(&r).len(), 1);
}
fn selection(r: &Runtime) -> Selection {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    editor.model().session(view.session_id).unwrap().selection()
}
#[test]
fn flash_structure_selects_the_groups_around_the_caret() {
    let text = "f(a, [b, c], {d})";
    let mut r = runtime(text);
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(7))));
    keys(&mut r, "M-x flash-structure RET");
    // Innermost first, selected at once; each labelled at both brackets.
    assert_eq!(labels(&r), [("a".into(), Some(5)), ("b".into(), Some(1))]);
    let range = |r: &Runtime| selection(r).range();
    assert_eq!(range(&r), 5..11);
    keys(&mut r, ";");
    assert_eq!(range(&r), 1..17);
    keys(&mut r, ";");
    assert_eq!(range(&r), 1..17);
    keys(&mut r, ",");
    assert_eq!(range(&r), 5..11);
    // Esc goes back to the caret.
    keys(&mut r, "ESC");
    assert!(r.layer().is_none());
    assert_eq!(selection(&r), Selection::caret(7));
    // A label selects its group as a block, which `o` goes on from.
    keys(&mut r, "M-x flash-structure RET b");
    assert!(r.layer().is_none());
    assert_eq!(range(&r), 1..17);
    // On an opening bracket, its own group comes first.
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(13))));
    keys(&mut r, "M-x flash-structure RET RET");
    assert_eq!(range(&r), 13..16);
    // Outside any group there is nothing to label.
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(0))));
    keys(&mut r, "M-x flash-structure RET");
    assert!(r.layer().is_none());
    assert_eq!(r.message(), "No group here");
}
