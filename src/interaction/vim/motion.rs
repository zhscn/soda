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
    /// `f`, `t`, `F`, `T` within the line.
    Find(Find),
    /// `;` and `,`: the last find, the same or the opposite way.
    RepeatFind {
        reverse: bool,
    },
    /// `%`: the bracket matching the first one at or after the caret.
    MatchPair,
    /// `}` and `{`: the next or previous empty line.
    Paragraph {
        forward: bool,
    },
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Find {
    pub ch: char,
    /// Stops before the character (`t`, `T`).
    pub till: bool,
    pub backward: bool,
    /// Repeated by `;` or `,`: `t` and `T` skip an adjacent match.
    pub repeat: bool,
}
/// How an operator extends over a motion.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Kind {
    Exclusive,
    Inclusive,
    Linewise,
}
pub(super) fn kind(motion: Motion) -> Kind {
    match motion {
        Motion::Up | Motion::Down | Motion::Top | Motion::Bottom => Kind::Linewise,
        Motion::End | Motion::EndWord | Motion::MatchPair => Kind::Inclusive,
        Motion::Find(find) if !find.backward => Kind::Inclusive,
        _ => Kind::Exclusive,
    }
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
) -> Option<usize> {
    let line = text.line_of(at).unwrap().min(lines(text) - 1);
    let range = text.line_content_range(line).unwrap();
    if !matches!(motion, Motion::Up | Motion::Down) {
        *goal = None;
    }
    Some(match motion {
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
        Motion::Find(target) => find(text, at, target, count)?,
        Motion::MatchPair => match_pair(text, at)?,
        Motion::Paragraph { forward } => paragraph(text, at, forward, count),
        Motion::RepeatFind { .. } => unreachable!("resolved by the caller"),
    })
}
fn char_at(text: &Snapshot, offset: usize) -> Option<char> {
    text.byte_slice(offset..next(text, offset))?.chars().next()
}
/// The `count`th occurrence of a character on the caret's line.
pub(super) fn find(text: &Snapshot, at: usize, target: Find, count: usize) -> Option<usize> {
    let line = text.line_of(at)?;
    let range = text.line_content_range(line)?;
    let mut position = at;
    // A repeated `t` would stop where it already is; look one further.
    if target.till && target.repeat {
        position = if target.backward {
            prev(text, position).max(range.start)
        } else {
            next(text, position).min(range.end)
        };
    }
    for _ in 0..count {
        loop {
            if target.backward {
                if position <= range.start {
                    return None;
                }
                position = prev(text, position);
            } else {
                position = next(text, position);
                if position >= range.end {
                    return None;
                }
            }
            if char_at(text, position) == Some(target.ch) {
                break;
            }
        }
    }
    Some(match (target.till, target.backward) {
        (false, _) => position,
        (true, false) => prev(text, position),
        (true, true) => next(text, position),
    })
}
const PAIRS: [(char, char); 3] = [('(', ')'), ('[', ']'), ('{', '}')];
/// The bracket matching the first one at or after `at` on its line.
fn match_pair(text: &Snapshot, at: usize) -> Option<usize> {
    let end = text.line_content_range(text.line_of(at)?)?.end;
    let mut position = at;
    while position < end {
        let ch = char_at(text, position)?;
        if let Some((open, close)) = PAIRS.iter().find(|(o, c)| *o == ch || *c == ch) {
            return if ch == *open {
                closing(text, position, *open, *close)
            } else {
                opening(text, position, *open, *close)
            };
        }
        position = next(text, position);
    }
    None
}
/// The bracket closing the one opened at `open_at`.
pub(super) fn closing(text: &Snapshot, open_at: usize, open: char, close: char) -> Option<usize> {
    let mut depth = 0usize;
    let mut position = open_at;
    while position < text.len_bytes() {
        let ch = char_at(text, position)?;
        if ch == open {
            depth += 1;
        } else if ch == close {
            depth -= 1;
            if depth == 0 {
                return Some(position);
            }
        }
        position = next(text, position);
    }
    None
}
/// The bracket opening the one closed at `close_at`.
pub(super) fn opening(text: &Snapshot, close_at: usize, open: char, close: char) -> Option<usize> {
    let mut depth = 0usize;
    let mut position = close_at;
    loop {
        let ch = char_at(text, position)?;
        if ch == close {
            depth += 1;
        } else if ch == open {
            depth -= 1;
            if depth == 0 {
                return Some(position);
            }
        }
        if position == 0 {
            return None;
        }
        position = prev(text, position);
    }
}
pub(super) fn is_empty_line(text: &Snapshot, line: usize) -> bool {
    text.line_content_range(line).unwrap().is_empty()
}
/// The start of the `count`th empty line after (or before) the caret's
/// paragraph; the buffer's last character or first byte when none is left.
fn paragraph(text: &Snapshot, at: usize, forward: bool, count: usize) -> usize {
    let last = lines(text) - 1;
    let mut line = text.line_of(at).unwrap().min(last);
    for _ in 0..count {
        if forward {
            while line < last && is_empty_line(text, line) {
                line += 1;
            }
            while line < last && !is_empty_line(text, line) {
                line += 1;
            }
            if line == last && !is_empty_line(text, line) {
                return clamp(text, text.line_content_range(line).unwrap().end);
            }
        } else {
            while line > 0 && is_empty_line(text, line) {
                line -= 1;
            }
            while line > 0 && !is_empty_line(text, line) {
                line -= 1;
            }
        }
    }
    text.line_start(line).unwrap()
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
/// The keyword under or after `at` on its line, for `*` and `#`.
pub(super) fn keyword_at(text: &Snapshot, at: usize) -> Option<std::ops::Range<usize>> {
    let end = text.line_content_range(text.line_of(at)?)?.end;
    let mut start = at;
    while start < end && class(text, start) != 1 {
        start = next(text, start);
    }
    if start >= end {
        return None;
    }
    let line_start = text.line_start(text.line_of(at)?)?;
    while start > line_start && class(text, prev(text, start)) == 1 {
        start = prev(text, start);
    }
    let mut stop = start;
    while stop < end && class(text, stop) == 1 {
        stop = next(text, stop);
    }
    Some(start..stop)
}
