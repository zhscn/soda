//! Snippets: text with places to fill in, in the LSP syntax. Unlike
//! completion, a snippet goes on after its text is in the document: the
//! session holds where each place is, mapped through every edit, and ends
//! when the caret leaves or the last place is reached.
//!
//! Filling one place does not change its copies: `$1` a second time gets the
//! text the first has when the snippet expands. Variables are empty or take
//! their default, and a choice takes its first option.
use crate::{
    application::{Application, ViewId},
    core::{Association, ByteOffset, Selection},
    editor::{DocumentId, DocumentPosition},
};
use std::ops::Range;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Parsed {
    pub text: String,
    /// In the order they are visited; the last is where the caret ends.
    pub stops: Vec<Range<usize>>,
}

struct Parser<'a> {
    rest: &'a str,
    text: String,
    stops: Vec<(u32, Range<usize>)>,
}
impl Parser<'_> {
    fn peek(&self) -> Option<char> {
        self.rest.chars().next()
    }
    fn bump(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.rest = &self.rest[ch.len_utf8()..];
        Some(ch)
    }
    fn eat(&mut self, ch: char) -> bool {
        let found = self.peek() == Some(ch);
        if found {
            self.bump();
        }
        found
    }
    fn take(&mut self, wanted: impl Fn(char) -> bool) -> &str {
        let end = self.rest.find(|ch| !wanted(ch)).unwrap_or(self.rest.len());
        let (taken, rest) = self.rest.split_at(end);
        self.rest = rest;
        taken
    }
    /// Reads text up to the end, or a `}` that closes a nested part.
    fn body(&mut self, nested: bool) {
        while let Some(ch) = self.bump() {
            match ch {
                '\\' => match self.peek() {
                    Some(next @ ('$' | '}' | '\\')) => {
                        self.bump();
                        self.text.push(next);
                    }
                    _ => self.text.push('\\'),
                },
                '}' if nested => return,
                '$' => self.dollar(),
                ch => self.text.push(ch),
            }
        }
    }
    fn dollar(&mut self) {
        let braced = self.eat('{');
        let digits = self.take(|ch| ch.is_ascii_digit()).to_owned();
        let name = if digits.is_empty() {
            self.take(|ch| ch.is_ascii_alphanumeric() || ch == '_')
                .to_owned()
        } else {
            String::new()
        };
        if digits.is_empty() && name.is_empty() && !braced {
            self.text.push('$');
            return;
        }
        let start = self.text.len();
        if braced {
            match self.peek() {
                Some(':') => {
                    self.bump();
                    self.body(true);
                }
                Some('|') => {
                    self.bump();
                    let first = self.take(|ch| ch != ',' && ch != '|').to_owned();
                    self.text.push_str(&first);
                    self.take(|ch| ch != '}');
                    self.bump();
                }
                Some('/') => {
                    self.take(|ch| ch != '}');
                    self.bump();
                }
                _ => {
                    self.eat('}');
                }
            }
        }
        let Ok(number) = digits.parse() else {
            return;
        };
        let range = start..self.text.len();
        match self.stops.iter().find(|(n, _)| *n == number) {
            Some((_, first)) if range.is_empty() => {
                let copy = self.text[first.clone()].to_owned();
                self.text.push_str(&copy);
            }
            Some(_) => {}
            None => self.stops.push((number, range)),
        }
    }
}
pub fn parse(body: &str) -> Parsed {
    let mut parser = Parser {
        rest: body,
        text: String::new(),
        stops: vec![],
    };
    parser.body(false);
    let Parser {
        text, mut stops, ..
    } = parser;
    let ends = stops.iter().any(|(number, _)| *number == 0);
    stops.sort_by_key(|(number, _)| (*number == 0, *number));
    let mut stops: Vec<_> = stops.into_iter().map(|(_, range)| range).collect();
    if !ends {
        stops.push(text.len()..text.len());
    }
    Parsed { text, stops }
}
impl Parsed {
    /// Follows the line it lands on: lines after the first take `indent`, and
    /// a tab at the start of one is a level, `unit`.
    pub fn indented(&self, indent: &str, unit: &str) -> Self {
        let mut text = String::new();
        let mut map = vec![0; self.text.len() + 1];
        let mut leading = false;
        for (at, ch) in self.text.char_indices() {
            map[at] = text.len();
            match ch {
                '\t' if leading => text.push_str(unit),
                ch => {
                    leading = ch == '\n';
                    text.push(ch);
                    if leading {
                        text.push_str(indent);
                    }
                }
            }
        }
        map[self.text.len()] = text.len();
        Self {
            text,
            stops: self
                .stops
                .iter()
                .map(|stop| map[stop.start]..map[stop.end])
                .collect(),
        }
    }
    pub fn lines(&self) -> usize {
        self.text.matches('\n').count()
    }
}

