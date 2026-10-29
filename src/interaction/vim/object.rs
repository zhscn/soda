//! Text objects: ranges around the caret that operators and Visual mode
//! select as a whole (`iw`, `a"`, `i(`, `ap`).
use super::motion::{closing, is_blank, next, opening, prev};
use crate::core::Snapshot;
use std::ops::Range;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Object {
    /// `iw`/`aw`, or `iW`/`aW` when `big`.
    Word { big: bool, inner: bool },
    /// `i"`/`a"` and the other quotes, within one line.
    Quote { quote: char, inner: bool },
    /// `i(`/`a(` and the other brackets, across lines.
    Pair {
        open: char,
        close: char,
        inner: bool,
    },
    /// `ip`/`ap`, by lines.
    Paragraph { inner: bool },
}
impl Object {
    /// The object named by the key after `i` or `a`.
    pub(super) fn parse(ch: char, inner: bool) -> Option<Self> {
        Some(match ch {
            'w' | 'W' => Self::Word {
                big: ch == 'W',
                inner,
            },
            '"' | '\'' | '`' => Self::Quote { quote: ch, inner },
            '(' | ')' | 'b' => Self::Pair {
                open: '(',
                close: ')',
                inner,
            },
            '[' | ']' => Self::Pair {
                open: '[',
                close: ']',
                inner,
            },
            '{' | '}' | 'B' => Self::Pair {
                open: '{',
                close: '}',
                inner,
            },
            '<' | '>' => Self::Pair {
                open: '<',
                close: '>',
                inner,
            },
            'p' => Self::Paragraph { inner },
            _ => return None,
        })
    }
    pub(super) fn linewise(self) -> bool {
        matches!(self, Self::Paragraph { .. })
    }
}

fn char_at(text: &Snapshot, offset: usize) -> char {
    text.byte_slice(offset..next(text, offset))
        .and_then(|slice| slice.chars().next())
        .unwrap_or('\n')
}
fn class(text: &Snapshot, offset: usize, big: bool) -> u8 {
    let ch = char_at(text, offset);
    if ch.is_whitespace() {
        0
    } else if big || ch.is_alphanumeric() || ch == '_' {
        1
    } else {
        2
    }
}
/// The run of same-class characters around `at`, within `line`.
fn run(text: &Snapshot, line: &Range<usize>, at: usize, big: bool) -> Range<usize> {
    let kind = class(text, at, big);
    let mut start = at;
    while start > line.start && class(text, prev(text, start), big) == kind {
        start = prev(text, start);
    }
    let mut end = at;
    while end < line.end && class(text, end, big) == kind {
        end = next(text, end);
    }
    start..end
}

/// The object's byte range around `at`, and whether it covers whole lines.
pub(super) fn range(
    text: &Snapshot,
    at: usize,
    object: Object,
    count: usize,
) -> Option<Range<usize>> {
    match object {
        Object::Word { big, inner } => word(text, at, big, inner, count),
        Object::Quote { quote, inner } => quoted(text, at, quote, inner),
        Object::Pair { open, close, inner } => pair(text, at, open, close, inner, count),
        Object::Paragraph { inner } => paragraph(text, at, inner, count),
    }
}

fn word(text: &Snapshot, at: usize, big: bool, inner: bool, count: usize) -> Option<Range<usize>> {
    let line = text.line_content_range(text.line_of(at)?)?;
    if line.is_empty() {
        return None;
    }
    let first = run(text, &line, at, big);
    let mut end = first.end;
    let mut start = first.start;
    if inner {
        for _ in 1..count {
            if end >= line.end {
                break;
            }
            end = run(text, &line, end, big).end;
        }
        return Some(start..end);
    }
    let on_blank = is_blank(text, at);
    for index in 0..count {
        let from = if index == 0 {
            first.clone()
        } else {
            run(text, &line, end, big)
        };
        end = from.end;
        if end >= line.end {
            break;
        }
        // A word takes the blanks after it; blanks take the word after them.
        if is_blank(text, from.start) || is_blank(text, end) {
            end = run(text, &line, end, big).end;
        }
    }
    if !on_blank && !is_blank(text, prev(text, end).max(line.start)) && start > line.start {
        // No trailing blanks: take the ones before the word instead.
        let before = prev(text, start);
        if is_blank(text, before) {
            start = run(text, &line, before, big).start;
        }
    }
    Some(start..end)
}

