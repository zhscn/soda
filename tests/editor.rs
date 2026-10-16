use soda::{
    core::{EditError, Selection, Transaction},
    cpp::CppStyle,
    editor::{Command, Editor, EditorModel, Language},
    language::IndentAdvice,
};

#[test]
fn model_queries_and_cpp_enter_are_independent_of_views() {
    let rules = CppStyle::default().compile().unwrap();
    let mut model = EditorModel::new("void f() {}", &rules);
    assert!(matches!(
        model.indentation(0).unwrap(),
        IndentAdvice::Set { .. }
    ));
    let mut editor = Editor::from_model(model);
    editor
        .execute(Command::SetSelection(Selection::caret(10)))
        .unwrap();
    assert_eq!(editor.model().text_revision(), 0);
    let update = editor.execute(Command::Enter).unwrap();
    assert!(update.text_changed);
    assert_eq!(editor.state().snapshot().text(), "void f() {\n    \n}");
    assert_eq!(editor.state().selection(), Selection::caret(15));
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "void f() {}");
    assert_eq!(editor.state().selection(), Selection::caret(10));
    editor.execute(Command::Redo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "void f() {\n    \n}");
    assert!(editor.model().text_revision() > update.text_revision);
}

#[test]
fn command_stream_reports_failures_and_continues_atomically() {
    let mut editor = Editor::new("", Language::PlainText);
    let mut outcomes = Vec::new();
    editor.run(
        [
            Command::InsertText("你".into()),
            Command::SetSelection(Selection::caret(1)),
            Command::TypeChar('好'),
            Command::Apply(Transaction::new(0, vec![])),
            Command::Enter,
        ],
        |model, outcome| outcomes.push((model.state().snapshot().text().to_owned(), outcome)),
    );
    assert_eq!(outcomes[1].0, "你");
    assert!(matches!(outcomes[1].1, Err(EditError::InvalidSelection)));
    assert!(matches!(outcomes[3].1, Err(EditError::StaleVersion)));
    assert_eq!(editor.state().snapshot().text(), "你好\n");
}

#[test]
fn language_changes_and_paste_have_explicit_boundaries() {
    let mut editor = Editor::new("void f() {}", Language::PlainText);
    editor
        .execute(Command::SetSelection(Selection::caret(10)))
        .unwrap();
    editor.execute(Command::Enter).unwrap();
    assert_eq!(editor.state().snapshot().text(), "void f() {\n}");
    editor.execute(Command::Undo).unwrap();
    let update = editor
        .execute(Command::SetLanguage(
            CppStyle::default().compile().unwrap().into(),
        ))
        .unwrap();
    assert!(update.language_changed);
    assert!(!update.text_changed);
    editor.execute(Command::InsertText("\n".into())).unwrap();
    assert_eq!(editor.state().snapshot().text(), "void f() {\n}");
    editor.execute(Command::Undo).unwrap();
    editor.execute(Command::Enter).unwrap();
    assert_eq!(editor.state().snapshot().text(), "void f() {\n    \n}");
}

#[test]
fn selection_revision_and_failed_commands_leave_text_revision_unchanged() {
    let mut editor = Editor::new("\t  value", Language::PlainText);
    editor
        .execute(Command::SetSelection(Selection::caret(8)))
        .unwrap();
    let version = editor.state().snapshot().version();
    assert!(editor.execute(Command::Reindent(9)).is_err());
    assert_eq!(editor.state().snapshot().version(), version);
    assert_eq!(editor.model().text_revision(), 0);
    editor.execute(Command::Enter).unwrap();
    assert_eq!(editor.state().snapshot().text(), "\t  value\n\t  ");
}

