use soda::core::*;

#[test]
fn transactions_are_atomic_utf8_checked_and_versioned() {
    let mut editor = StandaloneEditor::new("a界b\r\n\tend");
    let old = editor.state().snapshot().clone();
    let invalid = Transaction::new(0, vec![Change::new(1..2, "x")]);
    assert_eq!(
        editor.dispatch(invalid).unwrap_err(),
        EditError::InvalidRange
    );
    assert_eq!(editor.state().snapshot().text(), old.text());
    let mut tx = Transaction::new(0, vec![Change::new(1..4, "文"), Change::new(8..11, "tail")]);
    tx.selection = Some(Selection { anchor: 1, head: 4 });
    editor.dispatch(tx).unwrap();
    assert_eq!(editor.state().snapshot().text(), "a文b\r\n\ttail");
    assert_eq!(old.text(), "a界b\r\n\tend");
    assert_eq!(
        editor.dispatch(Transaction::new(0, vec![])).unwrap_err(),
        EditError::StaleVersion
    );
    editor.undo().unwrap();
    assert_eq!(editor.state().snapshot().text(), old.text());
    assert_eq!(editor.state().snapshot().version(), 2);
    editor.redo().unwrap();
    assert_eq!(editor.state().selection(), Selection { anchor: 1, head: 4 });
    assert_eq!(editor.state().snapshot().version(), 3);
}
#[test]
fn overlapping_changes_and_invalid_result_selection_do_not_mutate() {
    let mut editor = StandaloneEditor::new("abc");
    for changes in [
        vec![Change::new(0..2, "x"), Change::new(1..3, "y")],
        vec![Change::new(1..1, "x"), Change::new(1..1, "y")],
    ] {
        assert_eq!(
            editor.dispatch(Transaction::new(0, changes)).unwrap_err(),
            EditError::OverlappingChanges
        );
    }
    let mut tx = Transaction::new(0, vec![Change::new(0..3, "界")]);
    tx.selection = Some(Selection::caret(1));
    assert_eq!(
        editor.dispatch(tx).unwrap_err(),
        EditError::InvalidSelection
    );
    assert_eq!(editor.state().snapshot().text(), "abc");
    assert!(!editor.undo().unwrap());
}
#[test]
fn position_mapping_handles_replacement_boundaries_and_adjacent_insertions() {
    let state = EditorState::new("abcdef");
    let (_, map) = state
        .apply(Transaction::new(
            0,
            vec![Change::new(1..3, "X"), Change::new(3..3, "YZ")],
        ))
        .unwrap();
    assert_eq!(map.map(0, Association::After), 0);
    assert_eq!(map.map(1, Association::Before), 1);
    assert_eq!(map.map(2, Association::After), 2);
    assert_eq!(map.map(3, Association::Before), 2);
    assert_eq!(map.map(3, Association::After), 4);
    assert_eq!(map.map(6, Association::After), 7);
}
#[test]
fn explicit_history_groups_and_branching_redo() {
    let mut e = StandaloneEditor::new("");
    for (p, ch) in [(0, "a"), (1, "b")] {
        let mut tx = Transaction::new(e.state().snapshot().version(), vec![Change::new(p..p, ch)]);
        tx.history_group = Some(7);
        e.dispatch(tx).unwrap();
    }
    e.undo().unwrap();
    assert_eq!(e.state().snapshot().text(), "");
    e.redo().unwrap();
    assert_eq!(e.state().snapshot().text(), "ab");
    e.undo().unwrap();
    e.dispatch(Transaction::new(
        e.state().snapshot().version(),
        vec![Change::new(0..0, "x")],
    ))
    .unwrap();
    assert!(!e.redo().unwrap());
}
#[test]
fn snapshots_index_crlf_trailing_lines_and_unicode_bytes() {
    let state = EditorState::new("界\r\n\t\n");
    let s = state.snapshot();
    assert_eq!(s.line_count(), 3);
    assert_eq!(s.line(0).as_deref(), Some("界"));
    assert_eq!(s.line(1).as_deref(), Some("\t"));
    assert_eq!(s.line(2).as_deref(), Some(""));
    assert_eq!(s.line_of(2), None);
    assert_eq!(s.line_of(5), Some(1));
    assert_eq!(s.line_of(7), Some(2));
}

#[test]
fn selection_transactions_do_not_advance_text_revision() {
    let mut editor = StandaloneEditor::new("abc");
    let mut tx = Transaction::new(0, vec![]);
    tx.selection = Some(Selection::caret(2));
    editor.dispatch(tx).unwrap();
    assert_eq!(editor.state().snapshot().version(), 0);
    assert_eq!(editor.state().selection(), Selection::caret(2));
}

#[test]
fn net_zero_history_groups_still_advance_revision_on_restore() {
    let mut editor = StandaloneEditor::new("abc");
    for (range, text) in [(1..1, "x"), (1..2, "")] {
        let mut tx = Transaction::new(
            editor.state().snapshot().version(),
            vec![Change::new(range, text)],
        );
        tx.history_group = Some(1);
        editor.dispatch(tx).unwrap();
    }
    let revision = editor.state().snapshot().version();
    editor.undo().unwrap();
    assert_eq!(editor.state().snapshot().text(), "abc");
    assert_eq!(editor.state().snapshot().version(), revision + 1);
    editor.redo().unwrap();
    assert_eq!(editor.state().snapshot().version(), revision + 2);
}
