//! `restart` carries the session into a new process: here, into a new
//! Runtime, which is what the new process makes first.
use soda::{
    application::Event,
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, KeyStroke, UserInput},
    runtime::Runtime,
};
use std::{
    path::Path,
    time::{Duration, Instant},
};

fn wait(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done(r) {
        assert!(Instant::now() < deadline, "{}", r.message());
        r.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn open(r: &mut Runtime, path: &Path) {
    r.command(Command::Named(format!("edit {}", path.display())));
    let name = path.display().to_string();
    wait(r, |r| active(r) == name);
}
fn active(r: &Runtime) -> String {
    r.app()
        .active_view()
        .and_then(|view| r.app().view(view))
        .map_or_else(String::new, |view| r.app().document_name(view.document_id))
}
/// What shows: for each window, its document, text, whether unsaved and
/// selection; then the focused document. Untitled documents are numbered
/// anew in each process, so their numbers are left out.
fn shown(r: &Runtime) -> (Vec<(String, String, bool, Selection)>, String) {
    let app = r.app();
    let windows = app
        .windows()
        .views()
        .into_iter()
        .map(|view| {
            let view = app.view(view).unwrap();
            let editor = app.workspace().editor(view.document_id).unwrap();
            (
                unnumbered(app.document_name(view.document_id)),
                editor.model().document().snapshot().text().to_owned(),
                app.workspace().is_dirty(view.document_id),
                editor.model().session(view.session_id).unwrap().selection(),
            )
        })
        .collect();
    (windows, unnumbered(active(r)))
}
fn unnumbered(name: String) -> String {
    if name.starts_with("[untitled ") {
        "[untitled]".into()
    } else {
        name
    }
}

#[test]
fn a_session_comes_back_with_its_windows_and_unsaved_text_but_no_undo() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    std::fs::write(root.join("a.txt"), "alpha\nbeta\n").unwrap();
    std::fs::write(root.join("b.txt"), "one\ntwo\n").unwrap();
    let mut r = Runtime::new(root.clone()).unwrap();
    open(&mut r, &root.join("a.txt"));
    r.command(Command::Edit(Edit::SetSelection(Selection {
        anchor: 6,
        head: 10,
    })));
    keys(&mut r, "C-x 3 C-x o");
    open(&mut r, &root.join("b.txt"));
    r.command(Command::Edit(Edit::InsertText("X".into())));
    // An untitled draft, hidden behind b.txt.
    r.command(Command::New);
    r.command(Command::Edit(Edit::InsertText("draft".into())));
    r.command(Command::Named(format!(
        "buffer {}",
        root.join("b.txt").display()
    )));
    r.dispatch(Event::SetClipboard("kept".into()));
    r.dispatch(Event::StartedRoot {
        language: "cpp".into(),
        root: root.clone(),
        started: true,
    });
    let before = shown(&r);
    assert_eq!(before.0.len(), 2);
    assert!(before.0[1].2, "b.txt is unsaved");
    let session = r.session();

    let mut again = Runtime::new(root.clone()).unwrap();
    again.resume(&session);
    assert_eq!(shown(&again), before);
    let app = again.app();
    // The hidden draft came too, unsaved.
    let draft = app
        .workspace()
        .documents()
        .find(|d| app.workspace().file(*d).unwrap().path().is_none())
        .unwrap();
    assert!(app.workspace().is_dirty(draft));
    assert_eq!(
        app.workspace()
            .editor(draft)
            .unwrap()
            .model()
            .document()
            .snapshot()
            .text(),
        "draft"
    );
    assert_eq!(app.kill_ring().next(), Some("kept"));
    assert_eq!(app.started_roots(), [("cpp".to_owned(), root.clone())]);
    // Undo history stays behind: the text is where the session starts.
    again.command(Command::Edit(Edit::Undo));
    assert_eq!(shown(&again).0[1].1, "Xone\ntwo\n");
    assert!(
        again.app().workspace().is_dirty(
            again
                .app()
                .view(again.app().active_view().unwrap())
                .unwrap()
                .document_id
        )
    );
}
#[test]
fn a_file_gone_is_said_and_its_unsaved_text_stays_under_its_name() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    for name in ["kept.txt", "gone.txt", "edited.txt"] {
        std::fs::write(root.join(name), "text\n").unwrap();
    }
    let mut r = Runtime::new(root.clone()).unwrap();
    for name in ["gone.txt", "edited.txt", "kept.txt"] {
        open(&mut r, &root.join(name));
    }
    r.command(Command::Named(format!(
        "buffer {}",
        root.join("edited.txt").display()
    )));
    r.command(Command::Edit(Edit::InsertText("new ".into())));
    let session = r.session();
    std::fs::remove_file(root.join("gone.txt")).unwrap();
    std::fs::remove_file(root.join("edited.txt")).unwrap();
    let mut again = Runtime::new(root.clone()).unwrap();
    again.resume(&session);
    assert!(again.message().contains("gone.txt"), "{}", again.message());
    let app = again.app();
    let names: Vec<_> = app
        .workspace()
        .documents()
        .map(|d| app.document_name(d))
        .collect();
    assert!(names.iter().any(|n| n.ends_with("edited.txt")), "{names:?}");
    assert!(names.iter().any(|n| n.ends_with("kept.txt")), "{names:?}");
    assert!(!names.iter().any(|n| n.ends_with("gone.txt")), "{names:?}");
    assert_eq!(
        active(&again),
        root.join("edited.txt").display().to_string()
    );
}
#[test]
fn restart_quits_without_asking_about_unsaved_text() {
    let mut r = Runtime::new(std::path::PathBuf::from("/")).unwrap();
    r.command(Command::New);
    r.command(Command::Edit(Edit::InsertText("draft".into())));
    r.command(Command::Named("restart".into()));
    assert!(r.quit_requested() && r.restart_requested());
    assert!(r.layer().is_none(), "nothing is asked");
}
#[test]
fn a_session_keeps_each_windows_tabs() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    std::fs::write(root.join("a.txt"), "alpha\n").unwrap();
    std::fs::write(root.join("b.txt"), "one\n").unwrap();
    let mut r = Runtime::new(root.clone()).unwrap();
    open(&mut r, &root.join("a.txt"));
    keys(&mut r, "C-x 3 C-x o");
    open(&mut r, &root.join("b.txt"));
    let names = |r: &Runtime| -> Vec<Vec<String>> {
        let app = r.app();
        app.windows()
            .views()
            .iter()
            .map(|view| {
                app.windows()
                    .tabs(*view)
                    .iter()
                    .map(|d| app.document_name(*d))
                    .collect()
            })
            .collect()
    };
    let before = names(&r);
    assert_eq!(before[1].len(), 2, "{before:?}");
    let mut again = Runtime::new(root.clone()).unwrap();
    again.resume(&r.session());
    assert_eq!(names(&again), before);
}
#[test]
fn a_tab_comes_back_where_its_window_left_it() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    std::fs::write(root.join("a.txt"), "one\ntwo\nthree\n").unwrap();
    std::fs::write(root.join("b.txt"), "x\n").unwrap();
    let mut r = Runtime::new(root.clone()).unwrap();
    open(&mut r, &root.join("a.txt"));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(8))));
    open(&mut r, &root.join("b.txt"));
    let head = |r: &Runtime| {
        let app = r.app();
        let view = app.view(app.active_view().unwrap()).unwrap();
        let editor = app.workspace().editor(view.document_id).unwrap();
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head
    };
    let a = |r: &Runtime| {
        let app = r.app();
        app.workspace()
            .documents()
            .find(|d| app.document_name(*d).ends_with("a.txt"))
            .unwrap()
    };
    let mut again = Runtime::new(root.clone()).unwrap();
    again.resume(&r.session());
    let document = a(&again);
    again.input(UserInput::Pointer(soda::interaction::Pointer::Document(
        document,
    )));
    assert_eq!(head(&again), 8);
}
#[test]
fn each_window_takes_a_tab_back_where_it_left_it_also_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    std::fs::write(root.join("a.txt"), "one\ntwo\nthree\n").unwrap();
    std::fs::write(root.join("b.txt"), "x\n").unwrap();
    let mut r = Runtime::new(root.clone()).unwrap();
    open(&mut r, &root.join("a.txt"));
    std::fs::write(root.join("c.txt"), "y\n").unwrap();
    // Both windows show a.txt, the left one at 8, the right one at 0, then
    // each turns to another file.
    keys(&mut r, "C-x 3");
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(8))));
    open(&mut r, &root.join("b.txt"));
    keys(&mut r, "C-x o");
    open(&mut r, &root.join("c.txt"));
    let head = |r: &Runtime| {
        let app = r.app();
        let view = app.view(app.active_view().unwrap()).unwrap();
        let editor = app.workspace().editor(view.document_id).unwrap();
        editor
            .model()
            .session(view.session_id)
            .unwrap()
            .selection()
            .head
    };
    let a = |r: &Runtime| {
        let app = r.app();
        app.workspace()
            .documents()
            .find(|d| app.document_name(*d).ends_with("a.txt"))
            .unwrap()
    };
    let back = |r: &mut Runtime| {
        let document = a(r);
        r.input(UserInput::Pointer(soda::interaction::Pointer::Document(
            document,
        )));
        head(r)
    };
    let mut again = Runtime::new(root.clone()).unwrap();
    again.resume(&r.session());
    for r in [&mut r, &mut again] {
        assert_eq!(back(r), 0, "the right window");
        keys(r, "C-x o");
        assert_eq!(back(r), 8, "the left window");
    }
}
