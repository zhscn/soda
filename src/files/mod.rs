//! File I/O and immutable requests, independent of command execution.
mod service;
pub(crate) mod state;
mod workspace;

pub use service::{FileError, FileService, LoadedFile, SaveCompletion, SaveRequest};
pub use state::FileState;
pub use workspace::{FileUpdate, Workspace};
