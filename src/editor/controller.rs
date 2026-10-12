use super::{
    EditorModel, Language,
    document::{DocumentId, DocumentUpdate, EditOrigin, SessionId},
    operations,
};
use crate::core::{EditError, EditorState, Selection, Transaction};

#[derive(Clone, Debug)]
pub enum Command {
    InsertText(String),
    TypeChar(char),
    Enter,
    Reindent(usize),
    SetSelection(Selection),
    Apply(Transaction),
    SetLanguage(Language),
    Undo,
    Redo,
}
#[derive(Clone, Debug)]
pub struct SessionUpdate {
    pub session_id: SessionId,
    pub before: Selection,
    pub after: Selection,
}
#[derive(Clone, Debug)]
pub struct EditorUpdate {
    pub document_id: DocumentId,
    pub session_id: SessionId,
    pub config_generation: u64,
    pub text_revision: u64,
    pub text_changed: bool,
    pub selection_changed: bool,
    pub language_changed: bool,
    pub document: Option<DocumentUpdate>,
    pub sessions: Vec<SessionUpdate>,
}

/// Synchronous command controller with explicit session targeting. Frontends
/// observe updates; all text mutation and history are document-owned.
pub struct Editor {
    model: EditorModel,
}
impl Editor {
    pub fn new(text: impl Into<String>, language: impl Into<Language>) -> Self {
        Self::from_model(EditorModel::new(text, language))
    }
    pub fn from_model(model: EditorModel) -> Self {
        Self { model }
    }
    pub(crate) fn checkpoint_history(&mut self) {
        self.model.document.break_group();
    }
    pub(crate) fn bind_file(&mut self, file: crate::files::FileState) {
        self.model.document.file = file;
    }
    pub(crate) fn file_state_mut(&mut self) -> &mut crate::files::FileState {
        &mut self.model.document.file
    }
    pub fn model(&self) -> &EditorModel {
        &self.model
    }
    pub fn state(&self) -> &EditorState {
        self.model.state()
    }
    pub fn add_session(&mut self, selection: Selection) -> Result<SessionId, EditError> {
        self.model.add_session(selection)
    }
    /// The default session lives as long as the model; secondary sessions can close.
    pub fn close_session(&mut self, id: SessionId) -> Result<(), EditError> {
        if id == self.model.default_session() || self.model.sessions.remove(&id).is_none() {
            return Err(EditError::UnknownSession);
        }
        self.model.document.break_group();
        Ok(())
    }
    pub fn indentation(&mut self, line: usize) -> Result<crate::language::IndentAdvice, EditError> {
        self.model.indentation(line)
    }
    pub fn execute(&mut self, command: Command) -> Result<EditorUpdate, EditError> {
        self.execute_for(self.model.default_session(), command)
    }
    pub fn execute_for(
        &mut self,
        id: SessionId,
        command: Command,
    ) -> Result<EditorUpdate, EditError> {
        let state = self
            .model
            .session(id)
            .ok_or(EditError::UnknownSession)?
            .state()
            .clone();
        let before: Vec<_> = self
            .model
            .sessions()
            .map(|session| (session.id(), session.selection()))
            .collect();
        let mut language_changed = false;
        let commit = match command {
            Command::Undo => self.model.document.restore(id, false)?,
            Command::Redo => self.model.document.restore(id, true)?,
            Command::SetLanguage(language) => {
                language_changed = self.model.document.configure(language)?;
                None
            }
            Command::SetSelection(selection) => {
                self.model.set_selection(id, selection)?;
                None
            }
            command => {
                let (tx, origin) = match command {
                    Command::InsertText(text) => {
                        (operations::prepare_insert(&state, text), EditOrigin::Paste)
                    }
                    Command::TypeChar(ch) => (
                        operations::prepare_char(
                            &state,
                            ch,
                            &mut self.model.document.language.clone(),
                        )?,
                        EditOrigin::Input,
                    ),
                    Command::Enter => (
                        operations::prepare_enter(
                            &state,
                            &mut self.model.document.language.clone(),
                        )?,
                        EditOrigin::Input,
                    ),
                    Command::Reindent(line) => (
                        operations::prepare_reindent(
                            &state,
                            line,
                            &mut self.model.document.language,
                        )?,
                        EditOrigin::Reindent,
                    ),
                    Command::Apply(tx) => (tx, EditOrigin::Transaction),
                    _ => unreachable!(),
                };
                if tx.changes.is_empty() {
                    // Validation is shared with text transactions, but a selection
                    // update does not publish a new document revision or history.
                    let (next, _) = state.apply(tx)?;
                    self.model.set_selection(id, next.selection())?;
                    None
                } else {
                    Some(self.model.document.commit(id, &state, tx, origin)?)
                }
            }
        };
        if let Some(commit) = &commit {
            self.model.install(commit);
        }
        let sessions: Vec<_> = before
            .into_iter()
            .filter_map(|(session_id, before)| {
                let after = self.model.session(session_id).unwrap().selection();
                (before != after).then_some(SessionUpdate {
                    session_id,
                    before,
                    after,
                })
            })
            .collect();
        let selection_changed = sessions.iter().any(|update| update.session_id == id);
        let document = commit.map(|commit| commit.update);
        Ok(EditorUpdate {
            document_id: self.model.document.id(),
            session_id: id,
            config_generation: self.model.document.config_generation(),
            text_revision: self.model.text_revision(),
            text_changed: document.is_some(),
            selection_changed,
            language_changed,
            document,
            sessions,
        })
    }
    /// Reports each command outcome and continues after failed commands.
    pub fn run(
        &mut self,
        commands: impl IntoIterator<Item = Command>,
        mut observe: impl FnMut(&EditorModel, Result<EditorUpdate, EditError>),
    ) {
        for command in commands {
            let update = self.execute(command);
            observe(&self.model, update);
        }
    }
}
