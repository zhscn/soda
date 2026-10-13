mod word;
pub use word::word_boundary;
pub(crate) use word::word_edge;
mod coordinate;
pub use coordinate::{ByteOffset, LogicalColumn, TextPoint};
mod position;
pub use position::{
    clip_grapheme_offset, column_width, deletion_range, logical_column_at,
    offset_at_logical_column, step_grapheme,
};
mod history;
pub(crate) use history::History;
mod changes;
pub use changes::compose_changes;
pub(crate) use changes::{ValidatedChanges, compose_validated, invert_changes};
mod state;
mod text;

pub use state::{
    Association, Change, ChangeMap, EditError, Editor, EditorState, Selection, Transaction,
    UserEvent,
};
pub use text::Snapshot;
