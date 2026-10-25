use super::language::LanguageSession;
use crate::core::{
    ByteOffset, Change, EditError, EditorState, LogicalColumn, Selection, Transaction,
    logical_column_at, offset_at_logical_column, step_grapheme,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Motion {
    WordBackward,
    WordForward,
    Lines { backward: bool, count: usize },
    Backward,
    Forward,
    Up,
    Down,
    LineStart,
    LineEnd,
    DocumentStart,
    DocumentEnd,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Direction {
    Backward,
    Forward,
}

pub(super) fn move_selection(
    state: &EditorState,
    motion: Motion,
    extend: bool,
    goal: Option<LogicalColumn>,
    language: &LanguageSession,
) -> Result<(Selection, Option<LogicalColumn>), EditError> {
    let snapshot = state.snapshot();
    let selection = state.selection();
    let head = selection.head;
    let line = snapshot.line_of(head).unwrap();
    let vertical = matches!(motion, Motion::Up | Motion::Down | Motion::Lines { .. });
    let goal = if vertical {
        Some(match goal {
            Some(goal) => goal,
            None => logical_column_at(snapshot, ByteOffset(head), language.whitespace().tab_width)?,
        })
    } else {
        None
    };
    let position = if !extend
        && selection.anchor != head
        && matches!(motion, Motion::Backward | Motion::Forward)
    {
        if motion == Motion::Backward {
            selection.range().start
        } else {
            selection.range().end
        }
    } else {
        match motion {
            Motion::Backward | Motion::Forward => {
                step_grapheme(snapshot, ByteOffset(head), motion == Motion::Forward)?.0
            }
            Motion::WordBackward | Motion::WordForward => {
                crate::core::word_boundary(
                    snapshot,
                    ByteOffset(head),
                    motion == Motion::WordBackward,
                )?
                .0
            }
            Motion::Up | Motion::Down | Motion::Lines { .. } => {
                let (backward, count) = match motion {
                    Motion::Up => (true, 1),
                    Motion::Down => (false, 1),
                    Motion::Lines { backward, count } => (backward, count),
                    _ => unreachable!(),
                };
                let target = if backward {
                    line.saturating_sub(count)
                } else {
                    line.saturating_add(count).min(snapshot.line_count() - 1)
                };
                offset_at_logical_column(
                    snapshot,
                    target,
                    goal.unwrap(),
                    language.whitespace().tab_width,
                )?
                .0
            }
            Motion::LineStart => snapshot.line_start(line).unwrap(),
            Motion::LineEnd => snapshot.line_content_range(line).unwrap().end,
            Motion::DocumentStart => 0,
            Motion::DocumentEnd => snapshot.len_bytes(),
        }
    };
    Ok((
        if extend {
            Selection {
                anchor: selection.anchor,
                head: position,
            }
        } else {
            Selection::caret(position)
        },
        goal,
    ))
}
pub(super) fn delete_word(
    state: &EditorState,
    direction: Direction,
) -> Result<Transaction, EditError> {
    let mut range = state.selection().range();
    if range.is_empty() {
        let edge = crate::core::word_boundary(
            state.snapshot(),
            ByteOffset(range.start),
            direction == Direction::Backward,
        )?
        .0;
        range = crate::core::clip_grapheme_offset(
            state.snapshot(),
            ByteOffset(edge.min(range.start)),
            crate::core::Association::Before,
        )?
        .0
            ..crate::core::clip_grapheme_offset(
                state.snapshot(),
                ByteOffset(edge.max(range.start)),
                crate::core::Association::After,
            )?
            .0;
    }
    let changes = if range.is_empty() {
        vec![]
    } else {
        vec![Change::new(range.clone(), "")]
    };
    let mut tx = Transaction::new(state.snapshot().version(), changes);
    tx.selection = Some(Selection::caret(range.start));
    super::operations::normalize_caret(state, tx)
}
fn whitespace(target: usize, language: &LanguageSession) -> String {
    crate::language::materialize(target, 0, target, &language.whitespace())
}

pub(super) fn delete(
    state: &EditorState,
    direction: Direction,
    smart: bool,
    language: &LanguageSession,
) -> Result<Transaction, EditError> {
    let mut range = state.selection().range();
    if range.is_empty() {
        let position = range.start;
        if smart && direction == Direction::Backward {
            let snapshot = state.snapshot();
            let line = snapshot.line_of(position).unwrap();
            let start = snapshot.line_start(line).unwrap();
            let before = snapshot.byte_slice(start..position).unwrap();
            let width = language.whitespace().indent_width;
            if position > start
                && width > 0
                && before.bytes().all(|byte| matches!(byte, b' ' | b'\t'))
            {
                let column = logical_column_at(
                    snapshot,
                    ByteOffset(position),
                    language.whitespace().tab_width,
                )?
                .0;
                let target = column.saturating_sub(1) / width * width;
                let inserted = whitespace(target, language);
                let mut tx = Transaction::new(
                    snapshot.version(),
                    vec![Change::new(start..position, inserted.clone())],
                );
                tx.selection = Some(Selection::caret(start + inserted.len()));
                return Ok(tx);
            }
        }
        range = crate::core::deletion_range(
            state.snapshot(),
            ByteOffset(position),
            direction == Direction::Forward,
        )?;
    }
    let mut tx = Transaction::new(
        state.snapshot().version(),
        if range.is_empty() {
            vec![]
        } else {
            vec![Change::new(range.clone(), "")]
        },
    );
    tx.selection = Some(Selection::caret(range.start));
    super::operations::normalize_caret(state, tx)
}
pub(super) fn insert_tab(
    state: &EditorState,
    literal: bool,
    language: &LanguageSession,
) -> Result<Transaction, EditError> {
    if literal {
        return super::operations::prepare_insert(state, "\t".into());
    }
    if !state.selection().range().is_empty() {
        return Ok(indent_selection(state, false, language));
    }
    let settings = language.whitespace();
    let position = state.selection().range().start;
    let line = state.snapshot().line_of(position).unwrap();
    let leading = state
        .snapshot()
        .byte_slice(state.snapshot().line_start(line).unwrap()..position)
        .unwrap()
        .bytes()
        .all(|byte| matches!(byte, b' ' | b'\t'));
    let use_tab = literal
        || settings.tabs == crate::language::TabPolicy::Always
        || (leading && settings.tabs != crate::language::TabPolicy::Never);
    let text = if use_tab {
        "\t".to_owned()
    } else {
        let column =
            logical_column_at(state.snapshot(), ByteOffset(position), settings.tab_width)?.0;
        " ".repeat(settings.tab_width.get() - column % settings.tab_width.get())
    };
    super::operations::prepare_insert(state, text)
}
pub(super) fn indent_selection(
    state: &EditorState,
    outdent: bool,
    language: &LanguageSession,
) -> Transaction {
    let snapshot = state.snapshot();
    let range = state.selection().range();
    let first = snapshot.line_of(range.start).unwrap();
    let mut last = snapshot.line_of(range.end).unwrap();
    if !range.is_empty() && last > first && snapshot.line_start(last) == Some(range.end) {
        last -= 1;
    }
    let settings = language.whitespace();
    if settings.indent_width == 0 {
        return Transaction::new(snapshot.version(), vec![]);
    }
    let mut changes = Vec::new();
    for line in first..=last {
        let old = snapshot.leading_whitespace(line).unwrap();
        let start = snapshot.line_start(line).unwrap();
        let column = logical_column_at(
            snapshot,
            ByteOffset(start + old.len_bytes()),
            settings.tab_width,
        )
        .unwrap()
        .0;
        let target = if outdent {
            column.saturating_sub(settings.indent_width)
        } else {
            column + settings.indent_width
        };
        let inserted = whitespace(target, language);
        if old != inserted {
            let start = snapshot.line_start(line).unwrap();
            changes.push(Change::new(start..start + old.len_bytes(), inserted));
        }
    }
    Transaction::new(snapshot.version(), changes)
}
