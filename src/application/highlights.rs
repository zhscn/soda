//! Patterns highlighted wherever they occur, after kakoune's regex
//! highlighters: globally, such as TODO markers, or in one document, such
//! as the symbols symbol-overlay marks. Frontends match them against the
//! lines they show.
use crate::editor::DocumentId;
use regex::Regex;
use std::collections::BTreeMap;

/// How highlighted text looks; frontends map faces to colours.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Face {
    Todo,
    Error,
    Info,
    /// One of the backgrounds for marked symbols.
    Mark(u8),
    /// The underline of a note.
    Note(super::Severity),
    /// Any face by its place in `faces::names`, for paints.
    Named(u16),
}
pub const MARKS: u8 = 8;
impl Face {
    /// `todo`, `error`, `info`, `mark1` to `mark8`, or `mark` for the next mark
    /// colour.
    pub fn parse(name: &str) -> Result<Option<Self>, String> {
        Ok(Some(match name {
            "todo" => Self::Todo,
            "error" => Self::Error,
            "info" => Self::Info,
            "mark" => return Ok(None),
            _ => match name
                .strip_prefix("mark")
                .and_then(|n| n.parse::<u8>().ok())
                .filter(|n| (1..=MARKS).contains(n))
            {
                Some(n) => Self::Mark(n - 1),
                None => {
                    return Err(format!(
                        "unknown face {name}: use todo, error, info, mark or mark1 to mark{MARKS}"
                    ));
                }
            },
        }))
    }
}
#[derive(Clone, Debug)]
pub struct Highlight {
    pub face: Face,
    pub pattern: Regex,
}
#[derive(Default)]
pub(super) struct Highlights {
    global: Vec<Highlight>,
    documents: BTreeMap<DocumentId, Vec<Highlight>>,
}
impl Highlights {
    /// Adds a highlight, replacing one with the same pattern. Without a
    /// face, a document mark takes the colour after the last one.
    pub fn add(&mut self, document: Option<DocumentId>, face: Option<Face>, pattern: Regex) {
        let list = match document {
            Some(document) => self.documents.entry(document).or_default(),
            None => &mut self.global,
        };
        list.retain(|h| h.pattern.as_str() != pattern.as_str());
        let face = face.unwrap_or_else(|| {
            let last = list.iter().rev().find_map(|h| match h.face {
                Face::Mark(n) => Some(n),
                _ => None,
            });
            Face::Mark(last.map_or(0, |n| (n + 1) % MARKS))
        });
        list.push(Highlight { face, pattern });
    }
    /// Removes the highlights with this pattern, or all of them, from a
    /// document and globally. Returns how many went.
    pub fn remove(&mut self, document: Option<DocumentId>, pattern: Option<&str>) -> usize {
        let keep = |h: &Highlight| pattern.is_some_and(|p| p != h.pattern.as_str());
        let before = self.count(document);
        self.global.retain(keep);
        if let Some(list) = document.and_then(|d| self.documents.get_mut(&d)) {
            list.retain(keep);
        }
        before - self.count(document)
    }
    fn count(&self, document: Option<DocumentId>) -> usize {
        self.global.len()
            + document
                .and_then(|d| self.documents.get(&d))
                .map_or(0, Vec::len)
    }
    pub fn forget(&mut self, document: DocumentId) {
        self.documents.remove(&document);
    }
    /// The highlights that apply to a document, global ones first.
    pub fn of(&self, document: DocumentId) -> impl Iterator<Item = &Highlight> {
        self.global
            .iter()
            .chain(self.documents.get(&document).into_iter().flatten())
    }
}
