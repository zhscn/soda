//! Replacing over the files of the project, as Emacs's
//! `project-query-replace-regexp`: each file with a match is opened and
//! asked about in turn.
use soda::{
    interaction::{KeyStroke, Layer, UserInput},
    runtime::Runtime,
};
use std::time::{Duration, Instant};

fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn wait(r: &mut Runtime, mut done: impl FnMut(&Runtime) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done(r) {
        assert!(Instant::now() < deadline, "{}", r.message());
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
/// A project of three files, the second without a match, with the first
/// open.
fn project() -> (tempfile::TempDir, Runtime) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    std::fs::create_dir(root.join(".git")).unwrap();
    std::fs::write(root.join("a.txt"), "foo foo\n").unwrap();
    std::fs::write(root.join("b.txt"), "bar\n").unwrap();
    std::fs::write(root.join("c.txt"), "x foo\n").unwrap();
    let mut r = Runtime::new(root.clone()).unwrap();
    r.start(Some(root.join("a.txt")));
    wait(&mut r, |r| r.app().active_view().is_some());
    (dir, r)
}
fn text(r: &Runtime, name: &str) -> String {
    let app = r.app();
    let document = app
        .workspace()
        .documents()
        .find(|d| app.document_name(*d).ends_with(name))
        .unwrap();
    let editor = app.workspace().editor(document).unwrap();
    editor.model().document().snapshot().text().to_owned()
}
fn reviewing(r: &Runtime, name: &str) -> bool {
    matches!(r.layer(), Some(Layer::Search(_)))
        && r.app()
            .active_view()
            .and_then(|view| r.app().view(view))
            .is_some_and(|view| r.app().document_name(view.document_id).ends_with(name))
}

#[test]
fn each_file_with_a_match_is_asked_about_in_turn() {
    let (_dir, mut r) = project();
    keys(&mut r, "C-x p r foo RET baz RET");
    wait(&mut r, |r| reviewing(r, "a.txt"));
    // The first match, then the second left as it is.
    keys(&mut r, "y n");
    // b.txt has none, so c.txt comes next.
    wait(&mut r, |r| reviewing(r, "c.txt"));
    keys(&mut r, "y");
    wait(&mut r, |r| {
        r.layer().is_none() && r.message().starts_with("Replaced")
    });
    assert_eq!(r.message(), "Replaced 2 occurrences in 2 files");
    assert_eq!(text(&r, "a.txt"), "baz foo\n");
    assert_eq!(text(&r, "c.txt"), "x baz\n");
    // Changed, not saved, as query-replace leaves them.
    assert_eq!(
        std::fs::read_to_string(_dir.path().join("a.txt")).unwrap(),
        "foo foo\n"
    );
}
#[test]
fn capital_y_replaces_the_rest_of_every_file_and_q_stops() {
    let (_dir, mut r) = project();
    keys(&mut r, "C-x p r foo RET baz RET");
    wait(&mut r, |r| reviewing(r, "a.txt"));
    keys(&mut r, "n Y");
    wait(&mut r, |r| r.message().starts_with("Replaced"));
    assert_eq!(r.message(), "Replaced 2 occurrences in 2 files");
    assert_eq!(text(&r, "a.txt"), "foo baz\n");
    assert_eq!(text(&r, "c.txt"), "x baz\n");

    let (_dir, mut r) = project();
    keys(&mut r, "C-x p r foo RET baz RET");
    wait(&mut r, |r| reviewing(r, "a.txt"));
    keys(&mut r, "y q");
    wait(&mut r, |r| r.message().starts_with("Replaced"));
    assert_eq!(r.message(), "Replaced 1 occurrence in 1 file");
    assert_eq!(text(&r, "a.txt"), "baz foo\n");
    // c.txt was never reached.
    assert!(
        !r.app()
            .workspace()
            .documents()
            .any(|d| r.app().document_name(d).ends_with("c.txt"))
    );
}
#[test]
fn capital_n_goes_on_to_the_next_file() {
    let (_dir, mut r) = project();
    keys(&mut r, "C-x p r foo RET baz RET");
    wait(&mut r, |r| reviewing(r, "a.txt"));
    keys(&mut r, "N");
    wait(&mut r, |r| reviewing(r, "c.txt"));
    keys(&mut r, "!");
    wait(&mut r, |r| r.message().starts_with("Replaced"));
    assert_eq!(text(&r, "a.txt"), "foo foo\n");
    assert_eq!(text(&r, "c.txt"), "x baz\n");
}
