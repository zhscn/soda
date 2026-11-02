//! Text ranges an extension says something about, such as a language
//! server's diagnostics. Frontends underline them and show the words when
//! the caret comes to their line. Notes belong to named groups, so a source
//! replaces its own, and they move with the text as it is edited.
use crate::{
    core::{Association, ByteOffset},
    editor::{Document, DocumentId, DocumentPosition, DocumentUpdate},
};
use std::{collections::BTreeMap, ops::Range};

/// Ordered so that the worst sorts last.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Severity {
    Info,
    Warning,
    Error,
}
impl Severity {
    pub fn parse(name: &str) -> Result<Self, String> {
        match name {
            "info" => Ok(Self::Info),
            "warning" => Ok(Self::Warning),
            "error" => Ok(Self::Error),
            _ => Err(format!(
                "unknown severity {name}: use info, warning or error"
            )),
        }
    }
}
/// A note as an extension gives it, in zero-based lines and bytes.
#[derive(Clone, Debug)]
pub struct NoteSpan {
    pub start: (usize, usize),
    pub end: (usize, usize),
    pub severity: Severity,
    pub text: String,
}
/// A note as it stands in the text.
#[derive(Clone, Debug)]
pub struct Note<'a> {
    pub range: Range<usize>,
    pub severity: Severity,
    pub text: &'a str,
}
struct Stored {
    start: DocumentPosition,
    end: DocumentPosition,
    severity: Severity,
    text: String,
}
#[derive(Default)]
pub(super) struct Notes {
    documents: BTreeMap<DocumentId, BTreeMap<String, Vec<Stored>>>,
}
impl Notes {
    /// Replaces a group's notes; places past the end of a line stop at it,
    /// and notes on lines past the end are skipped.
    pub fn set(&mut self, document: &Document, group: &str, notes: Vec<NoteSpan>) {
        let snapshot = document.snapshot();
        let offset = |(line, byte): (usize, usize)| {
            let text = snapshot
                .line(line)
                .filter(|_| line < snapshot.text_lines())?;
            let length = text.trim_end_matches(['\n', '\r']).len();
            Some(snapshot.line_start(line)? + byte.min(length))
        };
        let stored = notes.into_iter().filter_map(|note| {
            let start = offset(note.start)?;
            let end = offset(note.end).unwrap_or(snapshot.len_bytes()).max(start);
            Some(Stored {
                // Inward, so that typing at either edge stays outside.
                start: document
                    .position(ByteOffset(start), Association::After)
                    .ok()?,
                end: document
                    .position(ByteOffset(end), Association::Before)
                    .ok()?,
                severity: note.severity,
                text: note.text,
            })
        });
        let stored: Vec<_> = stored.collect();
        let groups = self.documents.entry(document.id()).or_default();
        if stored.is_empty() {
            groups.remove(group);
        } else {
            groups.insert(group.to_owned(), stored);
        }
    }
    pub fn forget(&mut self, document: DocumentId) {
        self.documents.remove(&document);
    }
    pub fn map(&mut self, change: &DocumentUpdate) {
        let Some(groups) = self.documents.get_mut(&change.document_id) else {
            return;
        };
        for note in groups.values_mut().flatten() {
            for position in [&mut note.start, &mut note.end] {
                *position = position
                    .map(change, false)
                    .expect("application maps every document revision")
                    .unwrap();
            }
        }
    }
    /// A document's notes, the least severe first.
    pub fn of(&self, document: &Document) -> Vec<Note<'_>> {
        let mut notes: Vec<_> = self
            .documents
            .get(&document.id())
            .into_iter()
            .flat_map(BTreeMap::values)
            .flatten()
            .filter_map(|note| {
                let start = note.start.resolve(document).ok()?.0;
                let end = note.end.resolve(document).ok()?.0;
                Some(Note {
                    range: start..end.max(start),
                    severity: note.severity,
                    text: &note.text,
                })
            })
            .collect();
        notes.sort_by_key(|note| note.severity);
        notes
    }
}
