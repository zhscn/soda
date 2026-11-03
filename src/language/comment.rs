//! What continues a comment on the line Enter opens, whatever lexed it.
use crate::core::Snapshot;
use std::ops::Range;

/// A comment as a lexer found it.
#[derive(Clone, Debug)]
pub struct Comment {
    pub range: Range<usize>,
    pub block: bool,
    pub unterminated: bool,
}

/// What continues a comment that Enter at `position` splits or ends: the
/// marker of a line comment that starts its line, or the `*` of a block
/// comment whose lines start with one. Comments after code end with the
/// line.
pub fn continuation(
    snapshot: &Snapshot,
    comment: Option<Comment>,
    position: usize,
) -> &'static str {
    let Some(token) = comment else {
        return "";
    };
    // Slices only: the whole text may not be materialized.
    let slice = |range: Range<usize>| snapshot.byte_slice(range).unwrap().to_string();
    let line = snapshot.line_of(position).unwrap();
    let line_start = snapshot.line_start(line).unwrap();
    let line_end = snapshot.line_content_range(line).unwrap().end;
    let before = slice(line_start..position);
    let after = slice(position..line_end);
    let lead = |start: usize| start >= line_start && slice(line_start..start).trim().is_empty();
    // Markers are ASCII; a longer prefix may end inside a character.
    let mut head = token.range.end.min(token.range.start + 4);
    while !snapshot.is_char_boundary(head) {
        head -= 1;
    }
    let text = slice(token.range.start..head);
    if !token.block {
        if !lead(token.range.start) {
            return "";
        }
        let marker = ["/// ", "//! ", "// ", "///", "//!", "//"]
            .into_iter()
            .find(|marker| text.starts_with(marker))
            .unwrap();
        if position < token.range.start + marker.len().min(text.len()) {
            return "";
        }
        return marker;
    }
    if position <= token.range.start + 1 || (position + 2 > token.range.end && !token.unterminated)
    {
        return "";
    }
    let closing = after.trim_start().starts_with("*/");
    let opening_line = snapshot.line_of(token.range.start) == Some(line);
    if opening_line {
        // The new line takes this line's indentation, one space short of
        // the stars below `/*`.
        match (lead(token.range.start), closing) {
            (false, _) => "",
            (true, true) => " ",
            (true, false) => " * ",
        }
    } else if before.trim_start().starts_with('*') {
        if closing { "" } else { "* " }
    } else {
        ""
    }
}
