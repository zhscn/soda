use soda::{
    core::Selection,
    cpp::{CppStyle, TabPolicy},
    editor::search::SearchQuery,
    editor::{Command, Direction, Editor, Motion},
};
use std::{num::NonZeroUsize, time::Duration};
fn select(editor: &mut Editor, anchor: usize, head: usize) {
    editor
        .execute(Command::SetSelection(Selection { anchor, head }))
        .unwrap();
}
fn move_by(editor: &mut Editor, motion: Motion, extend: bool) {
    editor.execute(Command::Move { motion, extend }).unwrap();
}

#[test]
fn character_commands_respect_graphemes_and_crlf() {
    let mut editor = Editor::new("e\u{301}👨‍👩‍👧‍👦\r\n界", soda::editor::Language::PlainText);
    let accent = "e\u{301}".len();
    let family = "e\u{301}👨‍👩‍👧‍👦".len();
    for expected in [accent, family, family + 2, family + 5] {
        move_by(&mut editor, Motion::Forward, false);
        assert_eq!(editor.state().selection().head, expected);
    }
    editor
        .execute(Command::Delete {
            direction: Direction::Backward,
            smart: false,
        })
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "e\u{301}👨‍👩‍👧‍👦\r\n");
    editor
        .execute(Command::Delete {
            direction: Direction::Backward,
            smart: false,
        })
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "e\u{301}👨‍👩‍👧‍👦");
    editor
        .execute(Command::Delete {
            direction: Direction::Backward,
            smart: false,
        })
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "e\u{301}");
}

#[test]
fn vertical_movement_preserves_goal_column_per_session() {
    let mut editor = Editor::new(
        "\t界xx\nq\n12345678",
        CppStyle {
            tab_width: NonZeroUsize::new(4).unwrap(),
            ..Default::default()
        }
        .compile()
        .unwrap(),
    );
    select(&mut editor, 5, 5); // column 7, after first x
    move_by(&mut editor, Motion::Down, false);
    assert_eq!(editor.state().selection().head, 8);
    move_by(&mut editor, Motion::Down, false);
    assert_eq!(editor.state().selection().head, 16);
    move_by(&mut editor, Motion::Up, false);
    move_by(&mut editor, Motion::Up, false);
    assert_eq!(editor.state().selection().head, 5);
    let other = editor.add_session(Selection::caret(0)).unwrap();
    editor
        .execute_for(
            other,
            Command::Move {
                motion: Motion::Down,
                extend: false,
            },
        )
        .unwrap();
    assert_eq!(editor.model().session(other).unwrap().selection().head, 7);
}

#[test]
fn extending_and_collapsing_selections_does_not_change_text_revision() {
    let mut editor = Editor::new("ab\ncd", soda::editor::Language::PlainText);
    move_by(&mut editor, Motion::Forward, true);
    assert_eq!(editor.state().selection(), Selection { anchor: 0, head: 1 });
    move_by(&mut editor, Motion::Backward, false);
    assert_eq!(editor.state().selection(), Selection::caret(0));
    select(&mut editor, 4, 1);
    move_by(&mut editor, Motion::Forward, false);
    assert_eq!(editor.state().selection(), Selection::caret(4));
    move_by(&mut editor, Motion::LineEnd, true);
    assert_eq!(editor.state().selection(), Selection { anchor: 4, head: 5 });
    assert_eq!(editor.model().text_revision(), 0);
}

#[test]
fn delete_selection_line_join_and_crlf_interior_are_atomic() {
    let mut editor = Editor::new("ab\r\ncd", soda::editor::Language::PlainText);
    select(&mut editor, 3, 3);
    editor
        .execute(Command::Delete {
            direction: Direction::Backward,
            smart: false,
        })
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "abcd");
    editor.execute(Command::Undo).unwrap();
    select(&mut editor, 6, 1);
    editor
        .execute(Command::Delete {
            direction: Direction::Forward,
            smart: false,
        })
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "a");
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().selection(), Selection { anchor: 6, head: 1 });
}

#[test]
fn smart_backspace_and_tab_keep_tab_and_indent_width_independent() {
    let rules = CppStyle {
        indent_width: 3,
        tab_width: NonZeroUsize::new(8).unwrap(),
        tabs: TabPolicy::ForIndentation,
        ..Default::default()
    }
    .compile()
    .unwrap();
    let mut editor = Editor::new("\t  x", rules);
    select(&mut editor, 3, 3);
    editor
        .execute(Command::Delete {
            direction: Direction::Backward,
            smart: true,
        })
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "\t x"); // col 10 -> 9
    assert_eq!(editor.state().selection().head, 2);
    editor.execute(Command::InsertTab).unwrap();
    assert_eq!(editor.state().snapshot().text(), "\t \tx");
    let mut plain = Editor::new("a", soda::editor::Language::PlainText);
    select(&mut plain, 1, 1);
    plain.execute(Command::InsertTab).unwrap();
    assert_eq!(plain.state().snapshot().text(), "a   ");
    plain.execute(Command::InsertLiteralTab).unwrap();
    assert_eq!(plain.state().snapshot().text(), "a   \t");
}

