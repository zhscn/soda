//! Literal search queries and snapshot cursors, independent of UI and parsers.
use crate::core::Snapshot;
use std::ops::Range;

#[derive(Clone, Debug)]
pub struct SearchQuery {
    text: String,
    /// Matches only where no word character touches either end.
    whole_word: bool,
    finder: std::sync::Arc<memchr::memmem::Finder<'static>>,
}
impl SearchQuery {
    pub fn new(text: impl Into<String>) -> Self {
        let text = text.into();
        let finder = std::sync::Arc::new(memchr::memmem::Finder::new(text.as_bytes()).into_owned());
        Self {
            text,
            whole_word: false,
            finder,
        }
    }
    /// A query for `text` as a whole word, as Vim's `*` searches.
    pub fn word(text: impl Into<String>) -> Self {
        Self {
            whole_word: true,
            ..Self::new(text)
        }
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn is_valid(&self) -> bool {
        !self.text.is_empty()
    }
    pub fn cursor<'a>(&'a self, snapshot: &'a Snapshot) -> SearchCursor<'a> {
        SearchCursor {
            query: self,
            snapshot,
            chunks: Box::new(snapshot.chunks()),
            buffer: Vec::new(),
            base: 0,
            scan: 0,
        }
    }
}
pub struct SearchCursor<'a> {
    query: &'a SearchQuery,
    snapshot: &'a Snapshot,
    chunks: Box<dyn Iterator<Item = &'a str> + 'a>,
    buffer: Vec<u8>,
    base: usize,
    scan: usize,
}
impl Iterator for SearchCursor<'_> {
    type Item = Range<usize>;
    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let found = self.next_literal()?;
            if !self.query.whole_word || self.is_word_boundary(&found) {
                return Some(found);
            }
        }
    }
}
impl SearchCursor<'_> {
    fn is_word_boundary(&self, found: &Range<usize>) -> bool {
        let word = |range: Range<usize>| {
            self.snapshot
                .byte_slice(range)
                .and_then(|slice| slice.chars().next())
                .is_some_and(|ch| ch.is_alphanumeric() || ch == '_')
        };
        let before =
            crate::core::step_grapheme(self.snapshot, crate::core::ByteOffset(found.start), false)
                .map_or(found.start, |offset| offset.0);
        let after =
            crate::core::step_grapheme(self.snapshot, crate::core::ByteOffset(found.end), true)
                .map_or(found.end, |offset| offset.0);
        !(before < found.start && word(before..found.start))
            && !(after > found.end && word(found.end..after))
    }
    fn next_literal(&mut self) -> Option<Range<usize>> {
        if !self.query.is_valid() {
            return None;
        }
        loop {
            if let Some(offset) = self.query.finder.find(&self.buffer[self.scan..]) {
                let start = self.scan + offset;
                self.scan = start + self.query.text.len();
                return Some(self.base + start..self.base + self.scan);
            }
            let chunk = self.chunks.next()?;
            let keep = self.query.text.len() - 1;
            let discard = self.scan.max(self.buffer.len().saturating_sub(keep));
            self.buffer.drain(..discard);
            self.base += discard;
            self.scan = 0;
            self.buffer.extend_from_slice(chunk.as_bytes());
        }
    }
}
#[derive(Clone, Debug, Default)]
pub struct SearchState {
    pub(super) query: Option<SearchQuery>,
}
impl SearchState {
    pub fn query(&self) -> Option<&SearchQuery> {
        self.query.as_ref()
    }
}

pub(super) fn find(
    snapshot: &Snapshot,
    query: &SearchQuery,
    range: Range<usize>,
    backward: bool,
    wrap: bool,
) -> Option<Range<usize>> {
    if backward {
        query
            .cursor(snapshot)
            .filter(|found| found.end <= range.start)
            .last()
            .or_else(|| {
                if wrap {
                    query.cursor(snapshot).last()
                } else {
                    None
                }
            })
    } else {
        query
            .cursor(snapshot)
            .find(|found| found.start >= range.end)
            .or_else(|| {
                if wrap {
                    query.cursor(snapshot).next()
                } else {
                    None
                }
            })
    }
}
