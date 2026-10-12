use super::{Language, language::LanguageSession};
use crate::core::{
    Change, ChangeMap, EditError, EditorState, Selection, Snapshot, Transaction, compose_changes,
    invert_changes,
};
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct DocumentId(u64);
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct SessionId(u64);
impl SessionId {
    pub(super) fn allocate() -> Result<Self, EditError> {
        static NEXT_ID: AtomicU64 = AtomicU64::new(1);
        NEXT_ID
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .map(Self)
            .map_err(|_| EditError::VersionExhausted)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EditOrigin {
    Input,
    Paste,
    Reindent,
    Transaction,
    Undo,
    Redo,
}

#[derive(Clone, Debug)]
pub struct DocumentUpdate {
    pub document_id: DocumentId,
    pub session_id: SessionId,
    pub before_revision: u64,
    pub after_revision: u64,
    pub origin: EditOrigin,
    pub changes: Vec<Change>,
    pub mapping: ChangeMap,
}
struct HistoryEntry {
    base: Snapshot,
    forward: Vec<Change>,
    inverse: Vec<Change>,
    owner: SessionId,
    before_selection: Selection,
    after_selection: Selection,
}
pub(super) struct Commit {
    pub update: DocumentUpdate,
    pub restore_selection: (SessionId, Selection),
}

/// Shared text, history and language analysis. Session selections are separate.
pub struct Document {
    id: DocumentId,
    snapshot: Snapshot,
    pub(super) language: LanguageSession,
    undo: Vec<HistoryEntry>,
    redo: Vec<HistoryEntry>,
    group: Option<(SessionId, u64)>,
    config_generation: u64,
}
impl Document {
    pub(super) fn new(text: impl Into<String>, language: Language) -> Self {
        static NEXT_ID: AtomicU64 = AtomicU64::new(1);
        let id = NEXT_ID
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .expect("document identities exhausted");
        Self {
            id: DocumentId(id),
            snapshot: EditorState::new(text).snapshot().clone(),
            language: LanguageSession::new(language),
            undo: vec![],
            redo: vec![],
            group: None,
            config_generation: 0,
        }
    }
    pub fn id(&self) -> DocumentId {
        self.id
    }
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }
    pub fn language(&self) -> Language {
        self.language.description()
    }
    pub fn config_generation(&self) -> u64 {
        self.config_generation
    }
    pub(super) fn configure(&mut self, language: Language) -> Result<bool, EditError> {
        if self.language() == language {
            return Ok(false);
        }
        let generation = self
            .config_generation
            .checked_add(1)
            .ok_or(EditError::VersionExhausted)?;
        self.language.configure(language);
        self.config_generation = generation;
        self.group = None;
        Ok(true)
    }
    pub(super) fn break_group(&mut self) {
        self.group = None;
    }
    pub(super) fn commit(
        &mut self,
        owner: SessionId,
        state: &EditorState,
        mut tx: Transaction,
        origin: EditOrigin,
    ) -> Result<Commit, EditError> {
        tx.changes.sort_by_key(|change| change.range.start);
        let (next, mapping) = state.apply(tx.clone())?;
        let group = tx.history_group.map(|group| (owner, group));
        let merge = group.is_some() && self.group == group;
        let entry = if merge {
            let previous = self.undo.last().unwrap();
            let forward = compose_changes(&previous.base, &previous.forward, &tx.changes)?;
            HistoryEntry {
                inverse: invert_changes(&previous.base, &forward),
                base: previous.base.clone(),
                forward,
                owner,
                before_selection: previous.before_selection,
                after_selection: next.selection(),
            }
        } else {
            HistoryEntry {
                base: self.snapshot.for_history(),
                inverse: invert_changes(&self.snapshot, &tx.changes),
                forward: tx.changes.clone(),
                owner,
                before_selection: state.selection(),
                after_selection: next.selection(),
            }
        };
        let update = DocumentUpdate {
            document_id: self.id,
            session_id: owner,
            before_revision: self.snapshot.version(),
            after_revision: next.snapshot().version(),
            origin,
            changes: tx.changes,
            mapping,
        };
        if merge {
            self.undo.pop();
        }
        self.undo.push(entry);
        self.redo.clear();
        self.group = group;
        self.snapshot = next.snapshot().clone();
        self.language.invalidate();
        Ok(Commit {
            update,
            restore_selection: (owner, next.selection()),
        })
    }
    pub(super) fn restore(
        &mut self,
        requester: SessionId,
        redo: bool,
    ) -> Result<Option<Commit>, EditError> {
        let source = if redo { &self.redo } else { &self.undo };
        let Some(entry) = source.last() else {
            return Ok(None);
        };
        let changes = if redo { &entry.forward } else { &entry.inverse };
        let state = EditorState::from_snapshot(self.snapshot.clone(), Selection::caret(0))?;
        let (next, mapping) =
            state.apply(Transaction::new(self.snapshot.version(), changes.clone()))?;
        let restore_selection = (
            entry.owner,
            if redo {
                entry.after_selection
            } else {
                entry.before_selection
            },
        );
        let update = DocumentUpdate {
            document_id: self.id,
            session_id: requester,
            before_revision: self.snapshot.version(),
            after_revision: next.snapshot().version(),
            origin: if redo {
                EditOrigin::Redo
            } else {
                EditOrigin::Undo
            },
            changes: changes.clone(),
            mapping,
        };
        let entry = if redo {
            self.redo.pop().unwrap()
        } else {
            self.undo.pop().unwrap()
        };
        if redo {
            self.undo.push(entry);
        } else {
            self.redo.push(entry);
        }
        self.snapshot = next.snapshot().clone();
        self.group = None;
        self.language.invalidate();
        Ok(Some(Commit {
            update,
            restore_selection,
        }))
    }
}