#[test]
fn selected_line_indentation_excludes_next_line_at_selection_end() {
    let mut editor = Editor::new("a\r\nb\r\nc", soda::editor::Language::PlainText);
    select(&mut editor, 0, 6);
    editor
        .execute(Command::IndentSelection { outdent: false })
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "    a\r\n    b\r\nc");
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "a\r\nb\r\nc");
    editor
        .execute(Command::IndentSelection { outdent: true })
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "a\r\nb\r\nc");
}

#[test]
fn typing_history_joins_by_time_event_adjacency_and_session() {
    let mut editor = Editor::new("", soda::editor::Language::PlainText);
    let id = editor.model().default_session();
    for (time, ch) in [(0, 'a'), (100, 'b'), (700, 'c')] {
        editor
            .execute_at(id, Command::TypeChar(ch), Duration::from_millis(time))
            .unwrap();
    }
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ab");
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "");
    editor.execute(Command::Redo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ab");
    let other = editor.add_session(Selection::caret(0)).unwrap();
    editor
        .execute_at(other, Command::TypeChar('x'), Duration::from_millis(800))
        .unwrap();
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ab");
}

#[test]
fn movement_paste_and_deletion_isolate_typing_history() {
    let mut editor = Editor::new("", soda::editor::Language::PlainText);
    editor.execute(Command::TypeChar('a')).unwrap();
    move_by(&mut editor, Motion::LineEnd, false);
    editor.execute(Command::TypeChar('b')).unwrap();
    editor.execute(Command::InsertText("paste".into())).unwrap();
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ab");
    editor
        .execute(Command::Delete {
            direction: Direction::Backward,
            smart: false,
        })
        .unwrap();
    editor
        .execute(Command::Delete {
            direction: Direction::Backward,
            smart: false,
        })
        .unwrap();
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "ab");
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "a");
}

#[test]
fn search_state_is_session_local_and_replace_all_is_one_undo_unit() {
    let mut editor = Editor::new("界 a 界 a", soda::editor::Language::PlainText);
    let other = editor.add_session(Selection::caret(0)).unwrap();
    editor
        .execute(Command::SetSearchQuery(SearchQuery::new("界")))
        .unwrap();
    editor
        .execute(Command::Find {
            backward: false,
            wrap: true,
        })
        .unwrap();
    assert_eq!(editor.state().selection(), Selection { anchor: 0, head: 3 });
    editor
        .execute(Command::Find {
            backward: false,
            wrap: true,
        })
        .unwrap();
    assert_eq!(editor.state().selection(), Selection { anchor: 6, head: 9 });
    assert!(
        editor
            .model()
            .session(other)
            .unwrap()
            .search()
            .query()
            .is_none()
    );
    editor.execute(Command::ReplaceAll("文".into())).unwrap();
    assert_eq!(editor.state().snapshot().text(), "文 a 文 a");
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "界 a 界 a");
    editor.execute(Command::ReplaceCurrent("x".into())).unwrap();
    assert_eq!(editor.state().snapshot().text(), "界 a x a");
}

#[test]
fn search_cursor_handles_chunk_boundaries_and_nonoverlapping_matches() {
    let text = "ab界".repeat(4000);
    let state = soda::core::EditorState::new(text.clone());
    let query = SearchQuery::new("界ab界");
    let found: Vec<_> = query.cursor(state.snapshot()).collect();
    let expected: Vec<_> = text
        .match_indices(query.text())
        .map(|(offset, text)| offset..offset + text.len())
        .collect();
    assert_eq!(found, expected);
    assert_eq!(SearchQuery::new("").cursor(state.snapshot()).count(), 0);
}

#[test]
fn deletion_from_inside_a_grapheme_consumes_the_whole_cluster() {
    for direction in [Direction::Backward, Direction::Forward] {
        let mut editor = Editor::new("e\u{301}x", soda::editor::Language::PlainText);
        select(&mut editor, 1, 1);
        editor
            .execute(Command::Delete {
                direction,
                smart: false,
            })
            .unwrap();
        assert_eq!(editor.state().snapshot().text(), "x");
        assert_eq!(editor.state().selection(), Selection::caret(0));
    }
}
