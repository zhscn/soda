use super::language::LanguageSession;
use crate::core::{
    Change, EditError, EditorState, Selection, Transaction, column_at, column_width,
    position_at_column, step_grapheme,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Motion {
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
    goal: Option<usize>,
    language: &LanguageSession,
) -> Result<(Selection, Option<usize>), EditError> {
    let snapshot = state.snapshot();
    let selection = state.selection();
    let head = selection.head;
    let line = snapshot.line_of(head).unwrap();
    let vertical = matches!(motion, Motion::Up | Motion::Down);
    let goal = if vertical {
        Some(goal.unwrap_or(column_at(snapshot, head, language.whitespace().tab_width)?))
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
                step_grapheme(snapshot, head, motion == Motion::Forward)?
            }
            Motion::Up | Motion::Down => {
                let target = if motion == Motion::Up {
                    line.saturating_sub(1)
                } else {
                    (line + 1).min(snapshot.line_count() - 1)
                };
                position_at_column(
                    snapshot,
                    target,
                    goal.unwrap(),
                    language.whitespace().tab_width,
                )?
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
fn prefix(text: &str) -> &str {
    &text[..text
        .bytes()
        .take_while(|byte| matches!(byte, b' ' | b'\t'))
        .count()]
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
            let before = snapshot.byte_slice(start..position).unwrap().to_string();
            let width = language.whitespace().indent_width;
            if position > start && width > 0 && prefix(&before) == before {
                let column = column_width(&before, 0, language.whitespace().tab_width);
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
            position,
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
    Ok(tx)
}
pub(super) fn insert_tab(
    state: &EditorState,
    literal: bool,
    language: &LanguageSession,
) -> Transaction {
    let settings = language.whitespace();
    let column = column_at(
        state.snapshot(),
        state.selection().range().start,
        settings.tab_width,
    )
    .unwrap();
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
        let text = snapshot.line(line).unwrap();
        let old = prefix(&text);
        let column = column_width(old, 0, settings.tab_width);
        let target = if outdent {
            column.saturating_sub(settings.indent_width)
        } else {
            column + settings.indent_width
        };
        let inserted = whitespace(target, language);
        if old != inserted {
            let start = snapshot.line_start(line).unwrap();
            changes.push(Change::new(start..start + old.len(), inserted));
        }
    }
    Transaction::new(snapshot.version(), changes)
}