fn quoted(text: &Snapshot, at: usize, quote: char, inner: bool) -> Option<Range<usize>> {
    let line = text.line_content_range(text.line_of(at)?)?;
    let mut quotes = vec![];
    let mut position = line.start;
    let mut escaped = false;
    while position < line.end {
        let ch = char_at(text, position);
        if ch == quote && !escaped {
            quotes.push(position);
        }
        escaped = ch == '\\' && !escaped;
        position = next(text, position);
    }
    let (open, close) = if let Some(index) = quotes.iter().position(|q| *q == at) {
        // On a quote, pairs count from the start of the line.
        if index % 2 == 0 {
            (at, *quotes.get(index + 1)?)
        } else {
            (quotes[index - 1], at)
        }
    } else {
        match quotes.iter().rev().find(|q| **q < at) {
            Some(before) => (*before, *quotes.iter().find(|q| **q > at)?),
            None => {
                let mut after = quotes.iter().filter(|q| **q > at);
                (*after.next()?, *after.next()?)
            }
        }
    };
    if inner {
        return Some(next(text, open)..close);
    }
    let mut end = next(text, close);
    let mut start = open;
    if end < line.end && is_blank(text, end) {
        end = run(text, &line, end, false).end;
    } else if start > line.start && is_blank(text, prev(text, start)) {
        start = run(text, &line, prev(text, start), false).start;
    }
    Some(start..end)
}

fn pair(
    text: &Snapshot,
    at: usize,
    open: char,
    close: char,
    inner: bool,
    count: usize,
) -> Option<Range<usize>> {
    let mut start = match char_at(text, at) {
        ch if ch == open => at,
        ch if ch == close => opening(text, at, open, close)?,
        // Outside any pair, the next one on the line.
        _ => enclosing(text, at, open, close).or_else(|| {
            let end = text.line_content_range(text.line_of(at)?)?.end;
            let mut position = at;
            while position < end && char_at(text, position) != open {
                position = next(text, position);
            }
            (position < end && count == 1).then_some(position)
        })?,
    };
    for _ in 1..count {
        start = enclosing(text, start, open, close)?;
    }
    let end = closing(text, start, open, close)?;
    if !inner {
        return Some(start..next(text, end));
    }
    let mut inside = next(text, start)..end;
    // Brackets on lines of their own leave those lines in place.
    let rest = text.byte_slice(inside.clone())?.to_string();
    if let Some(after) = rest
        .strip_prefix('\n')
        .or_else(|| rest.strip_prefix("\r\n"))
    {
        inside.start = end - after.len();
        let close_line = text.line_start(text.line_of(end)?)?;
        let before_close = text.byte_slice(close_line..end)?.to_string();
        if close_line > inside.start && before_close.trim().is_empty() {
            inside.end = close_line;
        }
    }
    Some(inside)
}
/// The nearest unmatched `open` before `at`.
fn enclosing(text: &Snapshot, at: usize, open: char, close: char) -> Option<usize> {
    let mut depth = 0usize;
    let mut position = at;
    while position > 0 {
        position = prev(text, position);
        let ch = char_at(text, position);
        if ch == close {
            depth += 1;
        } else if ch == open {
            if depth == 0 {
                return Some(position);
            }
            depth -= 1;
        }
    }
    None
}

fn paragraph(text: &Snapshot, at: usize, inner: bool, count: usize) -> Option<Range<usize>> {
    let last = super::motion::lines(text) - 1;
    let blank = |line: usize| {
        text.byte_slice(text.line_content_range(line).unwrap())
            .unwrap()
            .to_string()
            .trim()
            .is_empty()
    };
    let line = text.line_of(at)?.min(last);
    let mut first = line;
    while first > 0 && blank(first - 1) == blank(line) {
        first -= 1;
    }
    let mut end = line;
    let mut blocks = if inner { count } else { count * 2 };
    loop {
        let kind = blank(end);
        while end < last && blank(end + 1) == kind {
            end += 1;
        }
        blocks -= 1;
        if blocks == 0 || end == last {
            break;
        }
        end += 1;
    }
    if !inner && blocks > 0 && !blank(line) {
        // No blank lines follow: take the ones before the paragraph.
        while first > 0 && blank(first - 1) {
            first -= 1;
        }
    }
    Some(text.line_start(first)?..text.line_range(end)?.end)
}
