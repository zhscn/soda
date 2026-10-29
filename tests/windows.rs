use soda::{
    application::{Axis, Event, Node},
    core::Selection,
    editor::Command as Edit,
    interaction::{Command, EditMode, KeyStroke, UserInput, WindowCommand},
    runtime::Runtime,
};
use std::path::PathBuf;

fn runtime(text: &str) -> Runtime {
    let mut r = Runtime::new(PathBuf::from("/")).unwrap();
    r.start(None);
    r.command(Command::SetMode(EditMode::Insert));
    r.command(Command::Edit(Edit::InsertText(text.into())));
    r.command(Command::Edit(Edit::SetSelection(Selection::caret(2))));
    r.command(Command::SetMode(EditMode::Normal));
    r
}
fn keys(r: &mut Runtime, notation: &str) {
    for key in KeyStroke::parse_sequence(notation).unwrap() {
        r.input(UserInput::Key(key));
    }
}
fn caret(r: &Runtime) -> usize {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    r.app()
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head
}

#[test]
fn splits_copy_the_view_and_focus_moves_between_windows() {
    let mut r = runtime("one\ntwo");
    let first = r.app().active_view().unwrap();
    keys(&mut r, "<c-w>v");
    let second = r.app().active_view().unwrap();
    assert_ne!(first, second);
    assert_eq!(r.app().windows().views(), [first, second]);
    // The new window shows the same document at the same place, with a
    // selection of its own.
    assert_eq!(caret(&r), 2);
    keys(&mut r, "j");
    keys(&mut r, "<c-w>h");
    assert_eq!(r.app().active_view(), Some(first));
    assert_eq!(caret(&r), 2);
    keys(&mut r, "<c-w>s");
    let third = r.app().active_view().unwrap();
    assert_eq!(
        r.app().windows().root(),
        Some(&Node::Split {
            axis: Axis::Columns,
            children: vec![
                Node::Split {
                    axis: Axis::Rows,
                    children: vec![Node::Window(first), Node::Window(third)],
                },
                Node::Window(second),
            ],
        })
    );
    keys(&mut r, "<c-w>k");
    assert_eq!(r.app().active_view(), Some(first));
    keys(&mut r, "<c-w>l");
    assert_eq!(r.app().active_view(), Some(second));
    keys(&mut r, "<c-w>w");
    assert_eq!(r.app().active_view(), Some(first));
    // Closing a window keeps its view, hidden.
    keys(&mut r, "<c-w>c");
    assert_eq!(r.app().windows().views(), [third, second]);
    assert!(r.app().view(first).is_some());
    keys(&mut r, "<c-w>o");
    assert_eq!(r.app().windows().views().len(), 1);
    keys(&mut r, "<c-w>c");
    assert!(r.message().contains("last window"), "{}", r.message());
}
#[test]
fn documents_shown_in_a_window_replace_its_view_and_closing_repairs_windows() {
    let mut r = runtime("one");
    let first = r.app().active_view().unwrap();
    r.command(Command::Window(WindowCommand::Split(Axis::Columns, None)));
    let right = r.app().active_view().unwrap();
    r.command(Command::New);
    let new = r.app().active_view().unwrap();
    // The new document took the right window's place.
    assert_eq!(r.app().windows().views(), [first, new]);
    // Its own view of the first document is hidden, so switching back in
    // this window shows it here again rather than jumping left.
    r.command(Command::NextView);
    assert_eq!(r.app().windows().views(), [first, right]);
    // Closing the new document leaves the windows as they are, since it is
    // not shown; closing a shown one fills its window with a hidden view.
    let document = r.app().view(new).unwrap().document_id;
    assert!(r.dispatch(Event::CloseDocument {
        document,
        discard: true,
    }));
    assert_eq!(r.app().windows().views(), [first, right]);
    r.command(Command::New);
    let third = r.app().active_view().unwrap();
    let document = r.app().view(first).unwrap().document_id;
    assert!(r.dispatch(Event::CloseDocument {
        document,
        discard: true,
    }));
    // Both views of the first document are gone. No hidden view is left
    // to show in the left window, so it closes.
    assert_eq!(r.app().windows().views(), [third]);
    assert_eq!(r.app().active_view(), Some(third));
}
#[test]
fn page_rows_follow_the_active_window() {
    let lines: Vec<String> = (0..40).map(|n| n.to_string()).collect();
    let mut r = runtime(&lines.join("\n"));
    r.resize(20, 5);
    r.set_page_rows(8);
    keys(&mut r, "gg<c-d>");
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let text = r
        .app()
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .document()
        .snapshot()
        .text()
        .to_owned();
    assert_eq!(&text[caret(&r)..caret(&r) + 2], "4\n");
}
fn settle(r: &mut Runtime, done: impl Fn(&Runtime) -> bool) {
    for _ in 0..500 {
        r.poll();
        if done(r) {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    panic!("timed out: {:?} in {}", r.message(), active_name(r));
}
fn active_name(r: &Runtime) -> String {
    let view = r.app().view(r.app().active_view().unwrap()).unwrap();
    let file = r.app().workspace().file(view.document_id).unwrap();
    file.scratch()
        .map(str::to_owned)
        .or_else(|| {
            file.path()
                .map(|p| p.file_name().unwrap().to_string_lossy().into())
        })
        .unwrap_or_default()
}
#[test]
fn grep_results_show_below_and_open_locations_in_the_other_window() {
    use soda::application::Side;
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("a.txt"), "one\n  needle here\n").unwrap();
    std::fs::write(root.path().join("b.txt"), "needle\n").unwrap();
    let mut r = Runtime::new(root.path().to_owned()).unwrap();
    r.start(None);
    let main = r.app().active_view().unwrap();
    r.command(Command::Grep("needle".into()));
    settle(&mut r, |r| active_name(r) == "*grep*");
    assert!(r.message().starts_with("2 matches"), "{}", r.message());
    let results = r.app().active_view().unwrap();
    assert_eq!(r.app().windows().side(results), Some(Side::Bottom));
    assert_eq!(r.app().windows().views(), [main, results]);
    // Enter on the first result opens it in the split window, not here.
    keys(&mut r, "<ret>");
    settle(&mut r, |r| active_name(r) == "a.txt");
    let file = r.app().active_view().unwrap();
    assert_eq!(r.app().windows().views(), [file, results]);
    assert_eq!(caret(&r), "one\n  ".len());
    // Stepping moves the results caret and opens the next file in place.
    keys(&mut r, "]q");
    settle(&mut r, |r| active_name(r) == "b.txt");
    assert_eq!(r.app().windows().views().len(), 2);
    keys(&mut r, "]q");
    assert_eq!(r.message(), "At the last result");
    // A new search reuses the document and its side window.
    r.command(Command::Grep("ONE".into()));
    settle(&mut r, |r| {
        active_name(r) == "*grep*" || r.message().starts_with("No")
    });
    assert_eq!(r.message(), "No matches for ONE");
    r.command(Command::Grep("one".into()));
    settle(&mut r, |r| active_name(r) == "*grep*");
    assert_eq!(r.app().active_view(), Some(results));
    // Side windows close like others and cannot be split.
    keys(&mut r, "<c-w>s");
    assert!(r.message().contains("side windows"), "{}", r.message());
    keys(&mut r, "<c-w>c");
    assert_eq!(r.app().windows().views().len(), 1);
    // Rules move a kind elsewhere; a hidden results view comes back there.
    r.command(Command::Named("display grep right 30".into()));
    r.command(Command::Named("buffer *grep*".into()));
    assert_eq!(r.app().windows().side(results), Some(Side::Right));
}
