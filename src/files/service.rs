use super::state::DiskImage;
use crate::{
    config::{ConfigError, ConfigOptions, ResolvedConfig, resolve_config},
    editor::{DocumentId, Language},
};
use std::{
    fmt, fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

#[derive(Debug)]
pub enum FileError {
    Io { path: PathBuf, source: io::Error },
    InvalidUtf8(PathBuf),
    Configuration(ConfigError),
    Conflict(PathBuf),
    UnknownDocument,
    Untitled,
    Busy,
    PathInUse(PathBuf),
    StaleCompletion,
    UnsavedChanges,
    Edit(crate::core::EditError),
}
impl fmt::Display for FileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, source } => write!(f, "{}: {source}", path.display()),
            Self::InvalidUtf8(path) => write!(f, "{}: expected UTF-8", path.display()),
            Self::Configuration(error) => write!(f, "{error}"),
            Self::Conflict(path) => write!(f, "{}: disk content changed", path.display()),
            Self::PathInUse(path) => write!(
                f,
                "{}: path already belongs to an open document or save",
                path.display()
            ),
            other => write!(f, "{other:?}"),
        }
    }
}
impl std::error::Error for FileError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Configuration(error) => Some(error),
            Self::Edit(error) => Some(error),
            _ => None,
        }
    }
}
impl From<ConfigError> for FileError {
    fn from(error: ConfigError) -> Self {
        Self::Configuration(error)
    }
}
impl From<crate::core::EditError> for FileError {
    fn from(error: crate::core::EditError) -> Self {
        Self::Edit(error)
    }
}
fn io_error(path: &Path, source: io::Error) -> FileError {
    FileError::Io {
        path: path.to_owned(),
        source,
    }
}

pub struct LoadedFile {
    pub(crate) path: PathBuf,
    pub(crate) text: String,
    pub(crate) bom: bool,
    pub(crate) configuration: Option<ResolvedConfig>,
}
impl LoadedFile {
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn has_utf8_bom(&self) -> bool {
        self.bom
    }
}

