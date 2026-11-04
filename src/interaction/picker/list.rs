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
/// The selection over the rows and the input itself, as vertico's
/// `vertico--index`: `None` is the input, which Enter then takes as typed;
/// a key is a row, which Enter takes. A selection the user moved to is
/// locked: it stays on its row while the rows change, as long as the row
/// is there, as `vertico--lock-candidate` keeps it.
#[derive(Default, Debug)]
pub struct CandidateListState {
    selected: Option<CandidateKey>,
    user_selected: bool,
    first_visible: usize,
    page_size: usize,
}
impl CandidateListState {
    /// The selected row; None when the input is selected.
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
    /// Starts over on new rows at `default`: a row, or the input.
    pub fn reset<T>(&mut self, rows: &[MatchedCandidate<T>], default: Option<CandidateKey>) {
        self.user_selected = false;
        self.first_visible = 0;
        self.selected = default.filter(|key| rows.iter().any(|row| row.candidate.key == *key));
        self.reveal(rows);
    }
    /// Follows changed rows: a locked selection stays on its row, or on
    /// the input; one whose row is gone, and one never moved, go to
    /// `default`.
    pub fn update<T>(&mut self, new: &[MatchedCandidate<T>], default: Option<CandidateKey>) {
        let kept = self.user_selected
            && self
                .selected
                .is_none_or(|key| new.iter().any(|row| row.candidate.key == key));
        if !kept {
            self.user_selected = false;
            self.selected = default.filter(|key| new.iter().any(|row| row.candidate.key == *key));
        }
        self.reveal(new);
    }
    /// Selects the input, as by hand.
    pub fn select_input(&mut self) {
        self.selected = None;
        self.user_selected = true;
        self.first_visible = 0;
    }
    /// Moves the selection, as `vertico-next` and its kin: the input is a
    /// place before the first row when `prompt` allows it; `wrap` goes
    /// round past either end, through the input. First goes to the first
    /// row, and from there to the input.
    pub fn navigate<T>(
        &mut self,
        rows: &[MatchedCandidate<T>],
        motion: ListMotion,
        wrap: bool,
        prompt: bool,
    ) -> bool {
        if rows.is_empty() {
            return false;
        }
        let before = (self.selected, self.first_visible);
        let total = rows.len() as isize;
        // -1 is the input.
        let index = self.index(rows).map_or(-1, |i| i as isize);
        let page = self.page_size.max(1) as isize;
        let lowest = if prompt { -1 } else { 0 };
        let next = match motion {
            ListMotion::First if index > 0 => 0,
            ListMotion::First => -1,
            ListMotion::Last => total - 1,
            ListMotion::Previous | ListMotion::Next => {
                let step = if matches!(motion, ListMotion::Next) {
                    1
                } else {
                    -1
                };
                let next = index + step;
                match (wrap, prompt) {
                    (false, _) => next,
                    (true, true) => (next + 1).rem_euclid(total + 1) - 1,
                    (true, false) => next.rem_euclid(total),
                }
            }
            ListMotion::PagePrevious => (index - page).max(0),
            ListMotion::PageNext => index + page,
        };
        let next = next.clamp(lowest, total - 1);
        self.selected = usize::try_from(next).ok().map(|i| rows[i].candidate.key);
        self.user_selected = true;
        self.reveal(rows);
        before != (self.selected, self.first_visible)
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
}
