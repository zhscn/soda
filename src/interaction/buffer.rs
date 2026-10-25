//! Synchronous buffer selection. One row per document, including documents with
//! no view; confirming reuses a live view or creates one through Application.
use super::{
    Input, Presentation, Response, TextInput,
    list::{ListInput, ListSession},
    picker::{CandidateKey, CandidateListState, MatchedCandidate},
    session::Transition,
};
use crate::{
    application::{Application, Event},
    editor::DocumentId,
};
use std::collections::BTreeMap;

pub struct BufferSession {
    list: ListSession<DocumentId>,
    keys: BTreeMap<DocumentId, CandidateKey>,
    next_key: u64,
}
impl BufferSession {
    pub fn new(app: &Application) -> Self {
        let mut session = Self {
            list: ListSession::new("Switch buffer: ", ""),
            keys: BTreeMap::new(),
            next_key: 0,
        };
        let rows = session.rows_for(app);
        session.list.set_rows(rows);
        session
    }
    pub fn input(&self) -> &TextInput {
        self.list.input()
    }
    pub fn rows(&self) -> &[MatchedCandidate<DocumentId>] {
        self.list.rows()
    }
    pub fn list(&self) -> &CandidateListState {
        self.list.list()
    }
    pub(super) fn resize(&mut self, rows: usize) {
        self.list.resize(rows);
    }
    fn rows_for(&mut self, app: &Application) -> Vec<(CandidateKey, String, DocumentId)> {
        let active = app
            .active_view()
            .and_then(|view| app.view(view))
            .map(|v| v.document_id);
        let query = self.list.query().to_lowercase();
        self.keys
            .retain(|id, _| app.workspace().editor(*id).is_some());
        let mut rows = Vec::new();
        for id in app.workspace().documents() {
            let key = *self.keys.entry(id).or_insert_with(|| {
                self.next_key += 1;
                CandidateKey(self.next_key)
            });
            let name = app.workspace().file(id).unwrap().path().map_or_else(
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
                if app.workspace().is_dirty(id) {
                    " [+]"
                } else {
                    ""
                }
            );
            rows.push((key, label, id));
        }
        // Offer another buffer first while preserving document order within groups.
        rows.sort_by_key(|row| active == Some(row.2));
        rows
    }
    pub(super) fn observe(&mut self, app: &Application) -> Transition {
        let rows = self.rows_for(app);
        Transition::active(Response {
            redraw: self.list.set_rows(rows),
            ..Response::default()
        })
    }
    pub(super) fn handle(&mut self, input: Input, app: &Application) -> Transition {
        match self.list.handle(input) {
            ListInput::Cancel => Transition::close(),
            ListInput::Accept(None) => Transition::redraw(),
            ListInput::Accept(Some(&document)) => {
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
            ListInput::Query => {
                let rows = self.rows_for(app);
                self.list.restart(rows);
                Transition::redraw()
            }
            ListInput::Redraw => Transition::redraw(),
            ListInput::Blocked => Transition::Blocked,
        }
    }
    pub(super) fn presentation(&self) -> Presentation {
        self.list.presentation()
    }
}
