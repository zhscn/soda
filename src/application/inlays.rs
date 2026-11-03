//! Words shown between the characters of a line without being part of it,
//! such as the names of parameters at a call. They move with the text and
//! stay until the server gives new ones. A document may have tens of
//! thousands, so, like tokens, they are plain sorted offsets that one pass
//! moves along with an edit, and drawing reads only the lines it shows.
use crate::{
    core::Association,
    editor::{Document, DocumentId, DocumentUpdate},
};
use std::{collections::BTreeMap, ops::Range};

#[derive(Default)]
pub(super) struct Inlays {
    documents: BTreeMap<DocumentId, Vec<(usize, String)>>,
}
impl Inlays {
    /// Replaces a document's hints, given as zero-based line, byte and text.
    /// Places past the end of a line stop at it.
    pub fn set(&mut self, document: &Document, mut hints: Vec<(usize, usize, String)>) {
        let snapshot = document.snapshot();
        let lines = snapshot.text_lines();
        hints.sort_by_key(|(line, byte, _)| (*line, *byte));
        let mut stored = Vec::with_capacity(hints.len());
        let mut walk = snapshot.walk_lines();
        let mut current: Option<(usize, Range<usize>)> = None;
        for (line, byte, text) in hints {
            if line >= lines {
                continue;
            }
            if current.as_ref().is_none_or(|(at, _)| *at != line) {
                let Some((range, _)) = walk.content(line) else {
                    continue;
                };
                current = Some((line, range));
            }
            let range = &current.as_ref().unwrap().1;
            let mut offset = (range.start + byte).min(range.end);
            while !snapshot.is_char_boundary(offset) {
                offset -= 1;
            }
            stored.push((offset, text));
        }
        self.documents.insert(document.id(), stored);
    }
    pub fn forget(&mut self, document: DocumentId) {
        self.documents.remove(&document);
    }
    pub fn map(&mut self, change: &DocumentUpdate) {
        let Some(hints) = self.documents.get_mut(&change.document_id) else {
            return;
        };
        for (offset, _) in hints {
            *offset = change.mapping.map(*offset, Association::After);
        }
    }
    /// A document's hints with their offsets, in order.
    pub fn of(&self, document: DocumentId) -> &[(usize, String)] {
        self.documents.get(&document).map_or(&[], Vec::as_slice)
    }
}
