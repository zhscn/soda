//! Where things are in the text: grapheme steps, words and symbols, lines,
//! and the bounds of what `,` and `.` select. Positions are byte offsets
//! between characters.
use crate::core::{ByteOffset, Snapshot, step_grapheme};
use std::ops::Range;

/// Lines the caret can reach: the empty one after a final newline too.
pub(crate) fn lines(text: &Snapshot) -> usize {
    text.line_count()
}
pub(crate) fn next(text: &Snapshot, offset: usize) -> usize {
    step_grapheme(text, ByteOffset(offset), true).unwrap().0
}
pub(crate) fn prev(text: &Snapshot, offset: usize) -> usize {
    step_grapheme(text, ByteOffset(offset), false).unwrap().0
}
/// The first non-blank of a line, or its end.
pub(crate) fn first(text: &Snapshot, line: usize) -> usize {
    let range = text.line_content_range(line).unwrap();
    let content = text.byte_slice(range.clone()).unwrap().to_string();
    range.start + content.len() - content.trim_start_matches([' ', '\t']).len()
}
pub(crate) fn char_at(text: &Snapshot, offset: usize) -> Option<char> {
    if offset >= text.len_bytes() {
        return None;
    }
    text.byte_slice(offset..next(text, offset))?.chars().next()
}
fn wordy(ch: char, symbol: bool) -> bool {
    ch.is_alphanumeric() || (symbol && ch == '_')
}
fn is_thing(text: &Snapshot, offset: usize, symbol: bool) -> bool {
    char_at(text, offset).is_some_and(|ch| wordy(ch, symbol))
}
/// The end of the next word from `at`.
pub(crate) fn thing_end(text: &Snapshot, mut at: usize, symbol: bool) -> Option<usize> {
    while at < text.len_bytes() && !is_thing(text, at, symbol) {
        at = next(text, at);
    }
    if at >= text.len_bytes() {
        return None;
    }
    while is_thing(text, at, symbol) {
        at = next(text, at);
    }
    Some(at)
}
/// The start of the word before `at`.
pub(crate) fn thing_start(text: &Snapshot, mut at: usize, symbol: bool) -> Option<usize> {
    while at > 0 && !is_thing(text, prev(text, at), symbol) {
        at = prev(text, at);
    }
    if at == 0 {
        return None;
    }
    while at > 0 && is_thing(text, prev(text, at), symbol) {
        at = prev(text, at);
    }
    Some(at)
}
/// Blanks before `at`, no further back than `limit`: `w` takes the space
/// before a word, but stops at punctuation.
pub(crate) fn blanks_before(text: &Snapshot, mut at: usize, limit: usize) -> usize {
    while at > limit && char_at(text, prev(text, at)).is_some_and(|ch| ch == ' ' || ch == '\t') {
        at = prev(text, at);
    }
    at
}
/// Blanks after `at`, no further than `limit`: `b` takes the space after
/// a word, as `w` takes the one before.
pub(crate) fn blanks_after(text: &Snapshot, mut at: usize, limit: usize) -> usize {
    while at < limit && char_at(text, at).is_some_and(|ch| ch == ' ' || ch == '\t') {
        at = next(text, at);
    }
    at
}
/// The word or symbol at, before or after `at`, on its line.
pub(crate) fn thing_at(text: &Snapshot, at: usize, symbol: bool) -> Option<Range<usize>> {
    let line = text.line_of(at)?;
    let range = text.line_content_range(line)?;
    let mut start = at;
    // Right after a word counts as on it.
    if start > range.start
        && !is_thing(text, start, symbol)
        && is_thing(text, prev(text, start), symbol)
    {
        start = prev(text, start);
    }
    while start < range.end && !is_thing(text, start, symbol) {
        start = next(text, start);
    }
    if start >= range.end {
        return None;
    }
    while start > range.start && is_thing(text, prev(text, start), symbol) {
        start = prev(text, start);
    }
    let mut end = start;
    while end < range.end && is_thing(text, end, symbol) {
        end = next(text, end);
    }
    Some(start..end)
}
/// The start of the `count`th occurrence of a character from `at`.
pub(crate) fn find(
    text: &Snapshot,
    at: usize,
    ch: char,
    count: usize,
    backward: bool,
) -> Option<usize> {
    let mut position = at;
    let mut left = count;
    loop {
        if backward {
            if position == 0 {
                return None;
            }
            position = prev(text, position);
        } else if position >= text.len_bytes() {
            return None;
        }
        if char_at(text, position) == Some(ch) {
            left -= 1;
            if left == 0 {
                return Some(position);
            }
        }
        if !backward {
            position = next(text, position);
        }
    }
}
/// The string on the line around `at`, between quotes of any kind.
pub(crate) fn quoted(text: &Snapshot, at: usize, inner: bool) -> Option<Range<usize>> {
    let line = text.line_content_range(text.line_of(at)?)?;
    let mut open: Option<(usize, char)> = None;
    let mut position = line.start;
    let mut escaped = false;
    while position < line.end {
        let ch = char_at(text, position)?;
        let after = next(text, position);
        match open {
            Some((start, quote)) if ch == quote && !escaped => {
                if at <= position {
                    return Some(if inner {
                        next(text, start)..position
                    } else {
                        start..after
                    });
                }
                open = None;
            }
            None if matches!(ch, '"' | '\'' | '`') && !escaped => open = Some((position, ch)),
            _ => {}
        }
        escaped = ch == '\\' && !escaped;
        position = after;
    }
    None
}
/// The lines of text around `at`, up to the blank lines on either side.
pub(crate) fn paragraph(text: &Snapshot, at: usize, inner: bool) -> Option<Range<usize>> {
    let last = lines(text) - 1;
    let line = text.line_of(at)?.min(last);
    let blank = |line: usize| first(text, line) == text.line_content_range(line).unwrap().end;
    if blank(line) {
        return None;
    }
    let mut start = line;
    while start > 0 && !blank(start - 1) {
        start -= 1;
    }
    let mut end = line;
    while end < last && !blank(end + 1) {
        end += 1;
    }
    if !inner {
        while end < last && blank(end + 1) {
            end += 1;
        }
    }
    Some(text.line_start(start)?..text.line_content_range(end)?.end)
}
