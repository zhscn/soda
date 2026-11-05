use super::{Language, language::LanguageSession};
use crate::core::{
    Change, ChangeMap, EditError, EditorState, History, Selection, Snapshot, Transaction,
};
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct DocumentId(u64);
impl DocumentId {
    /// Stable number for display, such as naming untitled documents.
    pub fn number(self) -> u64 {
        self.0
    }
}
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
    newline: &'static str,
    /// Type brackets and quotes in pairs.
    pub(super) auto_pairs: bool,
    /// Reindent the line when a character the language names is typed.
    pub(super) electric_indent: bool,
}
impl Document {
    pub(super) fn new(text: impl Into<String>, language: Language) -> Self {
        static NEXT_ID: AtomicU64 = AtomicU64::new(1);
        let id = NEXT_ID
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .expect("document identities exhausted");
        let snapshot = EditorState::new(text).snapshot().clone();
        Self {
            id: DocumentId(id),
            newline: super::operations::detect_newline(&snapshot),
            auto_pairs: false,
            electric_indent: true,
            snapshot,
            language: LanguageSession::new(language),
            history: History::default(),
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
    /// The document's TextMate results, in languages that have them.
    pub fn tokens(&self) -> Option<&crate::syntax::Tokens> {
        self.language.tokens()
    }
    pub fn whitespace(&self) -> crate::language::WhitespacePolicy {
        self.language.whitespace()
    }
    /// The line terminator inserted by Enter, detected when text is loaded.
    pub fn newline(&self) -> &'static str {
        self.newline
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
    pub(super) fn set_whitespace(&mut self, policy: crate::language::WhitespacePolicy) -> bool {
        self.language.set_whitespace(policy)
    }
    pub(super) fn set_group_start(&mut self, owner: SessionId, before: Selection) {
        self.history.set_group_start(owner, before);
    }
    pub(super) fn finish_group(&mut self, owner: SessionId, after: Selection) {
        self.history.finish_group(owner, after);
    }
    /// Undo steps recorded so far, for `squash_history`.
    pub fn history_depth(&self) -> usize {
        self.history.depth()
    }
    pub(super) fn squash_history(&mut self, depth: usize) -> Result<(), crate::core::EditError> {
        self.history.squash(depth)
    }
    pub(super) fn break_group(&mut self) {
        self.history.break_group();
    }
    /// Drops every undo step, as a document starts with none.
    pub(super) fn forget_history(&mut self) {
        self.history = History::default();
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
        if origin == EditOrigin::Reload {
            self.newline = super::operations::detect_newline(&self.snapshot);
        }
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
