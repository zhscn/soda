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
    /// The same pattern over the whole text, with `^` and `$` at line
    /// ends. It only finds the next line with a match, which `regex` then
    /// scans as before; patterns with `\A` or `\z` go line by line.
    across: Option<Regex>,
}
/// The pattern over the whole text, when it means there what it means in
/// a line.
fn across(pattern: &str, case_insensitive: bool) -> Option<Regex> {
    if pattern.contains("\\A") || pattern.contains("\\z") {
        return None;
    }
    RegexBuilder::new(pattern)
        .case_insensitive(case_insensitive)
        .multi_line(true)
        .crlf(true)
        .build()
        .ok()
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
        let case_insensitive = !has_capital(&text);
        let regex = RegexBuilder::new(&text)
            .case_insensitive(case_insensitive)
            .build()
            .map_err(|_| "invalid pattern".to_owned());
        Self {
            across: regex
                .is_ok()
                .then(|| across(&text, case_insensitive))
                .flatten(),
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
        let pattern = regex::escape(&text);
        Self {
            across: across(&pattern, false),
            regex: Ok(Regex::new(&pattern).unwrap()),
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
            across: None,
            line_end: None,
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
    /// Matches over the text from a line start on, and that start.
    across: Option<(usize, regex::Matches<'a, 'a>)>,
    /// Where the content of the last match's line ends, so that matches in
    /// the same line look nothing up.
    line_end: Option<usize>,
}
/// Where the content of the line holding `offset` ends: before its `\n`
/// or `\r\n`, or at the end of the text.
fn content_end(text: &str, offset: usize) -> usize {
    match text[offset..].find('\n') {
        Some(at) => {
            let newline = offset + at;
            if newline > offset && text.as_bytes()[newline - 1] == b'\r' {
                newline - 1
            } else {
                newline
            }
        }
        None => text.len(),
    }
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
            // Matches within a line are the same over the whole text, which
            // is searched in one pass; a match that runs past its line's
            // end is not one, so that line is scanned by itself.
            // A lone `\r` ends a line for the pattern over the text but not
            // for the line alone.
            if let Some(pattern) = self
                .query
                .across
                .as_ref()
                .filter(|_| !self.snapshot.has_lone_cr())
            {
                if self.across.is_none() {
                    let from = self.snapshot.line_start(self.line)?;
                    let matches = pattern.find_iter(&self.snapshot.text()[from..]);
                    self.across = Some((from, matches));
                }
                let (base, matches) = self.across.as_mut().unwrap();
                let Some(found) = matches.next() else {
                    self.line = self.snapshot.line_count();
                    return None;
                };
                if found.is_empty() {
                    continue;
                }
                let found = *base + found.start()..*base + found.end();
                let end = match self.line_end {
                    Some(end) if found.start <= end => end,
                    _ => content_end(self.snapshot.text(), found.start),
                };
                self.line_end = Some(end);
                if found.end <= end {
                    if self.accepts(&found) {
                        return Some(found);
                    }
                    continue;
                }
                self.across = None;
                self.line_end = None;
                self.line = self.snapshot.line_of(found.start).unwrap();
                let rest = self.line_matches(regex).into_iter();
                self.found
                    .extend(rest.filter(|range| range.start >= found.start));
                continue;
            }
            let found = self.line_matches(regex);
            if self.line > self.snapshot.line_count() {
                return None;
            }
            self.found.extend(found);
        }
    }
}
impl SearchCursor<'_> {
    /// The matches of the next line, scanned alone; past the last line,
    /// none.
    fn line_matches(&mut self, regex: &Regex) -> Vec<Range<usize>> {
        let Some(text) = self.snapshot.line(self.line) else {
            self.line = self.snapshot.line_count() + 1;
            return vec![];
        };
        let start = self.snapshot.line_start(self.line).unwrap();
        self.line += 1;
        regex
            .find_iter(&text)
            .filter(|m| !m.is_empty())
            .map(|m| start + m.start()..start + m.end())
            .filter(|found| self.accepts(found))
            .collect()
    }
    fn accepts(&self, found: &Range<usize>) -> bool {
        self.query
            .whole
            .is_none_or(|whole| self.is_boundary(found, whole))
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    /// The matches line by line, as before the text was searched whole.
    fn by_lines(query: &SearchQuery, snapshot: &Snapshot) -> Vec<Range<usize>> {
        let line_by_line = SearchQuery {
            across: None,
            ..query.clone()
        };
        line_by_line.cursor(snapshot).collect()
    }
    #[test]
    fn searching_the_whole_text_finds_what_lines_alone_find() {
        let texts = [
            "a b\nab  \n\nb a\n",
            "foo bar\r\nbar foo \r\n\r\nfoo",
            "x\n  x  \n\tx\n",
            "add add_x xadd\nadd\n",
            "",
            "no newline at end x",
            "a\rb x\r\nx\ra$\n",
        ];
        let patterns = [
            "a",
            "b a",
            "\\s*",
            "x\\s*",
            "\\s+",
            "^",
            "$",
            "^x",
            "x$",
            "\\bfoo\\b",
            "a|",
            "[^a]+",
            "o*",
            "(?s).",
            "bar\\s*\\n?foo",
            "\\Ax",
            "x\\z",
            "\\n",
        ];
        for text in texts {
            let snapshot = Snapshot::new(text.to_owned(), 0);
            for pattern in patterns {
                let query = SearchQuery::new(pattern);
                let found: Vec<_> = query.cursor(&snapshot).collect();
                assert_eq!(
                    found,
                    by_lines(&query, &snapshot),
                    "{pattern:?} in {text:?}"
                );
                for offset in [0, 3, text.len()] {
                    let from: Vec<_> = query.cursor_from(&snapshot, offset).collect();
                    let line = snapshot.line_of(offset.min(text.len())).unwrap_or(0);
                    let start = snapshot.line_start(line).unwrap_or(0);
                    let expected: Vec<_> = by_lines(&query, &snapshot)
                        .into_iter()
                        .filter(|range| range.start >= start)
                        .collect();
                    assert_eq!(from, expected, "{pattern:?} in {text:?} from {offset}");
                }
            }
            for query in [SearchQuery::word("add"), SearchQuery::symbol("add")] {
                let found: Vec<_> = query.cursor(&snapshot).collect();
                assert_eq!(
                    found,
                    by_lines(&query, &snapshot),
                    "{:?} in {text:?}",
                    query.text()
                );
            }
        }
    }
    /// `SODA_BENCH_FILE=path cargo test --release --lib -- --ignored search_bench --nocapture`
    #[test]
    #[ignore]
    fn search_bench() {
        let path = std::env::var("SODA_BENCH_FILE").unwrap();
        let snapshot = Snapshot::new(std::fs::read_to_string(&path).unwrap(), 0);
        snapshot.text();
        for text in ["e", "Lo", "Lowering", "X86ISD::", "zzzz", "\\bif\\b"] {
            let query = SearchQuery::new(text);
            let start = std::time::Instant::now();
            let count = query.cursor(&snapshot).count();
            println!("{text:>10}: {count:>7} matches in {:?}", start.elapsed());
        }
    }
}
