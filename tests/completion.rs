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
