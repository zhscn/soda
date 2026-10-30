//! Signs beside lines in the gutter, after kakoune's flag-lines: what an
//! extension marks as added or changed in version control, or where a build
//! reported errors. Flags belong to named groups, so one source replaces
//! its own flags without touching another's, and they keep to their lines
//! as text is edited.
use super::Face;
use crate::{
    core::{Association, ByteOffset},
    editor::{Document, DocumentId, DocumentPosition, DocumentUpdate},
};
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq)]
pub struct Flag {
    pub face: Face,
    /// One cell of text.
    pub sign: String,
}
impl Flag {
    /// A flag from a face name and a sign of one narrow character.
    pub fn new(face: &str, sign: &str) -> Result<Self, String> {
        let face = Face::parse(face)?
            .ok_or_else(|| "flags need a face: todo, error or mark1 to mark4".to_owned())?;
        let mut cells = unicode_segmentation::UnicodeSegmentation::graphemes(sign, true);
        match (cells.next(), cells.next()) {
            (Some(cell), None) if unicode_width::UnicodeWidthStr::width(cell) == 1 => Ok(Self {
                face,
                sign: cell.to_owned(),
            }),
            _ => Err(format!("a sign is one narrow character, not {sign}")),
        }
    }
}
/// A named group's flags, each at the start of its line.
type Group = (String, Vec<(DocumentPosition, Flag)>);
#[derive(Default)]
pub(super) struct Flags {
    /// Per document, groups in the order they were first flagged.
    documents: BTreeMap<DocumentId, Vec<Group>>,
}
impl Flags {
    /// Flags zero-based `lines` in a group; lines past the end are skipped.
    pub fn add(&mut self, document: &Document, group: &str, flag: &Flag, lines: &[usize]) {
        let snapshot = document.snapshot();
        let positions = lines.iter().filter_map(|line| {
            let start = snapshot
                .line_start(*line)
                .filter(|_| *line < snapshot.text_lines())?;
            // After: text inserted at the line start, such as a line opened
            // above, pushes the flag along with its line.
            document
                .position(ByteOffset(start), Association::After)
                .ok()
        });
        let groups = self.documents.entry(document.id()).or_default();
        let index = match groups.iter().position(|(name, _)| name == group) {
            Some(index) => index,
            None => {
                groups.push((group.to_owned(), vec![]));
                groups.len() - 1
            }
        };
        groups[index]
            .1
            .extend(positions.map(|position| (position, flag.clone())));
    }
    /// Removes a group's flags, or all, from a document. Returns whether
    /// there were any.
    pub fn remove(&mut self, document: DocumentId, group: Option<&str>) -> bool {
        let Some(groups) = self.documents.get_mut(&document) else {
            return false;
        };
        let before = groups.len();
        groups.retain(|(name, _)| group.is_some_and(|group| group != name));
        before != groups.len()
    }
    pub fn forget(&mut self, document: DocumentId) {
        self.documents.remove(&document);
    }
    /// Moves flags with an edit. A flag whose line went keeps to the line
    /// that took its place.
    pub fn map(&mut self, change: &DocumentUpdate) {
        let Some(groups) = self.documents.get_mut(&change.document_id) else {
            return;
        };
        for (_, flags) in groups {
            for (position, _) in flags.iter_mut() {
                *position = position
                    .map(change, false)
                    .expect("application maps every document revision")
                    .unwrap();
            }
        }
    }
    /// The flag shown on each flagged line; a later group's wins.
    pub fn of(&self, document: &Document) -> BTreeMap<usize, &Flag> {
        let snapshot = document.snapshot();
        let mut lines = BTreeMap::new();
        for (_, flags) in self.documents.get(&document.id()).into_iter().flatten() {
            for (position, flag) in flags {
                if let Some(line) = position
                    .resolve(document)
                    .ok()
                    .and_then(|offset| snapshot.line_of(offset.0))
                {
                    lines.insert(line, flag);
                }
            }
        }
        lines
    }
}
