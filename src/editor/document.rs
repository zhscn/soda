use super::{Language, language::LanguageSession};
use crate::core::{
    Change, ChangeMap, EditError, EditorState, History, Selection, Snapshot, Transaction,
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
    Delete,
    Indent,
    Replace,
    Reload,
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
pub(super) struct Commit {
    pub update: DocumentUpdate,
    pub restore_selection: (SessionId, Selection),
}

/// Shared text, history and language analysis. Session selections are separate.
pub struct Document {
    id: DocumentId,
    snapshot: Snapshot,
    pub(super) language: LanguageSession,
    history: History<SessionId>,
    config_generation: u64,
    pub(crate) file: crate::files::FileState,
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
            history: History::default(),
            config_generation: 0,
            file: crate::files::FileState::default(),
        }
    }
    pub fn file(&self) -> &crate::files::FileState {
        &self.file
    }
    pub fn is_dirty(&self) -> bool {
        self.file.is_dirty(&self.snapshot)
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
    pub fn whitespace(&self) -> crate::language::WhitespacePolicy {
        self.language.whitespace()
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
        self.history.break_group();
        Ok(true)
    }
    pub(super) fn break_group(&mut self) {
        self.history.break_group();
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
        self.history.record(owner, state, &next, &tx)?;
        let update = DocumentUpdate {
            document_id: self.id,
            session_id: owner,
            before_revision: self.snapshot.version(),
            after_revision: next.snapshot().version(),
            origin,
            changes: tx.changes,
            mapping,
        };
        self.snapshot = next.snapshot().clone();
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
        let Some(restored) = self.history.restore(&self.snapshot, redo)? else {
            return Ok(None);
        };
        let next = restored.state;
        let restore_selection = (restored.owner, next.selection());
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
            changes: restored.changes,
            mapping: restored.mapping,
        };
        self.snapshot = next.snapshot().clone();
        self.history.break_group();
        Ok(Some(Commit {
            update,
            restore_selection,
        }))
    }
}
