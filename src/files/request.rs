use super::{FileError, LoadedFile, state::DiskImage};
use crate::{config::ResolvedConfig, editor::DocumentId};
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, Ordering},
        mpsc::{SendError, Sender},
    },
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SaveId(pub(crate) u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct OpenId(u64);
impl OpenId {
    pub(super) fn allocate() -> Result<Self, FileError> {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT_ID: AtomicU64 = AtomicU64::new(1);
        NEXT_ID
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .map(Self)
            .map_err(|_| crate::core::EditError::VersionExhausted.into())
    }
}
pub enum OpenPreparation {
    Existing(DocumentId),
    Request(OpenRequest),
}

#[derive(Clone)]
pub(super) struct FileRoute {
    sender: Sender<FileEvent>,
    owner: Weak<AtomicBool>,
}
impl FileRoute {
    pub fn new(sender: Sender<FileEvent>, owner: &Arc<AtomicBool>) -> Self {
        Self {
            sender,
            owner: Arc::downgrade(owner),
        }
    }
    pub fn lease(&self) -> Option<Arc<AtomicBool>> {
        self.owner
            .upgrade()
            .filter(|owner| owner.load(Ordering::Acquire))
    }
    fn send(&self, event: FileEvent) -> Result<(), SendError<FileEvent>> {
        let sent = self.sender.send(event);
        crate::wake::wake();
        sent
    }
}
pub(super) enum FileEvent {
    CancelSave { token: u64, document_id: DocumentId },
    FinishSave(Box<SavePayload>),
    CancelOpen(OpenId),
    RecoverSave(Box<SavePlan>),
}
pub(crate) struct SavePlan {
    pub token: u64,
    pub document_id: DocumentId,
    pub path: PathBuf,
    pub image: DiskImage,
    pub expected: Option<DiskImage>,
    pub configuration: Option<ResolvedConfig>,
    pub editorconfig: crate::config::editorconfig::Settings,
    pub config_generation: u64,
}
pub(super) struct SavePayload {
    pub plan: SavePlan,
    pub result: Result<(), FileError>,
}

/// Single-use write intent. Dropping an unexecuted request queues cancellation
/// in its originating workspace; executing transfers the reservation to a result.
#[must_use]
pub struct SaveRequest {
    pub(super) plan: Option<SavePlan>,
    pub(super) route: FileRoute,
    pub(super) started: bool,
}
impl SaveRequest {
    pub fn id(&self) -> SaveId {
        SaveId(self.plan.as_ref().unwrap().token)
    }
    pub fn document_id(&self) -> DocumentId {
        self.plan.as_ref().unwrap().document_id
    }
    pub fn path(&self) -> &Path {
        &self.plan.as_ref().unwrap().path
    }
    pub fn revision(&self) -> u64 {
        self.plan.as_ref().unwrap().image.snapshot.version()
    }
}
impl Drop for SaveRequest {
    fn drop(&mut self) {
        if let Some(plan) = self.plan.take() {
            let event = if self.started {
                FileEvent::RecoverSave(Box::new(plan))
            } else {
                FileEvent::CancelSave {
                    token: plan.token,
                    document_id: plan.document_id,
                }
            };
            let _ = self.route.send(event);
        }
    }
}
#[must_use]
pub struct SaveCompletion {
    pub(super) payload: Option<SavePayload>,
    pub(super) route: FileRoute,
}
impl SaveCompletion {
    pub fn id(&self) -> SaveId {
        SaveId(self.payload.as_ref().unwrap().plan.token)
    }
    pub fn document_id(&self) -> DocumentId {
        self.payload.as_ref().unwrap().plan.document_id
    }
    pub fn result(&self) -> Result<(), &FileError> {
        self.payload.as_ref().unwrap().result.as_ref().map(|_| ())
    }
}
impl Drop for SaveCompletion {
    fn drop(&mut self) {
        if let Some(payload) = self.payload.take() {
            let _ = self.route.send(FileEvent::FinishSave(Box::new(payload)));
        }
    }
}

#[must_use]
pub struct OpenRequest {
    pub(super) id: OpenId,
    pub(super) path: PathBuf,
    pub(super) route: FileRoute,
    pub(super) active: bool,
}
impl OpenRequest {
    pub fn id(&self) -> OpenId {
        self.id
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
}
impl Drop for OpenRequest {
    fn drop(&mut self) {
        if self.active {
            let _ = self.route.send(FileEvent::CancelOpen(self.id));
        }
    }
}
#[must_use]
pub struct OpenCompletion {
    pub(super) id: OpenId,
    pub(super) path: PathBuf,
    pub(super) result: Option<Result<LoadedFile, FileError>>,
    pub(super) route: FileRoute,
}
impl OpenCompletion {
    pub fn id(&self) -> OpenId {
        self.id
    }
}
impl Drop for OpenCompletion {
    fn drop(&mut self) {
        if self.result.is_some() {
            let _ = self.route.send(FileEvent::CancelOpen(self.id));
        }
    }
}
