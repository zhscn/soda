use super::Snapshot;
use std::{fmt, ops::Range};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Association {
    Before,
    After,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Selection {
    pub anchor: usize,
    pub head: usize,
}
impl Selection {
    pub fn caret(position: usize) -> Self {
        Self {
            anchor: position,
            head: position,
        }
    }
    pub fn range(self) -> Range<usize> {
        self.anchor.min(self.head)..self.anchor.max(self.head)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Change {
    pub range: Range<usize>,
    pub insert: String,
}
impl Change {
    pub fn new(range: Range<usize>, insert: impl Into<String>) -> Self {
        Self {
            range,
            insert: insert.into(),
        }
    }
}

/// All ranges refer to the same base snapshot. Adjacent changes are allowed;
/// two changes starting at the same byte are rejected as ambiguous.
#[derive(Clone, Debug)]
pub struct Transaction {
    pub base_version: u64,
    pub changes: Vec<Change>,
    /// Explicit selection is in the resulting text's coordinates.
    pub selection: Option<Selection>,
    pub history_group: Option<u64>,
}
impl Transaction {
    pub fn new(base_version: u64, changes: Vec<Change>) -> Self {
        Self {
            base_version,
            changes,
            selection: None,
            history_group: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EditError {
    AnalysisMismatch,
    StaleVersion,
    InvalidRange,
    OverlappingChanges,
    InvalidSelection,
    VersionExhausted,
}
impl fmt::Display for EditError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for EditError {}

#[derive(Clone, Debug)]
pub struct ChangeMap {
    spans: Vec<(Range<usize>, usize)>,
}
impl ChangeMap {
    pub fn map(&self, position: usize, association: Association) -> usize {
        let mut removed = 0;
        let mut inserted = 0;
        for (r, len) in &self.spans {
            if position < r.start {
                break;
            }
            if position <= r.end {
                if position == r.end && !r.is_empty() {
                    // An adjacent insertion at this boundary still observes association.
                    removed += r.len();
                    inserted += len;
                    continue;
                }
                return r.start - removed
                    + inserted
                    + if association == Association::After {
                        *len
                    } else {
                        0
                    };
            }
            removed += r.len();
            inserted += len;
        }
        position - removed + inserted
    }
    pub fn map_selection(&self, selection: Selection) -> Selection {
        if selection.anchor == selection.head {
            return Selection::caret(self.map(selection.head, Association::After));
        }
        let forward = selection.anchor < selection.head;
        Selection {
            anchor: self.map(
                selection.anchor,
                if forward {
                    Association::Before
                } else {
                    Association::After
                },
            ),
            head: self.map(
                selection.head,
                if forward {
                    Association::After
                } else {
                    Association::Before
                },
            ),
        }
    }
}

#[derive(Clone, Debug)]
pub struct EditorState {
    snapshot: Snapshot,
    selection: Selection,
}
impl EditorState {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            snapshot: Snapshot::new(text.into(), 0),
            selection: Selection::caret(0),
        }
    }
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }
    pub fn selection(&self) -> Selection {
        self.selection
    }
    fn for_history(&self) -> Self {
        Self {
            snapshot: self.snapshot.for_history(),
            selection: self.selection,
        }
    }
    pub fn apply(&self, mut tx: Transaction) -> Result<(Self, ChangeMap), EditError> {
        if tx.base_version != self.snapshot.version() {
            return Err(EditError::StaleVersion);
        }
        let snapshot = &self.snapshot;
        if tx.changes.is_empty() {
            let selection = tx.selection.unwrap_or(self.selection);
            if [selection.anchor, selection.head]
                .iter()
                .any(|&p| !snapshot.is_char_boundary(p))
            {
                return Err(EditError::InvalidSelection);
            }
            let version = self
                .snapshot
                .version()
                .checked_add(1)
                .ok_or(EditError::VersionExhausted)?;
            return Ok((
                Self {
                    snapshot: self.snapshot.with_version(version),
                    selection,
                },
                ChangeMap { spans: vec![] },
            ));
        }
        tx.changes.sort_by_key(|c| c.range.start);
        let mut previous: Option<&Change> = None;
        for c in &tx.changes {
            if c.range.start > c.range.end
                || c.range.end > snapshot.len_bytes()
                || !snapshot.is_char_boundary(c.range.start)
                || !snapshot.is_char_boundary(c.range.end)
            {
                return Err(EditError::InvalidRange);
            }
            if previous
                .is_some_and(|p| p.range.end > c.range.start || p.range.start == c.range.start)
            {
                return Err(EditError::OverlappingChanges);
            }
            previous = Some(c);
        }
        let map = ChangeMap {
            spans: tx
                .changes
                .iter()
                .map(|c| (c.range.clone(), c.insert.len()))
                .collect(),
        };
        let version = snapshot
            .version()
            .checked_add(1)
            .ok_or(EditError::VersionExhausted)?;
        let output = snapshot.edited(&tx.changes, version);
        let selection = tx
            .selection
            .unwrap_or_else(|| map.map_selection(self.selection));
        if [selection.anchor, selection.head]
            .iter()
            .any(|&p| !output.is_char_boundary(p))
        {
            return Err(EditError::InvalidSelection);
        }
        Ok((
            Self {
                snapshot: output,
                selection,
            },
            map,
        ))
    }
}

/// Mutable history owner around immutable states. Undo/redo advances version
/// so asynchronous work cannot mistake a restored state for its old snapshot.
pub struct Editor {
    state: EditorState,
    undo: Vec<EditorState>,
    redo: Vec<EditorState>,
    group: Option<u64>,
}
impl Editor {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            state: EditorState::new(text),
            undo: Vec::new(),
            redo: Vec::new(),
            group: None,
        }
    }
    pub fn state(&self) -> &EditorState {
        &self.state
    }
    pub fn dispatch(&mut self, tx: Transaction) -> Result<ChangeMap, EditError> {
        let group = tx.history_group;
        let modifies_text = !tx.changes.is_empty();
        let (next, map) = self.state.apply(tx)?;
        if modifies_text {
            if group.is_none() || group != self.group {
                self.undo.push(self.state.for_history());
            }
            self.redo.clear();
        }
        self.group = if modifies_text { group } else { None };
        self.state = next;
        Ok(map)
    }
    pub fn undo(&mut self) -> Result<bool, EditError> {
        self.restore(false)
    }
    pub fn redo(&mut self) -> Result<bool, EditError> {
        self.restore(true)
    }
    fn restore(&mut self, redo: bool) -> Result<bool, EditError> {
        let source = if redo { &mut self.redo } else { &mut self.undo };
        if source.is_empty() {
            return Ok(false);
        }
        let version = self
            .state
            .snapshot
            .version()
            .checked_add(1)
            .ok_or(EditError::VersionExhausted)?;
        let mut restored = source.pop().unwrap();
        restored.snapshot = restored.snapshot.with_version(version);
        let prior = std::mem::replace(&mut self.state, restored);
        if redo {
            self.undo.push(prior.for_history());
        } else {
            self.redo.push(prior.for_history());
        }
        self.group = None;
        Ok(true)
    }
}
