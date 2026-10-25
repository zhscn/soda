use super::{
    Direction, EditorModel, Language, Motion, commands,
    document::{Commit, DocumentId, DocumentUpdate, EditOrigin, SessionId},
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
    BeginUndoGroup(Selection),
    EndUndoGroup(Selection),
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
        self.input_history.end();
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
        // Input history is staged and installed only when the command succeeds.
        let mut history = self.input_history.clone();
        let event = match &command {
            Command::TypeChar(ch) if !matches!(ch, '\n' | '\r') => Some(UserEvent::Input),
            Command::Delete { direction, .. } => Some(match direction {
                Direction::Backward => UserEvent::DeleteBackward,
                Direction::Forward => UserEvent::DeleteForward,
            }),
            _ => None,
        };
        history.owner_changed(id);
        if matches!(
            &command,
            Command::SetSelection(_)
                | Command::Move { .. }
                | Command::Undo
                | Command::Redo
                | Command::EndUndoGroup(_)
                | Command::SetLanguage(_)
                | Command::ReloadText(_)
        ) {
            history.end();
        }
        let preserves_explicit_group =
            matches!(&command, Command::Apply(_) | Command::BeginUndoGroup(_))
                || history.compound(id).is_some();
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
        let mut used_group = None;
        let commit = match self.step(id, &state, command, &mut history, &mut language_changed)? {
            Step::Done(commit) => commit,
            Step::Edit {
                mut tx,
                origin,
                language,
            } => {
                let compound = history.compound(id);
                if !tx.changes.is_empty() {
                    if let Some(group) = compound {
                        tx.history_group = Some(group);
                        tx.user_event = None;
                    } else if let Some(event) = event {
                        let group = history.plan(id, event, time, &state)?;
                        tx.history_group = Some(group);
                        tx.user_event = Some(event);
                        used_group = Some(group);
                    }
                }
                self.commit_edit(id, &state, tx, origin, language, compound.is_some())?
            }
        };
        if let Some(commit) = &commit {
            if let Some(before) = history.take_start(id) {
                self.model.document.set_group_start(id, before);
            }
            self.model.install(commit);
        }
        if let (Some(event), Some(group)) = (event, used_group) {
            history.record(
                id,
                event,
                time,
                self.model.session(id).unwrap().state(),
                group,
            );
        } else {
            history.isolate();
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
        self.input_history = history;
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
    /// Session, history and configuration commands apply directly; text
    /// commands only plan a transaction against `state`.
    fn step(
        &mut self,
        id: SessionId,
        state: &EditorState,
        command: Command,
        history: &mut InputHistory,
        language_changed: &mut bool,
    ) -> Result<Step, EditError> {
        let document = &mut self.model.document;
        let edit = |tx, origin| Step::Edit {
            tx,
            origin,
            language: None,
        };
        Ok(match command {
            Command::BeginUndoGroup(selection) => {
                EditorState::from_snapshot(document.snapshot().clone(), selection)?;
                history.begin(id, selection)?;
                document.break_group();
                Step::Done(None)
            }
            Command::EndUndoGroup(selection) => {
                EditorState::from_snapshot(document.snapshot().clone(), selection)?;
                document.finish_group(id, selection);
                self.model.set_selection(id, selection)?;
                Step::Done(None)
            }
            Command::Undo => Step::Done(document.restore(id, false)?),
            Command::Redo => Step::Done(document.restore(id, true)?),
            Command::SetLanguage(language) => {
                *language_changed = document.configure(language)?;
                if *language_changed {
                    for session in self.model.sessions.values_mut() {
                        session.goal_column = None;
                    }
                }
                Step::Done(None)
            }
            Command::SelectAll => {
                let selection = Selection {
                    anchor: 0,
                    head: state.snapshot().len_bytes(),
                };
                self.model.set_selection(id, selection)?;
                Step::Done(None)
            }
            Command::Goto { line, column } => {
                let line = line.min(state.snapshot().line_count() - 1);
                let offset = crate::core::offset_at_logical_column(
                    state.snapshot(),
                    line,
                    crate::core::LogicalColumn(column),
                    document.language.whitespace().tab_width,
                )?;
                self.model.set_selection(id, Selection::caret(offset.0))?;
                Step::Done(None)
            }
            Command::SetSelection(selection) => {
                self.model.set_selection(id, selection)?;
                Step::Done(None)
            }
            Command::Move { motion, extend } => {
                let goal = self.model.session(id).unwrap().goal_column;
                let language = &self.model.document.language;
                let (selection, goal) =
                    commands::move_selection(state, motion, extend, goal, language)?;
                self.model.set_selection(id, selection)?;
                self.model.sessions.get_mut(&id).unwrap().goal_column = goal;
                Step::Done(None)
            }
            Command::SetSearchQuery(query) => {
                self.model.sessions.get_mut(&id).unwrap().search.query = Some(query);
                Step::Done(None)
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
                    let selection = Selection {
                        anchor: range.start,
                        head: range.end,
                    };
                    self.model.set_selection(id, selection)?;
                }
                Step::Done(None)
            }
            // Typed input and Enter plan against a speculative language session
            // that is installed only if the transaction commits.
            Command::TypeChar(ch) => {
                let mut language = document.language.clone();
                let tx = operations::prepare_char(state, ch, &mut language)?;
                Step::Edit {
                    tx,
                    origin: EditOrigin::Input,
                    language: Some(language),
                }
            }
            Command::Enter => {
                let mut language = document.language.clone();
                let tx = operations::prepare_enter(state, document.newline(), &mut language)?;
                Step::Edit {
                    tx,
                    origin: EditOrigin::Input,
                    language: Some(language),
                }
            }
            Command::InsertText(text) => {
                edit(operations::prepare_insert(state, text)?, EditOrigin::Paste)
            }
            Command::Reindent(line) => edit(
                operations::prepare_reindent(state, line, &mut document.language)?,
                EditOrigin::Reindent,
            ),
            Command::Delete { direction, smart } => edit(
                commands::delete(state, direction, smart, &document.language)?,
                EditOrigin::Delete,
            ),
            Command::DeleteWord(direction) => {
                edit(commands::delete_word(state, direction)?, EditOrigin::Delete)
            }
            Command::InsertTab => edit(
                commands::insert_tab(state, false, &document.language)?,
                EditOrigin::Indent,
            ),
            Command::InsertLiteralTab => edit(
                commands::insert_tab(state, true, &document.language)?,
                EditOrigin::Input,
            ),
            Command::IndentSelection { outdent } => edit(
                commands::indent_selection(state, outdent, &document.language),
                EditOrigin::Indent,
            ),
            Command::ReplaceCurrent(text) => {
                let query = self.model.session(id).unwrap().search.query();
                edit(replace_current(state, query, text)?, EditOrigin::Replace)
            }
            Command::ReplaceAll(text) => {
                let query = self.model.session(id).unwrap().search.query();
                edit(replace_all(state, query, &text), EditOrigin::Replace)
            }
            Command::ReloadText(text) => edit(reload(state, &text), EditOrigin::Reload),
            Command::Apply(tx) => edit(tx, EditOrigin::Transaction),
        })
    }
    /// Commits text changes, or applies a selection-only result.
    fn commit_edit(
        &mut self,
        id: SessionId,
        state: &EditorState,
        tx: Transaction,
        origin: EditOrigin,
        language: Option<super::language::LanguageSession>,
        in_group: bool,
    ) -> Result<Option<Commit>, EditError> {
        if tx.changes.is_empty() {
            // Validation is shared with text transactions, but a selection
            // update does not publish a new document revision or history.
            let (next, _) = state.apply(tx)?;
            if in_group {
                self.model.set_selection_in_group(id, next.selection())?;
            } else {
                self.model.set_selection(id, next.selection())?;
            }
            return Ok(None);
        }
        let commit = self.model.document.commit(id, state, tx, origin)?;
        if let Some(language) = language {
            self.model.document.language = language;
        }
        Ok(Some(commit))
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

enum Step {
    Done(Option<Commit>),
    Edit {
        tx: Transaction,
        origin: EditOrigin,
        language: Option<super::language::LanguageSession>,
    },
}
/// Replaces the selection only while it is the current search match.
fn replace_current(
    state: &EditorState,
    query: Option<&SearchQuery>,
    text: String,
) -> Result<Transaction, EditError> {
    let selected = state.selection().range();
    let matches = query.is_some_and(|query| {
        query.is_valid()
            && state
                .snapshot()
                .byte_slice(selected)
                .is_some_and(|slice| slice == query.text())
    });
    if matches {
        operations::prepare_insert(state, text)
    } else {
        Ok(Transaction::new(state.snapshot().version(), vec![]))
    }
}
fn replace_all(state: &EditorState, query: Option<&SearchQuery>, text: &str) -> Transaction {
    let changes = query
        .map(|query| {
            query
                .cursor(state.snapshot())
                .map(|range| Change::new(range, text))
                .collect()
        })
        .unwrap_or_default();
    Transaction::new(state.snapshot().version(), changes)
}
/// Replaces only the differing middle so unchanged text keeps its positions.
fn reload(state: &EditorState, text: &str) -> Transaction {
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
    Transaction::new(state.snapshot().version(), changes)
}
