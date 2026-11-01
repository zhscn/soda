//! The balanced structure of text: what a language tells commands about
//! brackets and the items between them, whatever parses it. Commands ask
//! these two questions and know nothing of parsers or grammars.
//!
//! An item is a word, a literal, a comment, a directive or a whole bracket
//! group; punctuation between items belongs to none. Where structure is
//! unknown, as at a bracket with no partner, the answer is `None`, and a
//! command does what it would do without structure.
//!
//! This file also answers for languages with no parser, from the text and
//! the literals of each line.
use crate::core::Snapshot;
use std::ops::Range;

/// Lines one question may read; a further partner counts as missing.
const LINE_LIMIT: usize = 20_000;

/// A balanced pair of delimiters.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Group {
    pub open: Range<usize>,
    pub close: Range<usize>,
}
impl Group {
    pub fn range(&self) -> Range<usize> {
        self.open.start..self.close.end
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ItemKind {
    Group,
    Atom,
    Literal,
    Comment,
    Directive,
}
impl ItemKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Group => "group",
            Self::Atom => "atom",
            Self::Literal => "literal",
            Self::Comment => "comment",
            Self::Directive => "directive",
        }
    }
}
/// An item, cut at the position asked about if that is inside it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Item {
    pub range: Range<usize>,
    pub kind: ItemKind,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Side {
    Before,
    After,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum Piece {
    Open(usize),
    Close(usize),
    Item(ItemKind),
}
/// Walks text as pieces. Each line is cut on its own: `literals` gives the
/// literal and comment spans of a line, relative to its start.
pub(crate) struct Scanner<'a, F> {
    pub snapshot: &'a Snapshot,
    /// Delimiters, one character each.
    pub brackets: &'a [(char, char)],
    pub literals: F,
}
impl<F: FnMut(usize) -> Vec<(Range<usize>, ItemKind)>> Scanner<'_, F> {
    fn pieces(&mut self, line: usize) -> Vec<(Range<usize>, Piece)> {
        let start = self.snapshot.line_start(line).unwrap_or(0);
        let text = self.snapshot.line(line).unwrap_or_default().into_owned();
        let spans = (self.literals)(line);
        let mut pieces = vec![];
        let mut chars = text.char_indices().peekable();
        while let Some((at, ch)) = chars.next() {
            if let Some((span, kind)) = spans.iter().find(|(span, _)| span.contains(&at)) {
                pieces.push(((start + at)..(start + span.end), Piece::Item(*kind)));
                while chars.next_if(|(next, _)| *next < span.end).is_some() {}
            } else if let Some(index) = self.brackets.iter().position(|(open, _)| *open == ch) {
                pieces.push(((start + at)..(start + at + 1), Piece::Open(index)));
            } else if let Some(index) = self.brackets.iter().position(|(_, close)| *close == ch) {
                pieces.push(((start + at)..(start + at + 1), Piece::Close(index)));
            } else if ch.is_alphanumeric() || ch == '_' {
                let mut end = at + ch.len_utf8();
                while let Some((next, ch)) = chars.next_if(|(next, ch)| {
                    (ch.is_alphanumeric() || *ch == '_')
                        && !spans.iter().any(|(span, _)| span.contains(next))
                }) {
                    end = next + ch.len_utf8();
                }
                pieces.push(((start + at)..(start + end), Piece::Item(ItemKind::Atom)));
            }
        }
        pieces
    }
    /// Calls `visit` on the pieces after `at` until it returns something;
    /// a piece that `at` is inside comes cut.
    fn forward<T>(
        &mut self,
        at: usize,
        mut visit: impl FnMut(Range<usize>, Piece) -> Option<Option<T>>,
    ) -> Option<T> {
        let first = self.snapshot.line_of(at)?;
        let last = self.snapshot.line_count().min(first + LINE_LIMIT);
        for line in first..last {
            for (range, piece) in self.pieces(line) {
                if range.end > at
                    && let Some(answer) = visit(range.start.max(at)..range.end, piece)
                {
                    return answer;
                }
            }
        }
        None
    }
    fn backward<T>(
        &mut self,
        at: usize,
        mut visit: impl FnMut(Range<usize>, Piece) -> Option<Option<T>>,
    ) -> Option<T> {
        let first = self.snapshot.line_of(at)?;
        for line in (first.saturating_sub(LINE_LIMIT)..=first).rev() {
            for (range, piece) in self.pieces(line).into_iter().rev() {
                if range.start < at
                    && let Some(answer) = visit(range.start..range.end.min(at), piece)
                {
                    return answer;
                }
            }
        }
        None
    }
    /// The closer of what is open at `at`, where `open` is the list of
    /// indices waiting for one, innermost last.
    fn closing(&mut self, at: usize, mut open: Vec<usize>) -> Option<Range<usize>> {
        self.forward(at, |range, piece| match piece {
            Piece::Open(index) => {
                open.push(index);
                None
            }
            Piece::Close(index) if open.last() != Some(&index) => Some(None),
            Piece::Close(_) => {
                open.pop();
                open.is_empty().then_some(Some(range))
            }
            Piece::Item(_) => None,
        })
    }
    fn opening(&mut self, at: usize, mut close: Vec<usize>) -> Option<Range<usize>> {
        self.backward(at, |range, piece| match piece {
            Piece::Close(index) => {
                close.push(index);
                None
            }
            Piece::Open(index) if close.last() != Some(&index) => Some(None),
            Piece::Open(_) => {
                close.pop();
                close.is_empty().then_some(Some(range))
            }
            Piece::Item(_) => None,
        })
    }
    pub fn enclosing(&mut self, at: usize) -> Option<Group> {
        let mut close = vec![];
        let (open, index) = self.backward(at, |range, piece| match piece {
            Piece::Close(index) => {
                close.push(index);
                None
            }
            Piece::Open(index) => match close.pop() {
                None => Some(Some((range, index))),
                Some(waiting) if waiting == index => None,
                Some(_) => Some(None),
            },
            Piece::Item(_) => None,
        })?;
        let close = self.closing(at, vec![index])?;
        Some(Group { open, close })
    }
    pub fn item(&mut self, at: usize, side: Side) -> Option<Item> {
        let piece = match side {
            Side::After => self.forward(at, |range, piece| Some(Some((range, piece)))),
            Side::Before => self.backward(at, |range, piece| Some(Some((range, piece)))),
        }?;
        match (piece, side) {
            ((range, Piece::Item(kind)), _) => Some(Item { range, kind }),
            ((open, Piece::Open(index)), Side::After) => Some(Item {
                range: open.start..self.closing(open.end, vec![index])?.end,
                kind: ItemKind::Group,
            }),
            ((close, Piece::Close(index)), Side::Before) => Some(Item {
                range: self.opening(close.start, vec![index])?.start..close.end,
                kind: ItemKind::Group,
            }),
            _ => None,
        }
    }
}
