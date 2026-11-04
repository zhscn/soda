//! Per-document line cache with incremental updates, after IntelliJ's
//! `LexerEditorHighlighter` at line granularity: unchanged leading lines
//! keep their results, results after the edit are kept aside shifted by the
//! line delta, and scanning stops once a recomputed line start state equals
//! the kept one.
use super::{GrammarId, Registry, State};
use crate::{core::Snapshot, syntax::Category};
use std::ops::Range;

type Runs = Vec<(Range<usize>, Category)>;
struct Tail {
    /// New line number of `starts[0]`.
    first: usize,
    starts: Vec<State>,
    runs: Vec<Runs>,
}
pub(in crate::syntax) struct Lines {
    grammar: GrammarId,
    snapshot: Option<Snapshot>,
    /// `starts[i]` is the state at the start of line i; one longer than
    /// `runs`, whose entries are the categories of computed lines.
    starts: Vec<State>,
    runs: Vec<Runs>,
    tail: Option<Tail>,
}
impl Lines {
    pub fn new(registry: &Registry, grammar: GrammarId) -> Self {
        Self {
            grammar,
            snapshot: None,
            starts: vec![State::new(registry, grammar)],
            runs: vec![],
            tail: None,
        }
    }
    /// Lines whose results are currently cached, for tests.
    #[cfg(test)]
    pub fn computed(&self) -> usize {
        self.runs.len()
    }
    pub fn update(&mut self, snapshot: &Snapshot) {
        let Some(old) = self.snapshot.replace(snapshot.clone()) else {
            return;
        };
        if old.content_eq(snapshot) {
            return;
        }
        let (old_count, new_count) = (old.line_count(), snapshot.line_count());
        // Byte-level common prefix and suffix, as the C++ relexer does;
        // comparing whole lines would walk the file on every keystroke.
        let (a, b) = (old.shared_text(), snapshot.shared_text());
        let (a, b) = (a.as_bytes(), b.as_bytes());
        let common = a.iter().zip(b).take_while(|(x, y)| x == y).count();
        let shorter = a.len().min(b.len()) - common;
        let trailing = a[a.len() - shorter..]
            .iter()
            .rev()
            .zip(b[b.len() - shorter..].iter().rev())
            .take_while(|(x, y)| x == y)
            .count();
        // Lines before the one holding the first change are unchanged.
        let prefix = old.line_of(common).unwrap_or(old_count);
        // Lines starting inside the common suffix are unchanged.
        let boundary = a.len() - trailing;
        let line = old.line_of(boundary).unwrap_or(old_count);
        let old_first = if old.line_start(line) == Some(boundary) {
            line
        } else {
            line + 1
        };
        let suffix = old_count
            .saturating_sub(old_first)
            .min(new_count - prefix.min(new_count));
        let computed = self.runs.len();
        let keep = prefix.min(computed);
        let old_first = old_count - suffix;
        // Move, not copy, the results after the edit; `keep` never exceeds
        // `old_first`, since unchanged leading and trailing lines are disjoint.
        self.tail = (suffix > 0 && old_first <= computed).then(|| Tail {
            first: new_count - suffix,
            starts: self.starts.split_off(old_first),
            runs: self.runs.split_off(old_first),
        });
        self.runs.truncate(keep);
        self.starts.truncate(keep + 1);
        if self.starts.len() == keep {
            // The edit begins exactly where the kept lines start; their
            // first start state is still the state after the prefix.
            let first = self.tail.as_ref().unwrap().starts[0].clone();
            self.starts.push(first);
        }
    }
    /// Category runs of `lines`, relative to each line's start. Scanning
    /// stops after `budget`; lines not reached yet come back empty and
    /// `complete` reports whether all were reached.
    #[cfg(test)]
    pub fn highlights(
        &mut self,
        registry: &mut Registry,
        snapshot: &Snapshot,
        lines: Range<usize>,
    ) -> Vec<Runs> {
        self.highlights_within(registry, snapshot, lines, None)
    }
    pub fn highlights_within(
        &mut self,
        registry: &mut Registry,
        snapshot: &Snapshot,
        lines: Range<usize>,
        budget: Option<std::time::Duration>,
    ) -> Vec<Runs> {
        if self.snapshot.is_none() {
            self.snapshot = Some(snapshot.clone());
        }
        let end = lines.end.min(snapshot.line_count());
        let started = std::time::Instant::now();
        while self.runs.len() < end {
            if self.runs.len().is_multiple_of(64) && budget.is_some_and(|b| started.elapsed() > b) {
                break;
            }
            let line = self.runs.len();
            let mut state = self.starts[line].clone();
            let text = snapshot.line(line).unwrap_or_default();
            self.runs
                .push(registry.scan_line(self.grammar, &text, &mut state));
            self.starts.push(state);
            self.adopt_tail();
        }
        let start = lines.start.min(end);
        (start..end)
            .map(|line| self.runs.get(line).cloned().unwrap_or_default())
            .collect()
    }
    /// See `Tokens::in_literal`. A position between two characters has no
    /// category of its own, and an end of line closes some literals but not
    /// others, so a probe character is scanned in the position's place: it
    /// falls outside a string that just ended and inside one still open.
    /// Literals that grammars match whole need their end, so the runs of
    /// the line itself count too. A line not reached within `budget` counts
    /// as code; what was scanned stays for the next request.
    pub fn in_literal(
        &mut self,
        registry: &mut Registry,
        snapshot: &Snapshot,
        position: usize,
        budget: Option<std::time::Duration>,
    ) -> bool {
        let Some(line) = snapshot.line_of(position) else {
            return false;
        };
        self.highlights_within(registry, snapshot, line..line + 1, budget);
        let (Some(runs), Some(start), Some(text), Some(line_start)) = (
            self.runs.get(line),
            self.starts.get(line),
            snapshot.line(line),
            snapshot.line_start(line),
        ) else {
            return false;
        };
        let column = position - line_start;
        let literal = |category: &Category| {
            matches!(
                category.root(),
                Category::Comment | Category::String | Category::Escape
            )
        };
        if runs.iter().any(|(range, category)| {
            literal(category) && range.start < column && column < range.end
        }) {
            return true;
        }
        let probe = format!("{}x", &text[..column.min(text.len())]);
        let mut state = start.clone();
        registry
            .scan_line(self.grammar, &probe, &mut state)
            .iter()
            .any(|(range, category)| literal(category) && range.contains(&column))
    }
    pub fn complete(&self, lines: &Range<usize>, snapshot: &Snapshot) -> bool {
        self.runs.len() >= lines.end.min(snapshot.line_count())
    }
    /// Reuses the kept results once the next line starts in the same state.
    fn adopt_tail(&mut self) {
        let Some(tail) = &self.tail else {
            return;
        };
        let next = self.runs.len();
        if next < tail.first {
            return;
        }
        let index = next - tail.first;
        if index >= tail.starts.len() {
            self.tail = None;
            return;
        }
        if tail.starts[index] == self.starts[next] {
            let tail = self.tail.take().unwrap();
            if index < tail.runs.len() {
                self.runs.extend_from_slice(&tail.runs[index..]);
                self.starts.extend_from_slice(&tail.starts[index + 1..]);
            }
        }
    }
}
