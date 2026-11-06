//! Jumps after flash.nvim: `flash` searches the lines every window shows
//! as the query is typed and labels each match; `flash-structure` labels
//! the bracket groups around the caret and selects one.
//!
//! A label is one character, and never one that follows any match: typed,
//! a character either is a label or goes on with the query, never both.
//! Labels go to the matches nearest the caret first and stay with a match
//! as the query grows; matches beyond the labels are only highlighted.
use crate::{
    application::{Application, ViewId},
    core::Selection,
    editor::DocumentId,
    language::Group,
};
use std::{collections::HashMap, ops::Range};

/// Search labels, home row first; their capitals follow.
const LABELS: &str = "asdfghjklqwertyuiopzxcvbnm";
/// Labels of the groups around the caret, innermost first.
pub(super) const GROUP_LABELS: &str = "abcdefghijklmnopqrstuvwxyz";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    pub view: ViewId,
    pub range: Range<usize>,
    /// The character after the match on its line.
    next: Option<char>,
    pub label: Option<char>,
}
pub struct Flash {
    active: ViewId,
    caret: usize,
    /// Windows searched with the rows they show, the active one first.
    windows: Vec<(ViewId, usize)>,
    query: String,
    /// In the order labels go to them.
    matches: Vec<Match>,
    /// Where Enter goes: the first match after the caret in the active
    /// window, or its first.
    current: Option<usize>,
    /// Labels matches had, to keep as the query grows.
    used: HashMap<(ViewId, usize), char>,
}
impl Flash {
    pub(super) fn new(active: ViewId, caret: usize, windows: Vec<(ViewId, usize)>) -> Self {
        Self {
            active,
            caret,
            windows,
            query: String::new(),
            matches: vec![],
            current: None,
            used: HashMap::new(),
        }
    }
    pub fn query(&self) -> &str {
        &self.query
    }
    pub fn matches(&self) -> &[Match] {
        &self.matches
    }
    /// The match Enter goes to.
    pub fn current(&self) -> Option<&Match> {
        self.current.map(|index| &self.matches[index])
    }
    /// Whether a window is searched, and so shows the backdrop.
    pub fn covers(&self, view: ViewId) -> bool {
        self.windows.iter().any(|(id, _)| *id == view)
    }
    /// The match a label stands for, once something has been typed.
    pub(super) fn labelled(&self, label: char) -> Option<&Match> {
        if self.query.is_empty() {
            return None;
        }
        self.matches.iter().find(|m| m.label == Some(label))
    }
    pub(super) fn push(&mut self, ch: char, app: &Application) {
        self.query.push(ch);
        self.update(app);
    }
    pub(super) fn pop(&mut self, app: &Application) {
        self.query.pop();
        self.update(app);
    }
    /// Where a match's label stands: on the character after it, which no
    /// label can be. None at the caret, which shows there already.
    pub(super) fn mark(&self, m: &Match) -> Option<usize> {
        (m.view != self.active || m.range.end != self.caret).then_some(m.range.end)
    }
    fn update(&mut self, app: &Application) {
        let query: Vec<char> = self.query.chars().collect();
        let fold = !self.query.chars().any(char::is_uppercase);
        let mut found = vec![];
        let mut seen: Vec<(DocumentId, Range<usize>)> = vec![];
        for (rank, (view, rows)) in self.windows.iter().enumerate() {
            let Some((document, lines)) = visible(app, *view, *rows) else {
                continue;
            };
            for (line, start, text) in lines {
                for (range, next) in occurrences(&text, &query, fold) {
                    let range = start + range.start..start + range.end;
                    // A place two windows show is labelled once.
                    if seen.contains(&(document, range.clone())) {
                        continue;
                    }
                    seen.push((document, range.clone()));
                    let distance = if rank == 0 {
                        let (caret_line, caret_column) = self.caret_place(app);
                        let at = |line: usize, column: usize| (line << 20) as i64 + column as i64;
                        at(line, range.start - start).abs_diff(at(caret_line, caret_column))
                    } else {
                        range.start as u64
                    };
                    found.push((
                        (rank, distance),
                        Match {
                            view: *view,
                            range,
                            next,
                            label: None,
                        },
                    ));
                }
            }
        }
        found.sort_by_key(|(key, _)| *key);
        self.matches = found.into_iter().map(|(_, m)| m).collect();
        label(&mut self.matches, &mut self.used, fold);
        let ours = || {
            self.matches
                .iter()
                .enumerate()
                .filter(|(_, m)| m.view == self.active)
        };
        self.current = ours()
            .filter(|(_, m)| m.range.start > self.caret)
            .min_by_key(|(_, m)| m.range.start)
            .or_else(|| ours().min_by_key(|(_, m)| m.range.start))
            .map(|(index, _)| index);
    }
    fn caret_place(&self, app: &Application) -> (usize, usize) {
        let snapshot = app
            .view(self.active)
            .and_then(|view| app.workspace().editor(view.document_id))
            .map(|editor| editor.model().document().snapshot());
        snapshot
            .and_then(|snapshot| {
                let line = snapshot.line_of(self.caret)?;
                Some((line, self.caret - snapshot.line_start(line)?))
            })
            .unwrap_or_default()
    }
}
/// A line shown: its number, its start and its text without the break.
type Shown = (usize, usize, String);
/// The lines a view shows, of its document.
fn visible(app: &Application, view: ViewId, rows: usize) -> Option<(DocumentId, Vec<Shown>)> {
    let state = app.view(view)?;
    let editor = app.workspace().editor(state.document_id)?;
    let snapshot = editor.model().document().snapshot();
    let top = snapshot
        .line_of(state.viewport.anchor.offset.0)
        .unwrap_or(0);
    let bottom = top.saturating_add(rows.max(1)).min(snapshot.text_lines());
    let lines = (top..bottom)
        .filter_map(|line| {
            let range = snapshot.line_content_range(line)?;
            let text = snapshot.byte_slice(range.clone())?.to_string();
            Some((line, range.start, text))
        })
        .collect();
    Some((state.document_id, lines))
}
/// Where `query` occurs in a line, overlaps too, with the character after
/// each. Folded, case is ignored.
fn occurrences(text: &str, query: &[char], fold: bool) -> Vec<(Range<usize>, Option<char>)> {
    if query.is_empty() {
        return vec![];
    }
    let same = |a: char, b: char| a == b || (fold && a.to_lowercase().eq(b.to_lowercase()));
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let mut found = vec![];
    for start in 0..chars.len() {
        let Some(window) = chars.get(start..start + query.len()) else {
            break;
        };
        if window.iter().zip(query).all(|((_, a), b)| same(*a, *b)) {
            let after = chars.get(start + query.len());
            let end = after.map_or(text.len(), |(at, _)| *at);
            found.push((chars[start].0..end, after.map(|(_, ch)| *ch)));
        }
    }
    found
}
/// Labels matches in their order: first those that had a label still
/// free, then the rest while labels last. A label never is a character
/// that follows a match, in either case when the query ignores case.
fn label(matches: &mut [Match], used: &mut HashMap<(ViewId, usize), char>, fold: bool) {
    let mut free: Vec<char> = LABELS
        .chars()
        .chain(LABELS.chars().map(|ch| ch.to_ascii_uppercase()))
        .filter(|label| {
            !matches.iter().any(|m| {
                m.next.is_some_and(|next| {
                    next == *label || (fold && next.to_lowercase().eq(label.to_lowercase()))
                })
            })
        })
        .collect();
    let take = |label: char, free: &mut Vec<char>| {
        let index = free.iter().position(|ch| *ch == label)?;
        Some(free.remove(index))
    };
    for m in matches.iter_mut() {
        if let Some(label) = used.get(&(m.view, m.range.start)) {
            m.label = take(*label, &mut free);
        }
    }
    for m in matches.iter_mut().filter(|m| m.label.is_none()) {
        let Some(label) = free.first().copied() else {
            break;
        };
        m.label = take(label, &mut free);
    }
    // Capitals are not kept: typing one would make the query match case.
    for m in matches.iter() {
        if let Some(label) = m.label.filter(char::is_ascii_lowercase) {
            used.insert((m.view, m.range.start), label);
        }
    }
}

