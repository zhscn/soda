//! Path resolution shared by the command line and path commands. Directory
//! listing runs on a worker; see `files::paths`.
pub use crate::files::paths::{PathCompletion, PathRequest};
use std::path::{Path, PathBuf};

/// Resolves `~/` against home and relative paths against the file root.
pub(crate) fn resolve_path(
    base: &Path,
    home: Option<&Path>,
    path: &Path,
) -> Result<PathBuf, String> {
    if let Ok(suffix) = path.strip_prefix("~") {
        return home
            .filter(|home| home.is_absolute())
            .map(|home| home.join(suffix))
            .ok_or_else(|| "Home directory is unavailable".into());
    }
    Ok(base.join(path))
}
