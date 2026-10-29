//! Whitespace tidied when a file is saved: trailing spaces and tabs go from
//! the lines edited since the file was loaded or saved, as ws-butler does,
//! so lines nobody touched never show up in a diff; a missing final line
//! break is added.
use crate::{
    core::{Change, Snapshot},
    editor::{DocumentId, DocumentUpdate, EditOrigin},
};
use std::{collections::BTreeMap, ops::Range};

/// Byte ranges edited since the baseline, in the current revision, sorted
/// and disjoint.
#[derive(Default)]
pub(super) struct Touched(BTreeMap<DocumentId, Vec<Range<usize>>>);
impl Touched {
    pub fn record(&mut self, update: &DocumentUpdate) {
        if update.origin == EditOrigin::Reload {
            self.0.remove(&update.document_id);
            return;
        }
        let ranges = self.0.entry(update.document_id).or_default();
        let map = |offset, association| update.mapping.map(offset, association);
        use crate::core::Association::{After, Before};
        let mut next: Vec<_> = ranges
            .iter()
            .map(|range| map(range.start, Before)..map(range.end, After))
            .collect();
        next.extend(update.changes.iter().map(|change| {
            let start = map(change.range.start, Before);
            start..start + change.insert.len()
        }));
        next.sort_by_key(|range| range.start);
        let mut merged: Vec<Range<usize>> = Vec::with_capacity(next.len());
        for range in next {
            match merged.last_mut() {
                Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
                _ => merged.push(range),
            }
        }
        *ranges = merged;
    }
    pub fn forget(&mut self, document: DocumentId) {
        self.0.remove(&document);
    }
    pub fn get(&self, document: DocumentId) -> &[Range<usize>] {
        self.0.get(&document).map_or(&[], Vec::as_slice)
    }
}

/// Changes that tidy a snapshot before it is saved.
pub(super) fn changes(
    snapshot: &Snapshot,
    touched: &[Range<usize>],
    final_newline: bool,
) -> Vec<Change> {
    let mut lines = vec![];
    for range in touched {
        let (Some(first), Some(last)) = (
            snapshot.line_of(range.start.min(snapshot.len_bytes())),
            snapshot.line_of(range.end.min(snapshot.len_bytes())),
        ) else {
            continue;
        };
        lines.extend(first..=last);
    }
    lines.dedup();
    let mut out = vec![];
    for line in lines {
        let content = snapshot.line_content_range(line).unwrap();
        let text = snapshot.byte_slice(content.clone()).unwrap().to_string();
        let kept = text.trim_end_matches([' ', '\t']).len();
        if kept < text.len() {
            out.push(Change::new(
                content.start + kept..content.end,
                String::new(),
            ));
        }
    }
    let end = snapshot.len_bytes();
    // Text that ends with a line break has an empty last line.
    let last = snapshot.line_count() - 1;
    if final_newline && !snapshot.line_range(last).unwrap().is_empty() {
        // Follow the first line's break.
        let crlf = snapshot.line_count() > 1
            && snapshot.line_range(0).unwrap().len()
                == snapshot.line_content_range(0).unwrap().len() + 2;
        out.push(Change::new(end..end, if crlf { "\r\n" } else { "\n" }));
    }
    out
}

#[cfg(test)]
mod tests {
    use crate::core::Snapshot;
    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn only_touched_lines_lose_trailing_whitespace() {
        let snapshot = Snapshot::new("a  \nb \t\nc \n d".into(), 0);
        let changes = super::changes(&snapshot, &[5..6], true);
        assert_eq!(changes.len(), 2);
        assert_eq!(changes[0].range, 5..7);
        assert_eq!(
            (changes[1].range.clone(), changes[1].insert.as_str()),
            (13..13, "\n")
        );
        let crlf = Snapshot::new("a \r\nb".into(), 0);
        let changes = super::changes(&crlf, &[0..1], true);
        assert_eq!(changes[0].range, 1..2);
        assert_eq!(changes[1].insert, "\r\n");
        assert!(super::changes(&Snapshot::new(String::new(), 0), &[], true).is_empty());
        assert!(super::changes(&Snapshot::new("x".into(), 0), &[], false).is_empty());
        assert!(super::changes(&Snapshot::new("a\n".into(), 0), &[], true).is_empty());
        let wide = super::changes(&Snapshot::new("中".into(), 0), &[], true);
        assert_eq!(wide[0].range, 3..3);
    }
}
