use super::{
    Direction, EditorModel, Language, Motion, commands,
    document::{DocumentId, DocumentUpdate, EditOrigin, SessionId},
    history::InputHistory,
    operations,
    search::SearchQuery,
};
use crate::core::{Change, EditError, EditorState, Selection, Transaction, UserEvent};
use std::time::{Duration, Instant};

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
    Move { motion: Motion, extend: bool },
    Delete { direction: Direction, smart: bool },
    DeleteWord(Direction),
    SelectAll,
    Goto { line: usize, column: usize },
    InsertTab,
    InsertLiteralTab,
    IndentSelection { outdent: bool },
    SetSearchQuery(SearchQuery),
    Find { backward: bool, wrap: bool },
    ReplaceCurrent(String),
    ReplaceAll(String),
    ReloadText(String),
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
    input_history: InputHistory,
    epoch: Instant,
}
impl Editor {
    pub fn new(text: impl Into<String>, language: impl Into<Language>) -> Self {
        Self::from_model(EditorModel::new(text, language))
    }
    pub fn from_model(model: EditorModel) -> Self {
        Self {
            model,
            input_history: InputHistory::default(),
            epoch: Instant::now(),
        }
    }
    pub(crate) fn checkpoint_history(&mut self) {
        self.model.document.break_group();
        self.input_history.isolate();
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
        self.execute_at(id, command, self.epoch.elapsed())
    }
    /// Explicit event time supports deterministic command replay and tests.
    pub fn execute_at(
        &mut self,
        id: SessionId,
        command: Command,
        time: Duration,
    ) -> Result<EditorUpdate, EditError> {
        let event = match &command {
            Command::TypeChar(ch) if !matches!(ch, '\n' | '\r') => Some(UserEvent::Input),
            Command::Delete {
                direction: Direction::Backward,
                ..
            } => Some(UserEvent::DeleteBackward),
            Command::Delete {
                direction: Direction::Forward,
                ..
            } => Some(UserEvent::DeleteForward),
            _ => None,
        };
        let preserves_explicit_group = matches!(&command, Command::Apply(_));
        let mut used_group = None;
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
                if language_changed {
                    for session in self.model.sessions.values_mut() {
                        session.goal_column = None;
                    }
                }
                None
            }
            Command::SelectAll => {
                self.model.set_selection(
                    id,
                    Selection {
                        anchor: 0,
                        head: state.snapshot().len_bytes(),
                    },
                )?;
                None
            }
            Command::Goto { line, column } => {
                let line = line.min(state.snapshot().line_count() - 1);
                let offset = crate::core::offset_at_logical_column(
                    state.snapshot(),
                    line,
                    crate::core::LogicalColumn(column),
                    self.model.document.language.whitespace().tab_width,
                )?;
                self.model.set_selection(id, Selection::caret(offset.0))?;
                None
            }
            Command::SetSelection(selection) => {
                self.model.set_selection(id, selection)?;
                None
            }
            Command::Move { motion, extend } => {
                let goal = self.model.session(id).unwrap().goal_column;
                let (selection, goal) = commands::move_selection(
                    &state,
                    motion,
                    extend,
                    goal,
                    &self.model.document.language,
                )?;
                self.model.set_selection(id, selection)?;
                self.model.sessions.get_mut(&id).unwrap().goal_column = goal;
                None
            }
            Command::SetSearchQuery(query) => {
                self.model.sessions.get_mut(&id).unwrap().search.query = Some(query);
                None
            }
            Command::Find { backward, wrap } => {
                if let Some(query) = self.model.session(id).unwrap().search.query()
                    && let Some(range) = super::search::find(
                        state.snapshot(),
                        query,
                        state.selection().range(),
                        backward,
                        wrap,
                    )
                {
                    self.model.set_selection(
                        id,
                        Selection {
                            anchor: range.start,
                            head: range.end,
                        },
                    )?;
                }
                None
            }
            command => {
                let mut prepared_language = None;
                let (mut tx, origin) = match command {
                    Command::InsertText(text) => {
                        (operations::prepare_insert(&state, text)?, EditOrigin::Paste)
                    }
                    Command::TypeChar(ch) => {
                        let mut language = self.model.document.language.clone();
                        let tx = operations::prepare_char(&state, ch, &mut language)?;
                        prepared_language = Some(language);
                        (tx, EditOrigin::Input)
                    }
                    Command::Enter => {
                        let mut language = self.model.document.language.clone();
                        let tx = operations::prepare_enter(&state, &mut language)?;
                        prepared_language = Some(language);
                        (tx, EditOrigin::Input)
                    }
                    Command::Reindent(line) => (
                        operations::prepare_reindent(
                            &state,
                            line,
                            &mut self.model.document.language,
                        )?,
                        EditOrigin::Reindent,
                    ),
                    Command::Delete { direction, smart } => (
                        commands::delete(&state, direction, smart, &self.model.document.language)?,
                        EditOrigin::Delete,
                    ),
                    Command::DeleteWord(direction) => (
                        commands::delete_word(&state, direction)?,
                        EditOrigin::Delete,
                    ),
                    Command::InsertTab => (
                        commands::insert_tab(&state, false, &self.model.document.language)?,
                        EditOrigin::Indent,
                    ),
                    Command::InsertLiteralTab => (
                        commands::insert_tab(&state, true, &self.model.document.language)?,
                        EditOrigin::Input,
                    ),
                    Command::IndentSelection { outdent } => (
                        commands::indent_selection(&state, outdent, &self.model.document.language),
                        EditOrigin::Indent,
                    ),
                    Command::ReplaceCurrent(text) => {
                        let selected = state.selection().range();
                        let matches =
                            self.model
                                .session(id)
                                .unwrap()
                                .search
                                .query()
                                .is_some_and(|query| {
                                    query.is_valid()
                                        && state
                                            .snapshot()
                                            .byte_slice(selected.clone())
                                            .is_some_and(|slice| slice == query.text())
                                });
                        (
                            if matches {
                                operations::prepare_insert(&state, text)?
                            } else {
                                Transaction::new(state.snapshot().version(), vec![])
                            },
                            EditOrigin::Replace,
                        )
                    }
                    Command::ReplaceAll(text) => {
                        let changes = self
                            .model
                            .session(id)
                            .unwrap()
                            .search
                            .query()
                            .map(|query| {
                                query
                                    .cursor(state.snapshot())
                                    .map(|range| Change::new(range, text.clone()))
                                    .collect()
                            })
                            .unwrap_or_default();
                        (
                            Transaction::new(state.snapshot().version(), changes),
                            EditOrigin::Replace,
                        )
                    }
                    Command::ReloadText(text) => {
                        let old = state.snapshot().text();
                        let prefix: usize = old
                            .chars()
                            .zip(text.chars())
                            .take_while(|(left, right)| left == right)
                            .map(|(ch, _)| ch.len_utf8())
                            .sum();
                        let suffix: usize = old[prefix..]
                            .chars()
                            .rev()
                            .zip(text[prefix..].chars().rev())
                            .take_while(|(left, right)| left == right)
                            .map(|(ch, _)| ch.len_utf8())
                            .sum();
                        let changes = if prefix == old.len() && prefix == text.len() {
                            vec![]
                        } else {
                            vec![Change::new(
                                prefix..old.len() - suffix,
                                &text[prefix..text.len() - suffix],
                            )]
                        };
                        (
                            Transaction::new(state.snapshot().version(), changes),
                            EditOrigin::Reload,
                        )
                    }
                    Command::Apply(tx) => (tx, EditOrigin::Transaction),
                    _ => unreachable!(),
                };
                if !tx.changes.is_empty()
                    && let Some(event) = event
                {
                    let group = self.input_history.plan(id, event, time, &state)?;
                    tx.history_group = Some(group);
                    tx.user_event = Some(event);
                    used_group = Some(group);
                }
                if tx.changes.is_empty() {
                    // Validation is shared with text transactions, but a selection
                    // update does not publish a new document revision or history.
                    let (next, _) = state.apply(tx)?;
                    self.model.set_selection(id, next.selection())?;
                    None
                } else {
                    let commit = self.model.document.commit(id, &state, tx, origin)?;
                    if let Some(language) = prepared_language {
                        self.model.document.language = language;
                    }
                    Some(commit)
                }
            }
        };
        if let Some(commit) = &commit {
            self.model.install(commit);
        }
        if let (Some(event), Some(group)) = (event, used_group) {
            self.input_history.record(
                id,
                event,
                time,
                self.model.session(id).unwrap().state(),
                group,
            );
        } else {
            self.input_history.isolate();
            if !preserves_explicit_group {
                self.model.document.break_group();
            }
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
