use super::{
    Language,
    document::{Commit, Document, SessionId},
};
use crate::{
    core::{EditError, EditorState, Selection},
    language::{IndentAdvice, IndentRequest, IndentTrigger},
};
use std::collections::BTreeMap;

/// A session-local editing projection. Its snapshot shares document storage;
/// the document is the sole owner of text mutation and history.
pub struct EditorSession {
    id: SessionId,
    state: EditorState,
}
impl EditorSession {
    pub fn id(&self) -> SessionId {
        self.id
    }
    pub fn state(&self) -> &EditorState {
        &self.state
    }
    pub fn selection(&self) -> Selection {
        self.state.selection()
    }
}

/// One shared document with independently addressable editing sessions.
pub struct EditorModel {
    pub(super) document: Document,
    pub(super) sessions: BTreeMap<SessionId, EditorSession>,
    default_session: SessionId,
}
impl EditorModel {
    pub fn new(text: impl Into<String>, language: impl Into<Language>) -> Self {
        let document = Document::new(text, language.into());
        let id = SessionId::allocate().expect("session identities exhausted");
        let state =
            EditorState::from_snapshot(document.snapshot().clone(), Selection::caret(0)).unwrap();
        Self {
            document,
            sessions: BTreeMap::from([(id, EditorSession { id, state })]),
            default_session: id,
        }
    }
    pub fn document(&self) -> &Document {
        &self.document
    }
    pub fn default_session(&self) -> SessionId {
        self.default_session
    }
    pub fn session(&self, id: SessionId) -> Option<&EditorSession> {
        self.sessions.get(&id)
    }
    pub fn sessions(&self) -> impl Iterator<Item = &EditorSession> {
        self.sessions.values()
    }
    pub fn state(&self) -> &EditorState {
        self.sessions[&self.default_session()].state()
    }
    pub fn text_revision(&self) -> u64 {
        self.document.snapshot().version()
    }
    pub fn language(&self) -> Language {
        self.document.language()
    }
    pub fn indentation(&mut self, line: usize) -> Result<IndentAdvice, EditError> {
        let position = self
            .document
            .snapshot()
            .line_start(line)
            .ok_or(EditError::InvalidRange)?;
        let snapshot = self.document.snapshot().clone();
        self.document.language.indent(
            &snapshot,
            IndentRequest {
                line,
                position,
                trigger: IndentTrigger::Reindent,
            },
        )
    }
    pub(super) fn add_session(&mut self, selection: Selection) -> Result<SessionId, EditError> {
        let state = EditorState::from_snapshot(self.document.snapshot().clone(), selection)?;
        let id = SessionId::allocate()?;
        self.sessions.insert(id, EditorSession { id, state });
        Ok(id)
    }
    pub(super) fn set_selection(
        &mut self,
        id: SessionId,
        selection: Selection,
    ) -> Result<(), EditError> {
        let state = EditorState::from_snapshot(self.document.snapshot().clone(), selection)?;
        self.sessions
            .get_mut(&id)
            .ok_or(EditError::UnknownSession)?
            .state = state;
        self.document.break_group();
        Ok(())
    }
    pub(super) fn install(&mut self, commit: &Commit) {
        for session in self.sessions.values_mut() {
            let selection = if session.id == commit.restore_selection.0 {
                commit.restore_selection.1
            } else {
                commit.update.mapping.map_selection(session.selection())
            };
            session.state = EditorState::from_snapshot(self.document.snapshot().clone(), selection)
                .expect("validated changes preserve session character boundaries");
        }
    }
}
