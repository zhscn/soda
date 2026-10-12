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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UserEvent {
    Input,
    DeleteBackward,
    DeleteForward,
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
    pub user_event: Option<UserEvent>,
}
impl Transaction {
    pub fn new(base_version: u64, changes: Vec<Change>) -> Self {
        Self {
            base_version,
            changes,
            selection: None,
            history_group: None,
            user_event: None,
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
    UnknownSession,
    WrongDocument,
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
    pub(crate) fn from_sorted(changes: &[Change]) -> Self {
        Self {
            spans: changes
                .iter()
                .map(|change| (change.range.clone(), change.insert.len()))
                .collect(),
        }
    }
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
    /// Returns None when a replacement deletes the original position's context.
    pub fn map_tracked(&self, position: usize, association: Association) -> Option<usize> {
        if self
            .spans
            .iter()
            .any(|(range, _)| range.start < position && position < range.end)
        {
            None
        } else {
            Some(self.map(position, association))
        }
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
    /// A read-only editing projection of a document and a session selection.
    pub fn from_snapshot(snapshot: Snapshot, selection: Selection) -> Result<Self, EditError> {
        if !snapshot.is_char_boundary(selection.anchor)
            || !snapshot.is_char_boundary(selection.head)
        {
            return Err(EditError::InvalidSelection);
        }
        Ok(Self {
            snapshot,
            selection,
        })
    }
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }
    pub fn selection(&self) -> Selection {
        self.selection
    }
    pub fn apply(&self, tx: Transaction) -> Result<(Self, ChangeMap), EditError> {
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
            return Ok((
                Self {
                    snapshot: self.snapshot.clone(),
                    selection,
                },
                ChangeMap { spans: vec![] },
            ));
        }
        let validated = super::ValidatedChanges::new(snapshot, tx.changes)?;
        let map = validated.mapping;
        let version = snapshot
            .version()
            .checked_add(1)
            .ok_or(EditError::VersionExhausted)?;
        let output = snapshot.edited(&validated.changes, version);
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

/// Single-session adapter using the same history as document controllers.
pub struct Editor {
    state: EditorState,
    history: super::History<()>,
}
impl Editor {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            state: EditorState::new(text),
            history: super::History::default(),
        }
    }
    pub fn state(&self) -> &EditorState {
        &self.state
    }
    pub fn dispatch(&mut self, mut tx: Transaction) -> Result<ChangeMap, EditError> {
        tx.changes.sort_by_key(|change| change.range.start);
        let (next, map) = self.state.apply(tx.clone())?;
        if tx.changes.is_empty() {
            self.history.break_group();
        } else {
            self.history.record((), &self.state, &next, &tx)?;
        }
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
        let Some(restored) = self.history.restore(self.state.snapshot(), redo)? else {
            return Ok(false);
        };
        self.state = restored.state;
        Ok(true)
    }
}