/// The groups around the caret, from the innermost out, as flash.nvim's
/// Treesitter mode has the nodes around it.
pub struct Structure {
    pub view: ViewId,
    pub groups: Vec<Group>,
    /// The group selected now.
    pub current: usize,
    /// The selection to go back to on Esc.
    pub original: Selection,
}
impl Structure {
    /// The selection of a group, the way the original one ran.
    pub(super) fn selection(&self, index: usize) -> Selection {
        let range = self.groups[index].range();
        if self.original.anchor > self.original.head {
            Selection {
                anchor: range.end,
                head: range.start,
            }
        } else {
            Selection {
                anchor: range.start,
                head: range.end,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(text: &str, query: &str) -> Vec<(Range<usize>, Option<char>)> {
        let fold = !query.chars().any(char::is_uppercase);
        occurrences(text, &query.chars().collect::<Vec<_>>(), fold)
    }
    #[test]
    fn occurrences_overlap_and_fold_case_unless_asked() {
        assert_eq!(found("aaa", "aa"), [(0..2, Some('a')), (1..3, None)]);
        assert_eq!(
            found("Foo foo", "fo"),
            [(0..2, Some('o')), (4..6, Some('o'))]
        );
        assert_eq!(found("Foo foo", "Fo"), [(0..2, Some('o'))]);
        assert_eq!(found("é é", "é"), [(0..2, Some(' ')), (3..5, None)]);
        assert!(found("abc", "").is_empty());
    }
    fn m(start: usize, next: Option<char>) -> Match {
        Match {
            view: ViewId::for_test(1),
            range: start..start + 1,
            next,
            label: None,
        }
    }
    #[test]
    fn labels_skip_what_follows_a_match_and_stay_with_their_match() {
        let mut used = HashMap::new();
        // `a` and, folded, `S` follow a match: neither is a label.
        let mut matches = vec![m(0, Some('a')), m(5, Some('S')), m(9, None)];
        label(&mut matches, &mut used, true);
        let labels: Vec<_> = matches.iter().map(|m| m.label).collect();
        assert_eq!(labels, [Some('d'), Some('f'), Some('g')]);
        // Matched again, nearer ones first: each keeps its label.
        let mut matches = vec![m(9, None), m(0, Some('x'))];
        label(&mut matches, &mut used, true);
        let labels: Vec<_> = matches.iter().map(|m| m.label).collect();
        assert_eq!(labels, [Some('g'), Some('d')]);
        // Matching case, only the very character is skipped.
        let mut matches = vec![m(20, Some('A')), m(30, None)];
        label(&mut matches, &mut HashMap::new(), false);
        let labels: Vec<_> = matches.iter().map(|m| m.label).collect();
        assert_eq!(labels, [Some('a'), Some('s')]);
    }
    #[test]
    fn matches_beyond_the_labels_go_without() {
        let mut matches: Vec<_> = (0..60).map(|at| m(at * 2, Some(' '))).collect();
        label(&mut matches, &mut HashMap::new(), true);
        assert_eq!(matches.iter().filter(|m| m.label.is_some()).count(), 52);
        assert_eq!(matches[26].label, Some('A'));
        assert!(matches[52..].iter().all(|m| m.label.is_none()));
    }
}
