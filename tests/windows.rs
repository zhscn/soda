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
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
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
    keys(&mut r, "C-x 3");
    // Focus stays, as with Emacs's split-window.
    assert_eq!(r.app().active_view(), Some(first));
    let second = r.app().windows().views()[1];
    assert_ne!(first, second);
    assert_eq!(r.app().windows().views(), [first, second]);
    // The new window shows the same document at the same place, with a
    // selection of its own.
    keys(&mut r, "C-x o");
    assert_eq!(r.app().active_view(), Some(second));
    assert_eq!(caret(&r), 2);
    keys(&mut r, "j");
    keys(&mut r, "C-c H");
    assert_eq!(r.app().active_view(), Some(first));
    assert_eq!(caret(&r), 2);
    keys(&mut r, "C-x 2");
    let third = r.app().windows().views()[1];
    assert_eq!(
        r.app().windows().root(),
        Some(&Node::Split {
            axis: Axis::Columns,
            children: vec![
                Node::Split {
                    axis: Axis::Rows,
                    children: vec![Node::Window(first), Node::Window(third)],
                    weights: vec![1; 2],
                },
                Node::Window(second),
            ],
            weights: vec![1; 2],
        })
    );
    keys(&mut r, "C-c J");
    assert_eq!(r.app().active_view(), Some(third));
    keys(&mut r, "C-c K");
    assert_eq!(r.app().active_view(), Some(first));
    keys(&mut r, "C-c L");
    assert_eq!(r.app().active_view(), Some(second));
    keys(&mut r, "C-x o");
    assert_eq!(r.app().active_view(), Some(first));
    // Closing a window keeps its view, hidden.
    keys(&mut r, "C-x 0");
    assert_eq!(r.app().windows().views(), [third, second]);
    assert!(r.app().view(first).is_some());
    keys(&mut r, "C-x 1");
    assert_eq!(r.app().windows().views().len(), 1);
    keys(&mut r, "C-x 0");
    assert!(r.message().contains("last window"), "{}", r.message());
}
#[test]
fn documents_shown_in_a_window_replace_its_view_and_closing_repairs_windows() {
    let mut r = runtime("one");
    let first = r.app().active_view().unwrap();
    r.command(Command::Window(WindowCommand::Split(Axis::Columns, None)));
    keys(&mut r, "C-x o");
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
    keys(&mut r, "M-< C-v");
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
    r.source_lua("modal", include_str!("fixtures/modal.lua"))
        .unwrap();
    r.command(soda::interaction::Command::New);
    let main = r.app().active_view().unwrap();
    r.command(Command::Grep("needle".into()));
    settle(&mut r, |r| active_name(r) == "*grep*");
    assert!(r.message().starts_with("2 matches"), "{}", r.message());
    let results = r.app().active_view().unwrap();
    assert_eq!(r.app().windows().side(results), Some(Side::Bottom));
    assert_eq!(r.app().windows().views(), [main, results]);
    // Enter on the first result opens it in the split window, not here.
    keys(&mut r, "RET");
    settle(&mut r, |r| active_name(r) == "a.txt");
    let file = r.app().active_view().unwrap();
    assert_eq!(r.app().windows().views(), [file, results]);
    assert_eq!(caret(&r), "one\n  ".len());
    // Stepping moves the results caret and opens the next file in place.
    keys(&mut r, "M-g n");
    settle(&mut r, |r| active_name(r) == "b.txt");
    assert_eq!(r.app().windows().views().len(), 2);
    keys(&mut r, "M-g n");
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
    keys(&mut r, "C-x 2");
    assert!(r.message().contains("side windows"), "{}", r.message());
    keys(&mut r, "C-x 0");
    assert_eq!(r.app().windows().views().len(), 1);
    // Rules move a kind elsewhere; a hidden results view comes back there.
    r.command(Command::Named("display grep right 30".into()));
    r.command(Command::Named("buffer *grep*".into()));
    assert_eq!(r.app().windows().side(results), Some(Side::Right));
}
/// Two windows on different documents; the second is active.
fn two_documents(first: &str, second: &str) -> (Runtime, Vec<soda::application::ViewId>) {
    let mut r = runtime(first);
    keys(&mut r, "C-x 2");
    r.command(Command::New);
    r.command(Command::SetMode(soda::interaction::EditMode::Insert));
    r.input(UserInput::Paste(second.into()));
    r.command(Command::SetMode(soda::interaction::EditMode::Normal));
    keys(&mut r, "M-<");
    let windows = r.app().windows().views();
    assert_eq!(windows.len(), 2);
    let rows = windows.iter().map(|view| (*view, 10)).collect();
    r.set_window_rows(rows);
    (r, windows)
}
#[test]
fn jump_labels_cover_every_window_with_the_active_one_first() {
    let (mut r, windows) = two_documents("xy one\n", "  xy two\n");
    let active = r.app().active_view().unwrap();
    let other = *windows.iter().find(|view| **view != active).unwrap();
    keys(&mut r, "SPC jxy");
    let Some(soda::interaction::Layer::Labels(session)) = r.layer() else {
        panic!("no labels: {}", r.message());
    };
    let targets: Vec<_> = session
        .targets()
        .map(|(target, _)| (target.label.clone(), target.view))
        .collect();
    assert_eq!(targets, [("a".to_owned(), active), ("s".to_owned(), other)]);
    keys(&mut r, "s");
    assert_eq!(r.app().active_view(), Some(other));
    assert_eq!(caret(&r), 0);
}
#[test]
fn jump_takes_a_single_match_in_another_window() {
    let (mut r, windows) = two_documents("  only here\n", "nothing\n");
    let active = r.app().active_view().unwrap();
    let other = *windows.iter().find(|view| **view != active).unwrap();
    keys(&mut r, "SPC jon");
    assert_eq!(r.app().active_view(), Some(other));
    assert_eq!(caret(&r), 2);
}
#[test]
fn jump_respects_the_rows_of_each_window() {
    let (mut r, windows) = two_documents("a\nb\nzz\n", "nothing\n");
    let rows = windows.iter().map(|view| (*view, 2)).collect();
    r.set_window_rows(rows);
    keys(&mut r, "SPC jzz");
    assert_eq!(r.message(), "No zz on screen");
}