/// Text just expanded, waiting for its update to become a session.
pub(super) struct Pending {
    pub view: ViewId,
    pub document: DocumentId,
    pub offset: usize,
    pub stops: Vec<Range<usize>>,
}
struct Stop {
    start: DocumentPosition,
    end: DocumentPosition,
}
pub(super) struct Session {
    view: ViewId,
    stops: Vec<Stop>,
    /// The stop being filled.
    at: usize,
    start: DocumentPosition,
    end: DocumentPosition,
}
#[derive(Default)]
pub(super) struct State {
    pub pending: Option<Pending>,
    session: Option<Session>,
}
impl State {
    pub fn active(&self) -> bool {
        self.session.is_some()
    }
    pub fn observe(&mut self, app: &Application, update: &crate::application::Update) {
        let Some(edit) = update.edit.as_ref().and_then(|edit| edit.document.as_ref()) else {
            return;
        };
        if let Some(session) = &mut self.session
            && !session.map(edit)
        {
            self.session = None;
        }
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.document == edit.document_id)
        {
            let pending = self.pending.take().unwrap();
            self.session = Session::new(app, pending);
        }
    }
    /// Ends the session once the caret is out of the snippet.
    pub fn sync(&mut self, app: &Application, editing: bool) {
        let Some(session) = &self.session else {
            return;
        };
        let inside = editing && Some(session.view) == app.active_view() && {
            let view = app.view(session.view).unwrap();
            let editor = app.workspace().editor(view.document_id).unwrap();
            let selection = editor.model().session(view.session_id).unwrap().selection();
            let range = selection.range();
            session.start.offset.0 <= range.start && range.end <= session.end.offset.0
        };
        if !inside {
            self.session = None;
        }
    }
    /// The selection of the next or previous stop; reaching the last ends
    /// the session.
    pub fn step(&mut self, backward: bool) -> Option<(ViewId, Selection)> {
        let session = self.session.as_mut()?;
        session.at = if backward {
            session.at.saturating_sub(1)
        } else {
            session.at + 1
        };
        let stop = session.stops.get(session.at)?;
        let selection = Selection {
            anchor: stop.start.offset.0,
            head: stop.end.offset.0,
        };
        let view = session.view;
        if session.at + 1 == session.stops.len() {
            self.session = None;
        }
        Some((view, selection))
    }
}
impl Session {
    fn new(app: &Application, pending: Pending) -> Option<Self> {
        if pending.stops.len() < 2 {
            return None;
        }
        let document = app.workspace().editor(pending.document)?.model().document();
        let position = |offset, association| {
            document
                .position(ByteOffset(pending.offset + offset), association)
                .ok()
        };
        let stops = pending
            .stops
            .iter()
            .map(|stop| {
                Some(Stop {
                    start: position(stop.start, Association::Before)?,
                    end: position(stop.end, Association::After)?,
                })
            })
            .collect::<Option<Vec<_>>>()?;
        let first = pending.stops.iter().map(|stop| stop.start).min()?;
        let last = pending.stops.iter().map(|stop| stop.end).max()?;
        Some(Self {
            view: pending.view,
            stops,
            at: 0,
            start: position(first, Association::Before)?,
            end: position(last, Association::After)?,
        })
    }
    fn map(&mut self, edit: &crate::editor::DocumentUpdate) -> bool {
        let moved = |position: &mut DocumentPosition| match position.map(edit, false) {
            Ok(Some(mapped)) => {
                *position = mapped;
                true
            }
            _ => false,
        };
        self.stops
            .iter_mut()
            .all(|stop| moved(&mut stop.start) && moved(&mut stop.end))
            && moved(&mut self.start)
            && moved(&mut self.end)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn parsed(body: &str) -> (String, Vec<Range<usize>>) {
        let Parsed { text, stops } = parse(body);
        (text, stops)
    }
    #[test]
    fn stops_come_in_order_with_the_end_last() {
        assert_eq!(
            parsed("a$2b$1c$0d"),
            ("abcd".into(), vec![2..2, 1..1, 3..3])
        );
        assert_eq!(parsed("f(${1:x})"), ("f(x)".into(), vec![2..3, 4..4]));
        assert_eq!(parsed("plain").1.len(), 1);
    }
    #[test]
    fn placeholders_nest_and_copies_take_the_first() {
        assert_eq!(parsed("${1:a${2:b}c}").0, "abc");
        assert_eq!(parsed("${1:a} $1").0, "a a");
    }
    #[test]
    fn the_rest_of_the_syntax_reads_as_text() {
        assert_eq!(parsed("\\$1 \\} \\\\").0, "$1 } \\");
        assert_eq!(parsed("cost $").0, "cost $");
        assert_eq!(parsed("${1|yes,no|}!").0, "yes!");
        assert_eq!(parsed("$NAME${OTHER:x}").0, "x");
        assert_eq!(parsed("${1/a/b/}c").0, "c");
    }
    #[test]
    fn indenting_keeps_stops_on_their_text() {
        let body = parse("{\n\t${1:x}\n}");
        let indented = body.indented("  ", "    ");
        assert_eq!(indented.text, "{\n      x\n  }");
        assert_eq!(&indented.text[indented.stops[0].clone()], "x");
    }
}
