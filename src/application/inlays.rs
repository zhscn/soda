//! Words shown between the characters of a line without being part of it,
//! such as the names of parameters at a call. They move with the text and
//! stay until the server gives new ones.
use crate::{
    core::{Association, ByteOffset},
    editor::{Document, DocumentId, DocumentPosition, DocumentUpdate},
};
use std::collections::BTreeMap;

#[derive(Default)]
pub(super) struct Inlays {
    documents: BTreeMap<DocumentId, Vec<(DocumentPosition, String)>>,
}
impl Inlays {
    /// Replaces a document's hints, given as zero-based line, byte and text.
    /// Places past the end of a line stop at it.
    pub fn set(&mut self, document: &Document, hints: Vec<(usize, usize, String)>) {
        let snapshot = document.snapshot();
        let stored = hints.into_iter().filter_map(|(line, byte, text)| {
            let range = snapshot
                .line_content_range(line)
                .filter(|_| line < snapshot.text_lines())?;
            let offset = (range.start + byte).min(range.end);
            let position = document
                .position(ByteOffset(offset), Association::After)
                .ok()?;
            Some((position, text))
        });
        let stored = stored.collect();
        self.documents.insert(document.id(), stored);
    }
    pub fn forget(&mut self, document: DocumentId) {
        self.documents.remove(&document);
    }
    pub fn map(&mut self, change: &DocumentUpdate) {
        let Some(hints) = self.documents.get_mut(&change.document_id) else {
            return;
        };
        for (position, _) in hints {
            *position = position
                .map(change, false)
                .expect("application maps every document revision")
                .unwrap();
        }
    }
    /// A document's hints with their offsets, in order.
    pub fn of(&self, document: &Document) -> Vec<(usize, &str)> {
        let mut hints: Vec<_> = self
            .documents
            .get(&document.id())
            .into_iter()
            .flatten()
            .filter_map(|(position, text)| {
                Some((position.resolve(document).ok()?.0, text.as_str()))
            })
            .collect();
        hints.sort_by_key(|(offset, _)| *offset);
        hints
    }
}
