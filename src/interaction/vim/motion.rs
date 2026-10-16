//! Vim motion endpoints are distinct from operator ranges and core selections.
use crate::core::{ByteOffset, Snapshot, step_grapheme};
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Motion {
    Left,
    Right,
    Up,
    Down,
    Start,
    First,
    End,
    Word,
    BackWord,
    EndWord,
    Top,
    Bottom,
}
pub(super) fn lines(text: &Snapshot) -> usize {
    let count = text.line_count();
    if count > 1 && text.line_start(count - 1) == Some(text.len_bytes()) {
        count - 1
    } else {
        count
    }
}
pub(super) fn next(text: &Snapshot, offset: usize) -> usize {
    step_grapheme(text, ByteOffset(offset), true).unwrap().0
}
pub(super) fn prev(text: &Snapshot, offset: usize) -> usize {
    step_grapheme(text, ByteOffset(offset), false).unwrap().0
}
pub(super) fn clamp(text: &Snapshot, offset: usize) -> usize {
    let line = text
        .line_of(offset.min(text.len_bytes()))
        .unwrap()
        .min(lines(text) - 1);
    let range = text.line_content_range(line).unwrap();
    if offset >= range.end && !range.is_empty() {
        prev(text, range.end)
    } else {
        offset.clamp(range.start, range.end)
    }
}
pub(super) fn first(text: &Snapshot, line: usize) -> usize {
    let range = text.line_content_range(line).unwrap();
    let content = text.byte_slice(range.clone()).unwrap().to_string();
    range.start + content.len() - content.trim_start_matches([' ', '\t']).len()
}
fn class(text: &Snapshot, offset: usize) -> u8 {
    if offset >= text.len_bytes() {
        return 0;
    }
    let c = text
        .byte_slice(offset..next(text, offset))
        .unwrap()
        .chars()
        .next()
        .unwrap();
    if c.is_whitespace() {
        0
    } else if c.is_alphanumeric() || c == '_' {
        1
    } else {
        2
    }
}
pub(super) fn word(text: &Snapshot, mut at: usize, motion: Motion, count: usize) -> usize {
    for _ in 0..count {
        match motion {
            Motion::Word => {
                let kind = class(text, at);
                while at < text.len_bytes() && class(text, at) == kind {
                    at = next(text, at);
                }
                while at < text.len_bytes() && class(text, at) == 0 {
                    let line = text.line_of(at).unwrap();
                    if text.line_content_range(line).unwrap().is_empty()
                        && text.line_start(line) == Some(at)
                    {
                        break;
                    }
                    at = next(text, at);
                }
            }
            Motion::BackWord => {
                at = prev(text, at);
                while at > 0 && class(text, at) == 0 {
                    at = prev(text, at);
                }
                let kind = class(text, at);
                while at > 0 && class(text, prev(text, at)) == kind {
                    at = prev(text, at);
                }
            }
            Motion::EndWord => {
                at = next(text, at);
                while at < text.len_bytes() && class(text, at) == 0 {
                    at = next(text, at);
                }
                let kind = class(text, at);
                while at < text.len_bytes() && class(text, next(text, at)) == kind {
                    at = next(text, at);
                }
            }
            _ => unreachable!(),
        }
    }
    at
}
pub(super) fn endpoint(
    text: &Snapshot,
    at: usize,
    motion: Motion,
    count: usize,
    goal: &mut Option<crate::core::LogicalColumn>,
    tab_width: std::num::NonZeroUsize,
) -> usize {
    let line = text.line_of(at).unwrap().min(lines(text) - 1);
    let range = text.line_content_range(line).unwrap();
    if !matches!(motion, Motion::Up | Motion::Down) {
        *goal = None;
    }
    match motion {
        Motion::Left => {
            let mut out = at;
            for _ in 0..count {
                out = prev(text, out).max(range.start);
            }
            out
        }
        Motion::Right => {
            let mut out = at;
            for _ in 0..count {
                out = next(text, out).min(range.end);
            }
            clamp(text, out)
        }
        Motion::Up | Motion::Down => {
            let column = *goal.get_or_insert_with(|| {
                crate::core::logical_column_at(text, ByteOffset(at), tab_width).unwrap()
            });
            let target = if motion == Motion::Up {
                line.saturating_sub(count)
            } else {
                line.saturating_add(count).min(lines(text) - 1)
            };
            clamp(
                text,
                crate::core::offset_at_logical_column(text, target, column, tab_width)
                    .unwrap()
                    .0,
            )
        }
        Motion::Start => range.start,
        Motion::First => clamp(text, first(text, line)),
        Motion::End => {
            let target = (line + count - 1).min(lines(text) - 1);
            let end = text.line_content_range(target).unwrap().end;
            clamp(text, end)
        }
        Motion::Top | Motion::Bottom => clamp(text, first(text, (count - 1).min(lines(text) - 1))),
        Motion::Word | Motion::BackWord | Motion::EndWord => {
            clamp(text, word(text, at, motion, count))
        }
    }
}
pub(super) fn change_word_end(text: &Snapshot, mut at: usize, count: usize) -> usize {
    for i in 0..count {
        if i > 0 {
            at = next(text, at);
            while at < text.len_bytes() && class(text, at) == 0 {
                at = next(text, at);
            }
        }
        let kind = class(text, at);
        while at < text.len_bytes() && class(text, next(text, at)) == kind {
            let next = next(text, at);
            if next == at {
                break;
            }
            at = next;
        }
    }
    at
}
pub(super) fn is_blank(text: &Snapshot, at: usize) -> bool {
    class(text, at) == 0
}
