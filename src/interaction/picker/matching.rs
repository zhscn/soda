//! The matcher produces grapheme indices; only UTF-8 display ranges leave here.
use super::{MatchedCandidate, PickerResults, PickerTask, source::Catalog};
use nucleo_matcher::{
    Config, Matcher, Utf32Str,
    pattern::{Atom, AtomKind, CaseMatching, Normalization},
};
use std::{cmp::Ordering, collections::BinaryHeap, path::PathBuf};
use unicode_segmentation::UnicodeSegmentation;

struct Ranked {
    score: u16,
    candidate: std::sync::Arc<super::Candidate<PathBuf>>,
}
impl PartialEq for Ranked {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for Ranked {}
impl PartialOrd for Ranked {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
// The worst retained match stays at the heap root.
impl Ord for Ranked {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .score
            .cmp(&self.score)
            .then_with(|| self.candidate.label.cmp(&other.candidate.label))
            .then_with(|| self.candidate.payload.cmp(&other.candidate.payload))
            .then_with(|| self.candidate.key.cmp(&other.candidate.key))
    }
}
/// Fuzzy-matches one short text, returning the score and the UTF-8 ranges
/// of the matched graphemes. Used for in-memory candidate lists.
pub(crate) fn fuzzy_match(
    matcher: &mut Matcher,
    query: &str,
    text: &str,
) -> Option<(u16, Vec<std::ops::Range<usize>>)> {
    let atom = Atom::new(
        query,
        CaseMatching::Smart,
        Normalization::Smart,
        AtomKind::Fuzzy,
        false,
    );
    let ranges: Vec<_> = text
        .grapheme_indices(true)
        .map(|(start, g)| start..start + g.len())
        .collect();
    let symbols: Vec<char> = ranges
        .iter()
        .map(|range| text[range.clone()].chars().next().unwrap())
        .collect();
    let mut indices = Vec::new();
    let score = atom.indices(Utf32Str::Unicode(&symbols), matcher, &mut indices)?;
    indices.sort_unstable();
    indices.dedup();
    Some((
        score,
        indices
            .iter()
            .filter_map(|index| ranges.get(*index as usize).cloned())
            .collect(),
    ))
}
pub(super) fn filter(
    catalog: &Catalog,
    task: &PickerTask,
    matcher: &mut Matcher,
) -> Option<PickerResults<PathBuf>> {
    let atom = Atom::new(
        &task.query,
        CaseMatching::Smart,
        Normalization::Smart,
        AtomKind::Fuzzy,
        false,
    );
    let mut symbols = Vec::new();
    let mut heap = BinaryHeap::new();
    let mut matched = 0;
    matcher.config = Config::DEFAULT.match_paths();
    for candidate in &catalog.entries {
        if task.obsolete() {
            return None;
        }
        symbols.clear();
        symbols.extend(
            candidate
                .label
                .graphemes(true)
                .map(|g| g.chars().next().unwrap()),
        );
        let Some(score) = atom.score(Utf32Str::Unicode(&symbols), matcher) else {
            continue;
        };
        matched += 1;
        heap.push(Ranked {
            score,
            candidate: candidate.clone(),
        });
        if heap.len() > task.source.limits.max_results {
            heap.pop();
        }
    }
    let mut ranked = heap.into_vec();
    ranked.sort();
    let mut rows = Vec::with_capacity(ranked.len());
    let mut indices = Vec::new();
    for item in ranked {
        if task.obsolete() {
            return None;
        }
        let candidate = item.candidate;
        let ranges: Vec<_> = candidate
            .label
            .grapheme_indices(true)
            .map(|(start, g)| start..start + g.len())
            .collect();
        symbols.clear();
        symbols.extend(
            candidate
                .label
                .graphemes(true)
                .map(|g| g.chars().next().unwrap()),
        );
        indices.clear();
        atom.indices(Utf32Str::Unicode(&symbols), matcher, &mut indices)?;
        indices.sort_unstable();
        indices.dedup();
        let highlights = indices
            .iter()
            .filter_map(|index| ranges.get(*index as usize).cloned())
            .collect();
        rows.push(MatchedCandidate {
            candidate,
            score: item.score,
            highlights,
        });
    }
    Some(PickerResults {
        rows,
        matched,
        truncated: catalog.truncated,
    })
}
