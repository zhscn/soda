use crate::{config::ResolvedConfig, core::Snapshot};
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub(crate) struct DiskImage {
    pub snapshot: Snapshot,
    pub bom: bool,
}
impl DiskImage {
    pub fn matches(&self, bytes: &[u8]) -> bool {
        let prefix: &[u8] = if self.bom { b"\xef\xbb\xbf" } else { b"" };
        prefix
            .iter()
            .copied()
            .chain(self.snapshot.chunks().flat_map(str::bytes))
            .eq(bytes.iter().copied())
    }
}

/// File binding and the exact successfully loaded or saved content baseline.
#[derive(Default)]
pub struct FileState {
    pub(crate) path: Option<PathBuf>,
    pub(crate) bom: bool,
    pub(crate) saved: Option<DiskImage>,
    pub(crate) saved_revision: Option<u64>,
    pub(crate) configuration: Option<ResolvedConfig>,
}
impl FileState {
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }
    pub fn has_utf8_bom(&self) -> bool {
        self.bom
    }
    pub fn saved_revision(&self) -> Option<u64> {
        self.saved_revision
    }
    pub fn configuration(&self) -> Option<&ResolvedConfig> {
        self.configuration.as_ref()
    }
    pub(crate) fn is_dirty(&self, current: &Snapshot) -> bool {
        match &self.saved {
            Some(saved) => saved.bom != self.bom || !saved.snapshot.content_eq(current),
            None => !current.is_empty() || self.bom,
        }
    }
}
