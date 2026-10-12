mod changes;
pub use changes::compose_changes;
pub(crate) use changes::invert_changes;
mod state;
mod text;

pub use state::{
    Association, Change, ChangeMap, EditError, Editor, EditorState, Selection, Transaction,
};
pub use text::Snapshot;
