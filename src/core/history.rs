use super::{
    Change, ChangeMap, EditError, EditorState, Selection, Snapshot, Transaction, compose_changes,
    invert_changes,
};

struct Entry<Owner> {
    base: Snapshot,
    forward: Vec<Change>,
    inverse: Vec<Change>,
    owner: Owner,
    before: Selection,
    after: Selection,
}
/// Shared history algorithm. Owners provide identity; history only handles
/// edit grouping, inverse changes and branch transitions.
pub(crate) struct History<Owner> {
    undo: Vec<Entry<Owner>>,
    redo: Vec<Entry<Owner>>,
    group: Option<(Owner, u64)>,
}
impl<Owner> Default for History<Owner> {
    fn default() -> Self {
        Self {
            undo: vec![],
            redo: vec![],
            group: None,
        }
    }
}
pub(crate) struct HistoryRestore<Owner> {
    pub state: EditorState,
    pub changes: Vec<Change>,
    pub mapping: ChangeMap,
    pub owner: Owner,
}
impl<Owner: Copy + Eq> History<Owner> {
    pub fn break_group(&mut self) {
        self.group = None;
    }
    /// Called only after the transaction and its result selection validate.
    /// Failure leaves both branches intact.
    pub fn record(
        &mut self,
        owner: Owner,
        before: &EditorState,
        after: &EditorState,
        tx: &Transaction,
    ) -> Result<(), EditError> {
        let group = tx.history_group.map(|id| (owner, id));
        let merge = group.is_some() && self.group == group;
        let entry = if merge {
            let previous = self.undo.last().unwrap();
            let forward = compose_changes(&previous.base, &previous.forward, &tx.changes)?;
            Entry {
                inverse: invert_changes(&previous.base, &forward),
                base: previous.base.clone(),
                forward,
                owner,
                before: previous.before,
                after: after.selection(),
            }
        } else {
            Entry {
                base: before.snapshot().for_history(),
                forward: tx.changes.clone(),
                inverse: invert_changes(before.snapshot(), &tx.changes),
                owner,
                before: before.selection(),
                after: after.selection(),
            }
        };
        if merge {
            self.undo.pop();
        }
        self.undo.push(entry);
        self.redo.clear();
        self.group = group;
        Ok(())
    }
    pub fn restore(
        &mut self,
        snapshot: &Snapshot,
        redo: bool,
    ) -> Result<Option<HistoryRestore<Owner>>, EditError> {
        let source = if redo { &self.redo } else { &self.undo };
        let Some(entry) = source.last() else {
            return Ok(None);
        };
        let changes = if redo { &entry.forward } else { &entry.inverse };
        let mut tx = Transaction::new(snapshot.version(), changes.clone());
        tx.selection = Some(if redo { entry.after } else { entry.before });
        let (mut state, mapping) =
            EditorState::from_snapshot(snapshot.clone(), Selection::caret(0))?.apply(tx)?;
        if changes.is_empty() {
            let revision = snapshot
                .version()
                .checked_add(1)
                .ok_or(EditError::VersionExhausted)?;
            state = EditorState::from_snapshot(snapshot.with_version(revision), state.selection())?;
        }
        let restored = HistoryRestore {
            state,
            changes: changes.clone(),
            mapping,
            owner: entry.owner,
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
        self.group = None;
        Ok(Some(restored))
    }
}
