//! File I/O and immutable requests, independent of command execution.
mod editing;
pub(crate) mod request;
mod service;
pub use editing::Editing;
pub(crate) mod state;
mod workspace;

pub use request::{
    OpenCompletion, OpenId, OpenPreparation, OpenRequest, SaveCompletion, SaveRequest,
};
pub use service::{FileError, FileService, LoadedFile};
pub use state::FileState;
pub use workspace::{FileResult, FileUpdate, Workspace};