/// A single-use immutable save request; its snapshot may outlive further edits.
#[must_use = "write the request or cancel it through the workspace"]
pub struct SaveRequest {
    pub(crate) token: u64,
    pub(crate) document_id: DocumentId,
    pub(crate) path: PathBuf,
    pub(crate) image: DiskImage,
    pub(crate) expected: Option<DiskImage>,
    pub(crate) configuration: Option<ResolvedConfig>,
    pub(crate) config_generation: u64,
}
impl SaveRequest {
    pub fn document_id(&self) -> DocumentId {
        self.document_id
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn revision(&self) -> u64 {
        self.image.snapshot.version()
    }
}
#[must_use = "apply the completion through the originating workspace"]
pub struct SaveCompletion {
    pub(crate) request: SaveRequest,
    pub(crate) result: Result<(), FileError>,
}
impl SaveCompletion {
    pub fn result(&self) -> Result<(), &FileError> {
        self.result.as_ref().map(|_| ())
    }
}

/// Synchronous disk operations. Scheduling and completion application belong
/// to the workspace, so this service never mutates an editor model.
#[derive(Default)]
pub struct FileService {
    options: ConfigOptions,
}
impl FileService {
    pub fn new(options: ConfigOptions) -> Self {
        Self { options }
    }
    pub fn resolve_path(&self, path: &Path) -> Result<PathBuf, FileError> {
        match fs::canonicalize(path) {
            Ok(path) => Ok(path),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let absolute = if path.is_absolute() {
                    path.to_owned()
                } else {
                    std::env::current_dir()
                        .map_err(|e| io_error(path, e))?
                        .join(path)
                };
                let name = absolute.file_name().ok_or_else(|| {
                    io_error(
                        path,
                        io::Error::new(io::ErrorKind::InvalidInput, "expected a file name"),
                    )
                })?;
                let parent =
                    fs::canonicalize(absolute.parent().unwrap()).map_err(|e| io_error(path, e))?;
                let normalized = parent.join(name);
                // A dangling symlink is an existing directory entry, not a new file.
                if fs::symlink_metadata(&normalized).is_ok() {
                    return Err(io_error(path, error));
                }
                Ok(normalized)
            }
            Err(error) => Err(io_error(path, error)),
        }
    }
    pub(crate) fn configuration(&self, path: &Path) -> Result<Option<ResolvedConfig>, FileError> {
        let cpp = matches!(
            path.extension().and_then(|value| value.to_str()),
            Some("c" | "cc" | "cpp" | "cxx" | "h" | "hh" | "hpp" | "hxx" | "C" | "H")
        );
        if cpp {
            Ok(Some(resolve_config(path, &self.options)?))
        } else {
            Ok(None)
        }
    }
    pub(crate) fn language(configuration: &Option<ResolvedConfig>) -> Language {
        configuration
            .as_ref()
            .map(|config| config.config.rules.clone().into())
            .unwrap_or_default()
    }
    pub fn read(&self, path: &Path) -> Result<LoadedFile, FileError> {
        let path = self.resolve_path(path)?;
        if !fs::metadata(&path)
            .map_err(|e| io_error(&path, e))?
            .is_file()
        {
            return Err(io_error(
                &path,
                io::Error::new(io::ErrorKind::InvalidInput, "expected a regular file"),
            ));
        }
        let bytes = fs::read(&path).map_err(|e| io_error(&path, e))?;
        let bom = bytes.starts_with(b"\xef\xbb\xbf");
        let text = String::from_utf8(if bom { bytes[3..].to_vec() } else { bytes })
            .map_err(|_| FileError::InvalidUtf8(path.clone()))?;
        let configuration = self.configuration(&path)?;
        Ok(LoadedFile {
            path,
            text,
            bom,
            configuration,
        })
    }
    pub(crate) fn check(
        &self,
        path: &Path,
        expected: Option<&DiskImage>,
    ) -> Result<bool, FileError> {
        match fs::metadata(path) {
            Ok(metadata) if !metadata.is_file() => return Ok(false),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(io_error(path, error)),
            _ => {}
        }
        match fs::read(path) {
            Ok(bytes) => Ok(expected.is_some_and(|expected| expected.matches(&bytes))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                Ok(expected.is_none() && fs::symlink_metadata(path).is_err())
            }
            Err(error) => Err(io_error(path, error)),
        }
    }
    pub fn write(&self, request: SaveRequest) -> SaveCompletion {
        let result = self.write_snapshot(&request);
        SaveCompletion { request, result }
    }
    fn write_snapshot(&self, request: &SaveRequest) -> Result<(), FileError> {
        let path = &request.path;
        if !self.check(path, request.expected.as_ref())? {
            return Err(FileError::Conflict(path.clone()));
        }
        let mut temporary = tempfile::NamedTempFile::new_in(path.parent().unwrap())
            .map_err(|e| io_error(path, e))?;
        if request.expected.is_some() {
            let permissions = fs::metadata(path)
                .map_err(|e| io_error(path, e))?
                .permissions();
            temporary
                .as_file()
                .set_permissions(permissions)
                .map_err(|e| io_error(path, e))?;
        }
        if request.image.bom {
            temporary
                .write_all(b"\xef\xbb\xbf")
                .map_err(|e| io_error(path, e))?;
        }
        for chunk in request.image.snapshot.chunks() {
            temporary
                .write_all(chunk.as_bytes())
                .map_err(|e| io_error(path, e))?;
        }
        temporary
            .as_file()
            .sync_all()
            .map_err(|e| io_error(path, e))?;
        if !self.check(path, request.expected.as_ref())? {
            return Err(FileError::Conflict(path.clone()));
        }
        if request.expected.is_none() {
            temporary.persist_noclobber(path).map_err(|e| {
                if e.error.kind() == io::ErrorKind::AlreadyExists {
                    FileError::Conflict(path.clone())
                } else {
                    io_error(path, e.error)
                }
            })?;
        } else {
            temporary
                .persist(path)
                .map_err(|e| io_error(path, e.error))?;
        }
        Ok(())
    }
}
