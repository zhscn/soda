//! Synchronous buffer selection. One row per document, including documents with
//! no view; confirming reuses a live view or creates one through Application.
use super::{
    Input, Presentation, Response, TextInput,
    picker::{Candidate, CandidateKey, CandidateListState, MatchedCandidate},
    session::{Transition, edit_field, field_presentation},
};
use crate::{
    application::{Application, Event},
    editor::DocumentId,
};
use std::{collections::BTreeMap, sync::Arc};

pub struct BufferSession {
    input: TextInput,
    rows: Vec<MatchedCandidate<DocumentId>>,
    list: CandidateListState,
    keys: BTreeMap<DocumentId, CandidateKey>,
    next_key: u64,
}
impl BufferSession {
    pub fn new(app: &Application) -> Self {
        let mut session = Self {
            input: TextInput::default(),
            rows: vec![],
            list: CandidateListState::default(),
            keys: BTreeMap::new(),
            next_key: 0,
        };
        session.refresh(app);
        session
    }
    pub fn input(&self) -> &TextInput {
        &self.input
    }
    pub fn rows(&self) -> &[MatchedCandidate<DocumentId>] {
        &self.rows
    }
    pub fn list(&self) -> &CandidateListState {
        &self.list
    }
    pub(super) fn resize(&mut self, rows: usize) {
        self.list.resize(&self.rows, rows);
    }
    fn refresh(&mut self, app: &Application) -> bool {
        let active = app
            .active_view()
            .and_then(|view| app.view(view))
            .map(|v| v.document_id);
        let query = self.input.text().to_lowercase();
        self.keys
            .retain(|id, _| app.workspace().editor(*id).is_some());
        let mut rows = Vec::new();
        for id in app.workspace().documents() {
            let key = *self.keys.entry(id).or_insert_with(|| {
                self.next_key += 1;
                CandidateKey(self.next_key)
            });
            let document = app.workspace().editor(id).unwrap().model().document();
            let name = document.file().path().map_or_else(
                || format!("[untitled {}]", key.0),
                |path| path.to_string_lossy().into_owned(),
            );
            if !name.to_lowercase().contains(&query) {
                continue;
            }
            let name: String = name
                .chars()
                .map(|c| if c.is_control() { '�' } else { c })
                .collect();
            let label = format!(
                "{}{}{}",
                if active == Some(id) { "* " } else { "  " },
                name,
                if document.is_dirty() { " [+]" } else { "" }
            );
            rows.push(MatchedCandidate {
                candidate: Arc::new(Candidate {
                    key,
                    label,
                    payload: id,
                }),
                score: 0,
                highlights: vec![],
            });
        }
        // Offer another buffer first while preserving document order within groups.
        rows.sort_by_key(|row| active == Some(row.candidate.payload));
        let changed = self.rows.len() != rows.len()
            || self.rows.iter().zip(&rows).any(|(old, new)| {
                old.candidate.key != new.candidate.key || old.candidate.label != new.candidate.label
            });
        if !changed {
            return false;
        }
        self.list.update(&self.rows, &rows);
        self.rows = rows;
        true
    }
    pub(super) fn observe(&mut self, app: &Application) -> Transition {
        Transition::active(Response {
            redraw: self.refresh(app),
            ..Response::default()
        })
    }
    pub(super) fn handle(&mut self, input: Input, app: &Application) -> Transition {
        match input {
            Input::Cancel => Transition::close(),
            Input::Confirm => {
                let Some(index) = self.list.index(&self.rows) else {
                    return Transition::redraw();
                };
                let document = self.rows[index].candidate.payload;
                if app.workspace().editor(document).is_none() {
                    return self.observe(app);
                }
                let active = app
                    .active_view()
                    .and_then(|id| app.view(id))
                    .filter(|v| v.document_id == document);
                let view = active.or_else(|| app.views().find(|v| v.document_id == document));
                Transition::finished(Response {
                    events: vec![view.map_or(Event::AddView(document), |v| Event::Focus(v.id))],
                    redraw: true,
                    ..Response::default()
                })
            }
            Input::Candidate { motion, wrap } => {
                if self.list.navigate(&self.rows, motion, wrap) {
                    Transition::redraw()
                } else {
                    Transition::Blocked
                }
            }
            input => match edit_field(&mut self.input, input) {
                Some(update) if update.text_changed => {
                    self.list.reset();
                    self.refresh(app);
                    self.list.update(&[], &self.rows);
                    Transition::redraw()
                }
                Some(update) if update.selection_changed => Transition::redraw(),
                _ => Transition::Blocked,
            },
        }
    }
    pub(super) fn presentation(&self) -> Presentation {
        let mut p = field_presentation("Switch buffer: ".into(), &self.input);
        if self.rows.is_empty() {
            p.text.push_str(" [no matches]");
        }
        p
    }
}
