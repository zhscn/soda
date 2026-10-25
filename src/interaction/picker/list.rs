//! Candidate identity and selection are independent of text-input focus.
use std::ops::Range;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct CandidateKey(pub u64);
#[derive(Debug)]
pub struct Candidate<T> {
    pub key: CandidateKey,
    pub label: String,
    pub payload: T,
}
#[derive(Debug)]
pub struct MatchedCandidate<T> {
    pub candidate: Arc<Candidate<T>>,
    pub score: u16,
    pub highlights: Vec<Range<usize>>,
}
#[derive(Clone, Copy, Debug)]
pub enum ListMotion {
    Previous,
    Next,
    PagePrevious,
    PageNext,
    First,
    Last,
}
#[derive(Default, Debug)]
pub struct CandidateListState {
    selected: Option<CandidateKey>,
    user_selected: bool,
    first_visible: usize,
    page_size: usize,
}
impl CandidateListState {
    pub fn selected(&self) -> Option<CandidateKey> {
        self.selected
    }
    /// Whether the selection comes from explicit navigation, not a default.
    pub fn user_selected(&self) -> bool {
        self.user_selected
    }
    pub fn first_visible(&self) -> usize {
        self.first_visible
    }
    pub fn index<T>(&self, rows: &[MatchedCandidate<T>]) -> Option<usize> {
        rows.iter()
            .position(|row| Some(row.candidate.key) == self.selected)
    }
    pub fn reset(&mut self) {
        self.selected = None;
        self.user_selected = false;
        self.first_visible = 0;
    }
    pub fn update<T>(&mut self, old: &[MatchedCandidate<T>], new: &[MatchedCandidate<T>]) {
        let index = if self.user_selected {
            new.iter()
                .position(|row| Some(row.candidate.key) == self.selected)
                .unwrap_or_else(|| {
                    self.index(old)
                        .unwrap_or(0)
                        .min(new.len().saturating_sub(1))
                })
        } else {
            0
        };
        self.selected = new.get(index).map(|row| row.candidate.key);
        if new.is_empty() {
            self.user_selected = false;
        }
        self.reveal(new);
    }
    pub fn resize<T>(&mut self, rows: &[MatchedCandidate<T>], page_size: usize) -> bool {
        let before = (self.page_size, self.first_visible);
        self.page_size = page_size;
        self.reveal(rows);
        before != (self.page_size, self.first_visible)
    }
    fn reveal<T>(&mut self, rows: &[MatchedCandidate<T>]) {
        let Some(index) = self.index(rows) else {
            self.first_visible = 0;
            return;
        };
        let page = self.page_size.max(1);
        self.first_visible = self.first_visible.min(rows.len().saturating_sub(page));
        if index < self.first_visible {
            self.first_visible = index;
        } else if index >= self.first_visible.saturating_add(page) {
            self.first_visible = index + 1 - page;
        }
    }
    pub fn navigate<T>(
        &mut self,
        rows: &[MatchedCandidate<T>],
        motion: ListMotion,
        wrap: bool,
    ) -> bool {
        if rows.is_empty() {
            return false;
        }
        let before = (self.selected, self.first_visible);
        let index = self.index(rows).unwrap_or(0);
        let page = self.page_size.max(1);
        let last = rows.len() - 1;
        let next = match motion {
            ListMotion::First => 0,
            ListMotion::Last => last,
            ListMotion::Previous if wrap => (index + last) % rows.len(),
            ListMotion::Next if wrap => (index + 1) % rows.len(),
            ListMotion::Previous => index.saturating_sub(1),
            ListMotion::Next => (index + 1).min(last),
            ListMotion::PagePrevious if wrap => {
                (index + rows.len() - page % rows.len()) % rows.len()
            }
            ListMotion::PageNext if wrap => (index + page % rows.len()) % rows.len(),
            ListMotion::PagePrevious => index.saturating_sub(page),
            ListMotion::PageNext => index.saturating_add(page).min(last),
        };
        self.selected = Some(rows[next].candidate.key);
        self.user_selected = true;
        self.reveal(rows);
        before != (self.selected, self.first_visible)
    }
}
