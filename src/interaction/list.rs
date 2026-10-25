//! Synchronous filtered lists: a query field over rows the owner supplies.
//! The buffer switcher and the command palette interpret acceptance.
use super::{
    Input, Presentation, TextInput,
    picker::{Candidate, CandidateKey, CandidateListState, MatchedCandidate},
    session::{edit_field, field_presentation},
};
use std::sync::Arc;

pub(super) enum ListInput<'a, T> {
    Cancel,
    /// Confirm with the selected payload; None while no row matches.
    Accept(Option<&'a T>),
    /// The query changed; the owner supplies new rows.
    Query,
    Redraw,
    Blocked,
}
pub struct ListSession<T> {
    label: &'static str,
    input: TextInput,
    rows: Vec<MatchedCandidate<T>>,
    list: CandidateListState,
}
impl<T> ListSession<T> {
    pub(super) fn new(label: &'static str, text: &str) -> Self {
        Self {
            label,
            input: TextInput::new(text),
            rows: vec![],
            list: CandidateListState::default(),
        }
    }
    pub fn input(&self) -> &TextInput {
        &self.input
    }
    pub fn rows(&self) -> &[MatchedCandidate<T>] {
        &self.rows
    }
    pub fn list(&self) -> &CandidateListState {
        &self.list
    }
    pub(super) fn query(&self) -> &str {
        self.input.text()
    }
    pub(super) fn resize(&mut self, rows: usize) {
        self.list.resize(&self.rows, rows);
    }
    /// Replaces the rows, keeping the selected identity; returns whether the
    /// visible list changed.
    pub(super) fn set_rows(&mut self, rows: Vec<(CandidateKey, String, T)>) -> bool {
        let rows: Vec<_> = rows
            .into_iter()
            .map(|(key, label, payload)| MatchedCandidate {
                candidate: Arc::new(Candidate {
                    key,
                    label,
                    payload,
                }),
                score: 0,
                highlights: vec![],
            })
            .collect();
        let changed = self.rows.len() != rows.len()
            || self.rows.iter().zip(&rows).any(|(old, new)| {
                old.candidate.key != new.candidate.key || old.candidate.label != new.candidate.label
            });
        if changed {
            self.list.update(&self.rows, &rows);
            self.rows = rows;
        }
        changed
    }
    /// A new query selects its first row instead of keeping the old choice.
    pub(super) fn restart(&mut self, rows: Vec<(CandidateKey, String, T)>) {
        self.list.reset();
        self.set_rows(rows);
        self.list.update(&[], &self.rows);
    }
    pub(super) fn handle(&mut self, input: Input) -> ListInput<'_, T> {
        match input {
            Input::Cancel => ListInput::Cancel,
            Input::Confirm => ListInput::Accept(
                self.list
                    .index(&self.rows)
                    .map(|index| &self.rows[index].candidate.payload),
            ),
            Input::Candidate { motion, wrap } => {
                if self.list.navigate(&self.rows, motion, wrap) {
                    ListInput::Redraw
                } else {
                    ListInput::Blocked
                }
            }
            input => match edit_field(&mut self.input, input) {
                Some(update) if update.text_changed => ListInput::Query,
                Some(update) if update.selection_changed => ListInput::Redraw,
                _ => ListInput::Blocked,
            },
        }
    }
    pub(super) fn presentation(&self) -> Presentation {
        let mut p = field_presentation(self.label.into(), &self.input);
        if self.rows.is_empty() {
            p.text.push_str(" [no matches]");
        }
        p
    }
}
