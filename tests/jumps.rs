//! Jump history: what counts as a jump and where going back lands.
use soda::{
    interaction::{Command, EditMode, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::time::{Duration, Instant};

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn goto(r: &mut Runtime, line: usize) {
    keys(r, &format!("Q{line}<ret>"));
}
fn wait(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done(r) {
        assert!(Instant::now() < deadline, "{}", r.message());
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn name(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let name = r.app().document_name(view.document_id);
    name.rsplit('/').next().unwrap().to_owned()
}
/// The active file and the one-based line of the caret.
fn at(r: &Runtime) -> (String, usize) {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let editor = r.app().workspace().editor(view.document_id).unwrap();
    let head = editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head;
    let line = editor.model().document().snapshot().line_of(head).unwrap();
    (name(r), line + 1)
}
fn here(file: &str, line: usize) -> (String, usize) {
    (file.to_owned(), line)
}
struct Project {
    _dir: tempfile::TempDir,
    r: Runtime,
}
fn project() -> Project {
    let dir = tempfile::tempdir().unwrap();
    let lines: Vec<String> = (1..=30).map(|n| format!("line {n}")).collect();
    std::fs::write(dir.path().join("a.txt"), lines.join("\n") + "\n").unwrap();
    std::fs::write(dir.path().join("b.txt"), "x\nneedle\ny\nneedle\n").unwrap();
    std::fs::write(dir.path().join("c.txt"), "needle\n").unwrap();
    let mut r = Runtime::new(dir.path().to_owned()).unwrap();
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.start(Some(dir.path().join("a.txt")));
    wait(&mut r, |r| r.app().active_view().is_some());
    Project { _dir: dir, r }
}

#[test]
fn back_and_forward_within_a_file() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    goto(&mut r, 20);
    assert_eq!(at(&r), here("a.txt", 20));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 5));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 1));
    keys(&mut r, "<c-o>");
    assert_eq!(r.message(), "At the oldest jump");
    assert_eq!(at(&r), here("a.txt", 1));
    keys(&mut r, "<c-i>");
    assert_eq!(at(&r), here("a.txt", 5));
    keys(&mut r, "<c-i>");
    assert_eq!(at(&r), here("a.txt", 20));
    keys(&mut r, "<c-i>");
    assert_eq!(r.message(), "At the newest jump");
}
#[test]
fn tab_goes_forward_where_terminals_cannot_tell_it_from_ctrl_i() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 1));
    keys(&mut r, "<tab>");
    assert_eq!(at(&r), here("a.txt", 5));
}
#[test]
fn small_moves_are_not_jumps() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 10);
    keys(&mut r, "jjjlw");
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 1));
    keys(&mut r, "<c-i>");
    assert_eq!(at(&r), here("a.txt", 13), "forward returns where back left");
}
#[test]
fn jumping_after_going_back_drops_what_lay_ahead() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 10);
    goto(&mut r, 20);
    keys(&mut r, "<c-o>");
    goto(&mut r, 25);
    keys(&mut r, "<c-i>");
    assert_eq!(r.message(), "At the newest jump");
    assert_eq!(at(&r), here("a.txt", 25));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 10));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 1));
}
#[test]
fn a_search_counts_once_from_where_it_started() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    keys(&mut r, "<c-s>line 20<ret>");
    assert_eq!(at(&r), here("a.txt", 20));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 5));
    // A cancelled search went nowhere.
    keys(&mut r, "<c-s>line 25<esc>");
    assert_eq!(at(&r), here("a.txt", 5));
    keys(&mut r, "<c-i>");
    assert_eq!(at(&r), here("a.txt", 20));
}
#[test]
fn opening_results_returns_to_where_the_search_started() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    r.command(Command::Grep("needle".into()));
    wait(&mut r, |r| r.message().starts_with("3 matches"));
    assert_eq!(name(&r), "*grep*");
    keys(&mut r, "<a-g>n");
    wait(&mut r, |r| name(r) == "b.txt");
    keys(&mut r, "<a-g>n");
    wait(&mut r, |r| at(r) == here("b.txt", 4));
    keys(&mut r, "<a-g>n");
    wait(&mut r, |r| name(r) == "c.txt");
    // One step leaves the results, whatever was walked through.
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 5));
    keys(&mut r, "<c-i>");
    assert_eq!(at(&r), here("c.txt", 1));
}
#[test]
fn branches_of_results_unwind_one_at_a_time() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    r.command(Command::Grep("needle".into()));
    wait(&mut r, |r| r.message().starts_with("3 matches"));
    keys(&mut r, "<a-g>n");
    wait(&mut r, |r| name(r) == "b.txt");
    assert_eq!(at(&r), here("b.txt", 2));
    // A second search, from the first one's result.
    r.command(Command::Grep("line 7$".into()));
    wait(&mut r, |r| r.message().starts_with("1 matches"));
    keys(&mut r, "<a-g>n");
    wait(&mut r, |r| name(r) == "a.txt");
    assert_eq!(at(&r), here("a.txt", 7));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("b.txt", 2));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 5));
}
#[test]
fn enter_only_counts_on_a_location() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    keys(&mut r, "<ret><ret>");
    assert_eq!(at(&r), here("a.txt", 7));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 1));
}
#[test]
fn places_follow_edits() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    goto(&mut r, 20);
    keys(&mut r, "<a-lt>Inew<esc>");
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 21));
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 6));
}
#[test]
fn closed_documents_leave_the_list() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    r.command(Command::OpenPath(_dir.path().join("b.txt")));
    wait(&mut r, |r| name(r) == "b.txt");
    r.command(Command::OpenPath(_dir.path().join("c.txt")));
    wait(&mut r, |r| name(r) == "c.txt");
    r.command(Command::Named("buffer ".to_owned() + &buffer(&r, "b.txt")));
    assert_eq!(name(&r), "b.txt");
    r.command(Command::Named("close".into()));
    assert_ne!(name(&r), "b.txt", "{}", r.message());
    for _ in 0..4 {
        keys(&mut r, "<c-o>");
        assert_ne!(name(&r), "b.txt");
    }
}
fn buffer(r: &Runtime, file: &str) -> String {
    let workspace = r.app().workspace();
    workspace
        .documents()
        .map(|document| r.app().document_name(document))
        .find(|name| name.ends_with(file))
        .unwrap()
}
#[test]
fn going_back_focuses_the_window_that_holds_the_place() {
    let Project { mut r, _dir } = project();
    goto(&mut r, 5);
    let first = r.app().active_view().unwrap();
    keys(&mut r, "<c-x>2");
    r.command(Command::OpenPath(_dir.path().join("b.txt")));
    wait(&mut r, |r| name(r) == "b.txt");
    assert_eq!(r.app().windows().len(), 2);
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 5));
    assert_eq!(r.app().windows().len(), 2);
    assert_eq!(r.app().active_view(), Some(first));
}
#[test]
fn jump_to_counts_and_typing_does_not() {
    let Project { mut r, _dir } = project();
    r.set_page_rows(25);
    goto(&mut r, 5);
    keys(&mut r, "<space>j20");
    assert_eq!(r.edit_mode(), EditMode::Normal);
    assert_eq!(at(&r).1, 20, "{}", r.message());
    keys(&mut r, "<c-o>");
    assert_eq!(at(&r), here("a.txt", 5));
}