#[test]
fn auto_indent_preserves_other_session_positions_and_history_maps_both_ways() {
    use soda::editor::EditOrigin;
    let text = "class C {\n      public\n};";
    let mut editor = Editor::new(text, CppStyle::default().compile().unwrap());
    let label = text.find("public").unwrap();
    let owner = editor.model().default_session();
    let other = editor.add_session(Selection::caret(label + 2)).unwrap();
    editor
        .execute(Command::SetSelection(Selection::caret(label + 6)))
        .unwrap();
    let edit = editor.execute(Command::TypeChar(':')).unwrap();
    assert_eq!(editor.state().snapshot().text(), "class C {\npublic:\n};");
    let update = edit.document.unwrap();
    assert_eq!(update.changes.len(), 2);
    assert_eq!(update.origin, EditOrigin::Input);
    assert_eq!(
        update
            .mapping
            .map_tracked(label + 2, soda::core::Association::After),
        Some(label - 4)
    );
    assert_eq!(
        editor.model().session(other).unwrap().selection(),
        Selection::caret(label - 4)
    );
    assert_eq!(update.document_id, editor.model().document().id());
    let undo = editor
        .execute_for(other, Command::Undo)
        .unwrap()
        .document
        .unwrap();
    assert_eq!(undo.origin, EditOrigin::Undo);
    assert_eq!(undo.before_revision, update.after_revision);
    assert_eq!(editor.state().snapshot().text(), text);
    assert_eq!(
        editor.model().session(owner).unwrap().selection(),
        Selection::caret(label + 6)
    );
    assert_eq!(
        editor.model().session(other).unwrap().selection(),
        Selection::caret(label + 2)
    );
    let redo = editor
        .execute_for(other, Command::Redo)
        .unwrap()
        .document
        .unwrap();
    assert_eq!(redo.origin, EditOrigin::Redo);
    assert_eq!(
        editor.model().session(other).unwrap().selection(),
        Selection::caret(label - 4)
    );
}

#[test]
fn document_and_session_updates_have_distinct_lifecycles() {
    let mut editor = Editor::new("abc", Language::PlainText);
    let default = editor.model().default_session();
    let other = editor.add_session(Selection::caret(2)).unwrap();
    let selected = editor
        .execute_for(other, Command::SetSelection(Selection::caret(1)))
        .unwrap();
    assert!(selected.document.is_none());
    assert_eq!(selected.sessions.len(), 1);
    assert_eq!(selected.text_revision, 0);
    assert_eq!(
        editor.model().session(default).unwrap().selection(),
        Selection::caret(0)
    );
    let changed = editor
        .execute(Command::SetLanguage(
            CppStyle::default().compile().unwrap().into(),
        ))
        .unwrap();
    assert!(changed.document.is_none());
    assert_eq!(editor.model().document().config_generation(), 1);
    let unchanged = editor
        .execute(Command::SetLanguage(editor.model().language()))
        .unwrap();
    assert!(!unchanged.language_changed);
    assert_eq!(editor.model().document().config_generation(), 1);
    editor.execute_for(other, Command::TypeChar('界')).unwrap();
    editor.close_session(other).unwrap();
    assert!(matches!(
        editor.execute_for(other, Command::Undo),
        Err(EditError::UnknownSession)
    ));
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "abc");
    let fresh = editor.add_session(Selection::caret(0)).unwrap();
    assert_ne!(fresh, other);
    editor.execute(Command::Redo).unwrap();
    assert_eq!(
        editor.model().session(fresh).unwrap().selection(),
        Selection::caret(0)
    );
    let independent = Editor::new("abc", Language::PlainText);
    assert_ne!(
        editor.model().document().id(),
        independent.model().document().id()
    );
    assert!(matches!(
        editor.execute_for(independent.model().default_session(), Command::Enter),
        Err(EditError::UnknownSession)
    ));
}

#[test]
fn grouped_history_preserves_gaps_and_does_not_merge_between_sessions() {
    use soda::core::Change;
    let mut editor = Editor::new("abcdef", Language::PlainText);
    let other = editor.add_session(Selection::caret(3)).unwrap();
    for (range, inserted) in [(0..0, "X"), (7..7, "Y")] {
        let mut tx = Transaction::new(
            editor.model().text_revision(),
            vec![Change::new(range, inserted)],
        );
        tx.history_group = Some(1);
        editor.execute(Command::Apply(tx)).unwrap();
    }
    assert_eq!(
        editor.model().session(other).unwrap().selection(),
        Selection::caret(4)
    );
    let undo = editor.execute(Command::Undo).unwrap().document.unwrap();
    assert_eq!(undo.changes.len(), 2);
    assert_eq!(
        editor.model().session(other).unwrap().selection(),
        Selection::caret(3)
    );
    editor.execute(Command::Redo).unwrap();
    for session in [editor.model().default_session(), other] {
        let mut tx = Transaction::new(editor.model().text_revision(), vec![Change::new(0..0, "Z")]);
        tx.history_group = Some(2);
        editor.execute_for(session, Command::Apply(tx)).unwrap();
    }
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ZXabcdefY");
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "XabcdefY");
}

