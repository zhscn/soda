mod history;
pub(crate) use history::History;
mod changes;
pub use changes::compose_changes;
pub(crate) use changes::{ValidatedChanges, compose_validated, invert_changes};
mod state;
mod text;

pub use state::{
    Association, Change, ChangeMap, EditError, Editor, EditorState, Selection, Transaction,
};
pub use text::Snapshot;
