//! Search queries and snapshot cursors, independent of UI and parsers.
//! Patterns are regular expressions matched within lines, ignoring case
//! unless they contain a capital, as kakoune does.
use crate::core::Snapshot;
use regex::{Regex, RegexBuilder};
use std::{collections::VecDeque, ops::Range};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Whole {
    Word,
    Symbol,
}
#[derive(Clone, Debug)]
pub struct SearchQuery {
    text: String,
    /// Matches only where nothing of the same kind touches either end:
    /// letters and digits for a word, and underscores too for a symbol.
    whole: Option<Whole>,
    regex: Result<Regex, String>,
}
/// Whether a pattern asks for exact case: a capital that is not an escape
/// such as `\S` or `\W`.
fn has_capital(pattern: &str) -> bool {
    let mut chars = pattern.chars();
    while let Some(ch) = chars.next() {
        match ch {
            '\\' => {
                chars.next();
            }
            ch if ch.is_uppercase() => return true,
            _ => {}
        }
    }
    false
}
impl SearchQuery {
    pub fn new(text: impl Into<String>) -> Self {
        let text = text.into();
        let regex = RegexBuilder::new(&text)
            .case_insensitive(!has_capital(&text))
            .build()
            .map_err(|_| "invalid pattern".to_owned());
        Self {
            text,
            whole: None,
            regex,
        }
    }
    /// A query for `text` exactly, as a whole word: `add` matches in
    /// `add_executable`, where the underscore ends the word.
    pub fn word(text: impl Into<String>) -> Self {
        Self::whole(text.into(), Whole::Word)
    }
    /// A query for `text` exactly, as a whole symbol: an underscore next to
    /// it makes a longer symbol, so `add` does not match in `add_x`.
    pub fn symbol(text: impl Into<String>) -> Self {
        Self::whole(text.into(), Whole::Symbol)
    }
    fn whole(text: String, whole: Whole) -> Self {
        Self {
            regex: Ok(Regex::new(&regex::escape(&text)).unwrap()),
            text,
            whole: Some(whole),
        }
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn is_valid(&self) -> bool {
        !self.text.is_empty() && self.regex.is_ok()
    }
    /// Why the pattern matches nothing, when it does not compile.
    pub fn error(&self) -> Option<&str> {
        self.regex.as_ref().err().map(String::as_str)
    }
    /// Matches from the start of the document.
    pub fn cursor<'a>(&'a self, snapshot: &'a Snapshot) -> SearchCursor<'a> {
        self.cursor_from(snapshot, 0)
    }
    /// Matches from the line holding `offset` on.
    pub fn cursor_from<'a>(&'a self, snapshot: &'a Snapshot, offset: usize) -> SearchCursor<'a> {
        SearchCursor {
            query: self,
            snapshot,
            line: snapshot
                .line_of(offset.min(snapshot.len_bytes()))
                .unwrap_or(0),
            found: VecDeque::new(),
        }
    }
    /// Whether `range` is one of the matches.
    pub fn matches(&self, snapshot: &Snapshot, range: &Range<usize>) -> bool {
        self.cursor_from(snapshot, range.start)
            .take_while(|found| found.start <= range.start)
            .any(|found| found == *range)
    }
    /// The replacement for the match at `range`: `$1` or `${name}` stands for
    /// a group, `$0` for the whole match and `$$` for a dollar sign.
    pub fn expand(&self, snapshot: &Snapshot, range: &Range<usize>, template: &str) -> String {
        let Ok(regex) = &self.regex else {
            return template.to_owned();
        };
        let Some(line) = snapshot.line_of(range.start) else {
            return template.to_owned();
        };
        let start = snapshot.line_start(line).unwrap();
        let text = snapshot.line(line).unwrap_or_default();
        let mut out = String::new();
        match regex.captures_at(&text, range.start - start) {
            Some(captures)
                if captures.get(0).unwrap().range() == (range.start - start..range.end - start) =>
            {
                captures.expand(template, &mut out)
            }
            _ => out.push_str(template),
        }
        out
    }
}
pub struct SearchCursor<'a> {
    query: &'a SearchQuery,
    snapshot: &'a Snapshot,
    /// The next line to scan.
    line: usize,
    found: VecDeque<Range<usize>>,
}
impl Iterator for SearchCursor<'_> {
    type Item = Range<usize>;
    fn next(&mut self) -> Option<Self::Item> {
        let regex = self
            .query
            .regex
            .as_ref()
            .ok()
            .filter(|_| self.query.is_valid())?;
        loop {
            if let Some(found) = self.found.pop_front() {
                return Some(found);
            }
            let text = self.snapshot.line(self.line)?;
            let start = self.snapshot.line_start(self.line).unwrap();
            self.line += 1;
            let found: Vec<_> = regex
                .find_iter(&text)
                .filter(|m| !m.is_empty())
                .map(|m| start + m.start()..start + m.end())
                .filter(|found| {
                    self.query
                        .whole
                        .is_none_or(|whole| self.is_boundary(found, whole))
                })
                .collect();
            self.found.extend(found);
        }
    }
}
impl SearchCursor<'_> {
    fn is_boundary(&self, found: &Range<usize>, whole: Whole) -> bool {
        let word = |range: Range<usize>| {
            self.snapshot
                .byte_slice(range)
                .and_then(|slice| slice.chars().next())
                .is_some_and(|ch| ch.is_alphanumeric() || (whole == Whole::Symbol && ch == '_'))
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
            .cursor_from(snapshot, range.end)
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
