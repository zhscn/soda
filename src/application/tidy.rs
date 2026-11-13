//! Whitespace tidied when a file is saved: trailing spaces and tabs go from
//! the lines edited since the file was loaded or saved, as ws-butler does,
//! so lines nobody touched never show up in a diff; a missing final line
//! break is added. EditorConfig can instead request whole-file whitespace
//! cleanup, explicit line endings and removal of final line breaks.
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

/// EditorConfig can tidy every line, choose line endings, or remove trailing
/// newlines. Each changed line keeps its unchanged prefix so retained carets
/// and diagnostics continue to point at the same text.
pub(super) fn configured_changes(
    snapshot: &Snapshot,
    touched: &[Range<usize>],
    trim_all: bool,
    final_newline: bool,
    remove_final: bool,
    newline: Option<&str>,
) -> Vec<Change> {
    let mut trim_lines = std::collections::BTreeSet::new();
    for range in touched {
        let first = snapshot
            .line_of(range.start.min(snapshot.len_bytes()))
            .unwrap();
        let last = snapshot
            .line_of(range.end.min(snapshot.len_bytes()))
            .unwrap();
        trim_lines.extend(first..=last);
    }
    let mut rows = Vec::new();
    for line in 0..snapshot.line_count() {
        let range = snapshot.line_range(line).unwrap();
        let content = snapshot.line_content_range(line).unwrap();
        let text = snapshot.byte_slice(content.clone()).unwrap().to_string();
        let kept = if trim_all {
            text.trim_end_matches(char::is_whitespace)
        } else if trim_lines.contains(&line) {
            text.trim_end_matches([' ', '\t'])
        } else {
            &text
        };
        let ending = if range.end > content.end {
            newline.unwrap_or(if range.end - content.end == 2 {
                "\r\n"
            } else {
                "\n"
            })
        } else {
            ""
        };
        rows.push((range, kept.to_owned(), ending));
    }
    let last_content = rows.iter().rposition(|(_, text, _)| !text.is_empty());
    let detected = if snapshot.line_count() > 1
        && snapshot.line_range(0).unwrap().len() - snapshot.line_content_range(0).unwrap().len()
            == 2
    {
        "\r\n"
    } else {
        "\n"
    };
    let last_line = rows.len() - 1;
    let mut out = Vec::new();
    for (line, (range, mut text, mut ending)) in rows.into_iter().enumerate() {
        if remove_final && last_content.is_none_or(|last| line > last) {
            text.clear();
            ending = "";
        } else if remove_final && Some(line) == last_content {
            ending = "";
        } else if final_newline && line == last_line && !text.is_empty() && ending.is_empty() {
            ending = newline.unwrap_or(detected);
        }
        text.push_str(ending);
        let old = snapshot.byte_slice(range.clone()).unwrap().to_string();
        if old == text {
            continue;
        }
        let prefix = old
            .chars()
            .zip(text.chars())
            .take_while(|(a, b)| a == b)
            .map(|(ch, _)| ch.len_utf8())
            .sum::<usize>();
        out.push(Change::new(
            range.start + prefix..range.end,
            text[prefix..].to_owned(),
        ));
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