#[test]
fn resize_mode_moves_the_edge_until_escape_and_reset_evens_it() {
    let mut r = runtime("one\ntwo");
    r.set_editing_area(81, 20);
    let first = r.app().active_view().unwrap();
    keys(&mut r, "C-x 3 C-x o");
    let second = r.app().active_view().unwrap();
    let width = |r: &Runtime, view| r.app().window_area(view).unwrap().width;
    assert_eq!((width(&r, first), width(&r, second)), (40, 40));
    keys(&mut r, "C-x ^");
    assert!(r.layer().is_some());
    // Two columns a step, four with Ctrl; the window to the left gives them.
    keys(&mut r, "w C-w");
    assert_eq!((width(&r, first), width(&r, second)), (34, 46));
    keys(&mut r, "n");
    assert_eq!(width(&r, second), 44);
    let shown = r.layer().unwrap().presentation().text;
    assert!(
        shown.contains("20 rows 44 cols (was 20 rows 40 cols)"),
        "{shown}"
    );
    // Nothing is above or below: the size stays and the mode goes on.
    keys(&mut r, "t");
    assert!(r.layer().is_some());
    keys(&mut r, "ESC");
    assert!(r.layer().is_none());
    // Sizes are kept as weights, so a smaller terminal scales both.
    r.set_editing_area(41, 20);
    assert_eq!((width(&r, first), width(&r, second)), (18, 22));
    r.command(Command::Named("resize-window reset".into()));
    assert_eq!((width(&r, first), width(&r, second)), (20, 20));
    r.command(Command::Named("resize-window narrower 30".into()));
    assert_eq!((width(&r, first), width(&r, second)), (32, 8));
}
#[test]
fn a_tab_shows_its_document_in_its_window_even_one_another_window_shows() {
    use soda::interaction::Pointer;
    let mut r = runtime("one\ntwo");
    let document = |r: &Runtime, view| r.app().view(view).unwrap().document_id;
    let first = r.app().active_view().unwrap();
    let a = document(&r, first);
    keys(&mut r, "C-x 3 C-x o");
    r.command(Command::New);
    let second = r.app().active_view().unwrap();
    assert_ne!(document(&r, second), a);
    // The tab of the first window's document, in the second window's row.
    r.input(UserInput::Pointer(Pointer::Document(a)));
    let windows = r.app().windows().views();
    let docs: Vec<_> = windows.iter().map(|v| document(&r, *v)).collect();
    assert_eq!(docs, [a, a], "both windows show it");
    assert_eq!(r.app().active_view(), Some(windows[1]));
    // Its tab in its own window's row leaves things as they are.
    r.input(UserInput::Pointer(Pointer::Document(a)));
    assert_eq!(r.app().windows().views(), windows);
}
#[test]
fn each_window_has_the_tabs_of_what_it_showed_and_closing_one_keeps_the_document() {
    let mut r = runtime("one");
    let document = |r: &Runtime, view| r.app().view(view).unwrap().document_id;
    let tabs = |r: &Runtime, at: usize| {
        let view = r.app().windows().views()[at];
        r.app().windows().tabs(view).to_vec()
    };
    let a = document(&r, r.app().active_view().unwrap());
    keys(&mut r, "C-x 3 C-x o");
    r.command(Command::New);
    let b = document(&r, r.app().active_view().unwrap());
    // A document opened in one window is a tab there only.
    assert_eq!(tabs(&r, 0), [a]);
    assert_eq!(tabs(&r, 1), [a, b]);
    // Going back to a tab keeps the order.
    r.input(UserInput::Pointer(soda::interaction::Pointer::Document(a)));
    assert_eq!(tabs(&r, 1), [a, b]);
    // Closing the tab shown turns the window to the one beside it; the
    // document stays open.
    r.command(Command::Named("close-tab".into()));
    assert_eq!(document(&r, r.app().active_view().unwrap()), b);
    assert_eq!(tabs(&r, 1), [b]);
    assert!(r.app().workspace().editor(a).is_some());
    assert_eq!(tabs(&r, 0), [a]);
    r.command(Command::Named("close-tab".into()));
    assert!(r.message().contains("only tab"), "{}", r.message());
    // A new split starts with the document it shows alone.
    keys(&mut r, "C-x 2");
    assert_eq!(tabs(&r, 2), [b]);
}
