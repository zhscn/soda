//! UI-independent model, command controller and atomic input planning.
mod commands;
mod history;
pub mod search;
pub use commands::{Direction, Motion};
mod controller;
mod document;
mod language;
mod model;
mod operations;

pub use controller::{Command, Editor, EditorUpdate, SessionUpdate};
pub use document::{Document, DocumentId, DocumentUpdate, EditOrigin, SessionId};
pub use language::Language;
pub use model::{EditorModel, EditorSession};
pub use operations::{enter, reindent, type_char};
