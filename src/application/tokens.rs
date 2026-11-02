//! What a language server knows that highlighting cannot: which names are
//! types, parameters or macros. Tokens are many and change only when the
//! server answers, so they are plain sorted byte ranges that one pass moves
//! along with an edit, until the next answer replaces them.
use crate::{
    core::Association,
    editor::{Document, DocumentId, DocumentUpdate},
    syntax::Category,
};
use std::{collections::BTreeMap, ops::Range};

/// A token in zero-based lines and bytes.
#[derive(Clone, Debug)]
pub struct TokenSpan {
    pub line: usize,
    pub bytes: Range<usize>,
    pub category: Category,
}
#[derive(Default)]
pub(super) struct Tokens {
    documents: BTreeMap<DocumentId, Vec<(Range<usize>, Category)>>,
}
impl Tokens {
    /// Replaces a document's tokens. Those past the end of a line are cut
    /// to it, and any overlapping an earlier one are dropped.
    pub fn set(&mut self, document: &Document, mut tokens: Vec<TokenSpan>) {
        let snapshot = document.snapshot();
        tokens.sort_by_key(|token| (token.line, token.bytes.start));
        let mut kept: Vec<(Range<usize>, Category)> = Vec::with_capacity(tokens.len());
        for token in tokens {
            let Some(range) = snapshot
                .line_content_range(token.line)
                .filter(|_| token.line < snapshot.text_lines())
            else {
                continue;
            };
            let start = (range.start + token.bytes.start).min(range.end);
            let end = (range.start + token.bytes.end).min(range.end);
            if start < end && kept.last().is_none_or(|(last, _)| last.end <= start) {
                kept.push((start..end, token.category));
            }
        }
        self.documents.insert(document.id(), kept);
    }
    pub fn forget(&mut self, document: DocumentId) {
        self.documents.remove(&document);
    }
    pub fn map(&mut self, change: &DocumentUpdate) {
        let Some(tokens) = self.documents.get_mut(&change.document_id) else {
            return;
        };
        tokens.retain_mut(|(range, _)| {
            // Text typed at an edge stays outside the token.
            range.start = change.mapping.map(range.start, Association::After);
            range.end = change.mapping.map(range.end, Association::Before);
            range.start < range.end
        });
    }
    /// The tokens starting within `range`, relative to its start.
    pub fn within(
        &self,
        document: DocumentId,
        range: Range<usize>,
    ) -> Vec<(Range<usize>, Category)> {
        let Some(tokens) = self.documents.get(&document) else {
            return vec![];
        };
        let first = tokens.partition_point(|(token, _)| token.start < range.start);
        tokens[first..]
            .iter()
            .take_while(|(token, _)| token.start < range.end)
            .map(|(token, category)| {
                let end = token.end.min(range.end);
                (token.start - range.start..end - range.start, *category)
            })
            .collect()
    }
}
