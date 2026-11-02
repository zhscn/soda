//! Text ranges an extension colors with a face, such as changed lines or
//! a matching bracket. Like notes, paints belong to named groups, so a
//! source replaces its own, and they move with the text as it is edited;
//! unlike notes they say nothing, they only color.
use super::Face;
use crate::{
    core::{Association, ByteOffset},
    editor::{Document, DocumentId, DocumentPosition, DocumentUpdate},
};
use std::{collections::BTreeMap, ops::Range};

/// A paint as an extension gives it, in zero-based lines and bytes.
#[derive(Clone, Debug)]
pub struct PaintSpan {
    pub start: (usize, usize),
    pub end: (usize, usize),
    pub face: Face,
}
struct Stored {
    start: DocumentPosition,
    end: DocumentPosition,
    face: Face,
}
#[derive(Default)]
pub(super) struct Paints {
    documents: BTreeMap<DocumentId, BTreeMap<String, Vec<Stored>>>,
}
impl Paints {
    /// Replaces a group's paints; places past the end of a line stop at it,
    /// and paints on lines past the end are skipped. None clear the group.
    pub fn set(&mut self, document: &Document, group: &str, paints: Vec<PaintSpan>) {
        let snapshot = document.snapshot();
        let offset = |(line, byte): (usize, usize)| {
            let text = snapshot
                .line(line)
                .filter(|_| line < snapshot.text_lines())?;
            let length = text.trim_end_matches(['\n', '\r']).len();
            Some(snapshot.line_start(line)? + byte.min(length))
        };
        let stored: Vec<_> = paints
            .into_iter()
            .filter_map(|paint| {
                let start = offset(paint.start)?;
                let end = offset(paint.end).unwrap_or(snapshot.len_bytes()).max(start);
                Some(Stored {
                    // Inward, so that typing at either edge stays outside.
                    start: document
                        .position(ByteOffset(start), Association::After)
                        .ok()?,
                    end: document
                        .position(ByteOffset(end), Association::Before)
                        .ok()?,
                    face: paint.face,
                })
            })
            .collect();
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
        for paint in groups.values_mut().flatten() {
            for position in [&mut paint.start, &mut paint.end] {
                *position = position
                    .map(change, false)
                    .expect("application maps every document revision")
                    .unwrap();
            }
        }
    }
    /// A document's paints as they stand in the text, groups in name order.
    pub fn of(&self, document: &Document) -> Vec<(Range<usize>, Face)> {
        self.documents
            .get(&document.id())
            .into_iter()
            .flat_map(BTreeMap::values)
            .flatten()
            .filter_map(|paint| {
                let start = paint.start.resolve(document).ok()?.0;
                let end = paint.end.resolve(document).ok()?.0;
                (start < end).then_some((start..end, paint.face))
            })
            .collect()
    }
}