#[test]
fn adjacent_deletions_have_a_valid_inverse_and_failures_are_atomic_across_sessions() {
    use soda::core::Change;
    let mut editor = Editor::new("a界bc", Language::PlainText);
    let other = editor.add_session(Selection::caret(5)).unwrap();
    let mut invalid = Transaction::new(0, vec![Change::new(0..1, "文")]);
    invalid.selection = Some(Selection::caret(1));
    assert!(editor.execute(Command::Apply(invalid)).is_err());
    assert_eq!(
        editor.model().session(other).unwrap().selection(),
        Selection::caret(5)
    );
    assert_eq!(editor.model().text_revision(), 0);
    assert!(!editor.execute(Command::Undo).unwrap().text_changed);
    editor
        .execute(Command::Apply(Transaction::new(
            0,
            vec![Change::new(1..4, ""), Change::new(4..5, "")],
        )))
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "ac");
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "a界bc");
    editor.execute(Command::Redo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ac");
}

#[test]
fn grouped_random_utf8_edits_restore_every_checkpoint() {
    use soda::core::Change;
    let mut editor = Editor::new("ab界\r\nα\tcd", Language::PlainText);
    let other = editor.add_session(Selection::caret(5)).unwrap();
    let mut oracle = editor.state().snapshot().text().to_owned();
    let mut checkpoints = vec![oracle.clone()];
    let mut seed = 17_u64;
    let mut next = |limit: usize| {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        seed as usize % limit
    };
    let inserted = ["", "你", "xy", "\r\n\t", "αβ"];
    for index in 0..120 {
        let boundaries: Vec<_> = (0..=oracle.len())
            .filter(|&position| oracle.is_char_boundary(position))
            .collect();
        let a = next(boundaries.len());
        let b = next(boundaries.len());
        let range = boundaries[a.min(b)]..boundaries[a.max(b)];
        let replacement = inserted[next(inserted.len())];
        oracle.replace_range(range.clone(), replacement);
        let mut tx = Transaction::new(
            editor.model().text_revision(),
            vec![Change::new(range, replacement)],
        );
        tx.history_group = Some(index / 3);
        editor.execute(Command::Apply(tx)).unwrap();
        assert_eq!(editor.state().snapshot().text(), oracle);
        let session = editor.model().session(other).unwrap();
        assert!(
            session
                .state()
                .snapshot()
                .is_char_boundary(session.selection().head)
        );
        if index % 3 == 2 {
            checkpoints.push(oracle.clone());
        }
    }
    for expected in checkpoints[..checkpoints.len() - 1].iter().rev() {
        editor.execute(Command::Undo).unwrap();
        assert_eq!(editor.state().snapshot().text(), expected);
    }
    assert!(!editor.execute(Command::Undo).unwrap().text_changed);
    for expected in &checkpoints[1..] {
        editor.execute(Command::Redo).unwrap();
        assert_eq!(editor.state().snapshot().text(), expected);
    }
}

#[test]
fn explicit_edit_groups_preserve_original_and_final_carets_across_failed_edits() {
    let mut editor = soda::editor::Editor::new("", soda::editor::Language::PlainText);
    editor
        .execute(Command::BeginUndoGroup(Selection::caret(0)))
        .unwrap();
    editor.execute(Command::TypeChar('a')).unwrap();
    assert!(
        editor
            .execute(Command::Apply(soda::core::Transaction::new(
                editor.state().snapshot().version(),
                vec![soda::core::Change::new(9..10, "x")]
            )))
            .is_err()
    );
    editor.execute(Command::TypeChar('b')).unwrap();
    editor
        .execute(Command::EndUndoGroup(Selection::caret(1)))
        .unwrap();
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "");
    assert_eq!(editor.state().selection(), Selection::caret(0));
    editor.execute(Command::Redo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ab");
    assert_eq!(editor.state().selection(), Selection::caret(1));
}
