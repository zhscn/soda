use super::{
    FileError, FileService, LoadedFile, SaveCompletion, SaveRequest,
    state::{DiskImage, FileState},
};
use crate::editor::{DocumentId, Editor, Language};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug)]
pub struct FileUpdate {
    pub document_id: DocumentId,
    pub path: PathBuf,
    /// Revision actually written, which may differ from the current revision.
    pub saved_revision: u64,
    pub dirty: bool,
    pub language_changed: bool,
}
struct PendingSave {
    token: u64,
    path: PathBuf,
}

/// Document registry and file lifecycle coordinator. Editing remains in each
/// document's controller; the file service performs reads and writes separately.
#[derive(Default)]
pub struct Workspace {
    service: FileService,
    editors: BTreeMap<DocumentId, Editor>,
    paths: BTreeMap<PathBuf, DocumentId>,
    pending: BTreeMap<DocumentId, PendingSave>,
    next_save: u64,
}
impl Workspace {
    pub fn new(service: FileService) -> Self {
        Self {
            service,
            ..Self::default()
        }
    }
    pub fn service(&self) -> &FileService {
        &self.service
    }
    pub fn editor(&self, id: DocumentId) -> Option<&Editor> {
        self.editors.get(&id)
    }
    pub fn editor_mut(&mut self, id: DocumentId) -> Option<&mut Editor> {
        self.editors.get_mut(&id)
    }
    pub fn documents(&self) -> impl Iterator<Item = DocumentId> + '_ {
        self.editors.keys().copied()
    }
    pub fn new_document(&mut self, language: impl Into<Language>) -> DocumentId {
        let editor = Editor::new("", language);
        let id = editor.model().document().id();
        self.editors.insert(id, editor);
        id
    }
    pub fn open(&mut self, path: &Path) -> Result<DocumentId, FileError> {
        let path = self.service.resolve_path(path)?;
        if let Some(id) = self.paths.get(&path) {
            return Ok(*id);
        }
        if self.pending.values().any(|pending| pending.path == path) {
            return Err(FileError::PathInUse(path));
        }
        let loaded = self.service.read(&path)?;
        self.accept_loaded(loaded)
    }
    /// Applies a completed read without replacing an already open document.
    pub fn accept_loaded(&mut self, loaded: LoadedFile) -> Result<DocumentId, FileError> {
        if let Some(id) = self.paths.get(&loaded.path) {
            return Ok(*id);
        }
        if self
            .pending
            .values()
            .any(|pending| pending.path == loaded.path)
        {
            return Err(FileError::PathInUse(loaded.path));
        }
        let mut editor = Editor::new(loaded.text, FileService::language(&loaded.configuration));
        let id = editor.model().document().id();
        let snapshot = editor.model().document().snapshot().for_history();
        editor.bind_file(FileState {
            path: Some(loaded.path.clone()),
            bom: loaded.bom,
            saved: Some(DiskImage {
                snapshot,
                bom: loaded.bom,
            }),
            saved_revision: Some(0),
            configuration: loaded.configuration,
        });
        self.paths.insert(loaded.path, id);
        self.editors.insert(id, editor);
        Ok(id)
    }
    pub fn close(&mut self, id: DocumentId) -> Result<(), FileError> {
        if self.pending.contains_key(&id) {
            return Err(FileError::Busy);
        }
        if self
            .editors
            .get(&id)
            .ok_or(FileError::UnknownDocument)?
            .model()
            .document()
            .is_dirty()
        {
            return Err(FileError::UnsavedChanges);
        }
        self.discard_document(id)
    }
    /// Explicitly discard local edits. Outstanding saves must finish first.
    pub fn discard_document(&mut self, id: DocumentId) -> Result<(), FileError> {
        if self.pending.contains_key(&id) {
            return Err(FileError::Busy);
        }
        let editor = self.editors.remove(&id).ok_or(FileError::UnknownDocument)?;
        if let Some(path) = editor.model().document().file().path() {
            self.paths.remove(path);
        }
        Ok(())
    }
    /// Resolves the target and reserves it until the result is applied. One
    /// save per document can be outstanding; ordinary editing remains available.
    pub fn prepare_save(
        &mut self,
        id: DocumentId,
        target: Option<&Path>,
    ) -> Result<SaveRequest, FileError> {
        if self.pending.contains_key(&id) {
            return Err(FileError::Busy);
        }
        let document = self
            .editors
            .get(&id)
            .ok_or(FileError::UnknownDocument)?
            .model()
            .document();
        let target = target
            .or_else(|| document.file().path())
            .ok_or(FileError::Untitled)?;
        let path = self.service.resolve_path(target)?;
        if self.paths.get(&path).is_some_and(|owner| *owner != id)
            || self.pending.values().any(|pending| pending.path == path)
        {
            return Err(FileError::PathInUse(path));
        }
        let same_path = document.file().path() == Some(path.as_path());
        let configuration = if same_path {
            None
        } else {
            self.service.configuration(&path)?
        };
        if !same_path && document.language() != FileService::language(&configuration) {
            document
                .config_generation()
                .checked_add(1)
                .ok_or(crate::core::EditError::VersionExhausted)?;
        }
        let token = self.next_save;
        let next = token
            .checked_add(1)
            .ok_or(crate::core::EditError::VersionExhausted)?;
        let request = SaveRequest {
            token,
            document_id: id,
            path: path.clone(),
            image: DiskImage {
                snapshot: document.snapshot().clone(),
                bom: document.file().has_utf8_bom(),
            },
            expected: if same_path {
                document.file().saved.clone()
            } else {
                None
            },
            configuration,
            config_generation: document.config_generation(),
        };
        self.editors.get_mut(&id).unwrap().checkpoint_history();
        self.pending.insert(id, PendingSave { token, path });
        self.next_save = next;
        Ok(request)
    }
    /// Releases an unexecuted request. Consuming it prevents a later write.
    pub fn cancel_save(&mut self, request: SaveRequest) -> Result<(), FileError> {
        let pending = self
            .pending
            .get(&request.document_id)
            .ok_or(FileError::StaleCompletion)?;
        if pending.token != request.token || pending.path != request.path {
            return Err(FileError::StaleCompletion);
        }
        self.pending.remove(&request.document_id);
        Ok(())
    }
    /// Confirms only the snapshot that was written. A failed write releases
    /// the reservation and leaves the file binding and saved baseline intact.
    pub fn finish_save(&mut self, completion: SaveCompletion) -> Result<FileUpdate, FileError> {
        let SaveCompletion { request, result } = completion;
        let pending = self
            .pending
            .get(&request.document_id)
            .ok_or(FileError::StaleCompletion)?;
        if pending.token != request.token || pending.path != request.path {
            return Err(FileError::StaleCompletion);
        }
        self.pending.remove(&request.document_id);
        result?;
        let editor = self
            .editors
            .get_mut(&request.document_id)
            .ok_or(FileError::UnknownDocument)?;
        let old_path = editor.model().document().file().path().map(Path::to_owned);
        let language_changed = editor.confirm_save(&request)?;
        if let Some(old_path) = old_path {
            self.paths.remove(&old_path);
        }
        self.paths.insert(request.path.clone(), request.document_id);
        Ok(FileUpdate {
            document_id: request.document_id,
            path: request.path,
            saved_revision: request.image.snapshot.version(),
            dirty: editor.model().document().is_dirty(),
            language_changed,
        })
    }
    pub fn save(&mut self, id: DocumentId, target: Option<&Path>) -> Result<FileUpdate, FileError> {
        let request = self.prepare_save(id, target)?;
        let completion = self.service.write(request);
        self.finish_save(completion)
    }
    /// Compares disk bytes to the loaded/saved baseline, independently of local
    /// edits. A missing previously saved file is also an external change.
    pub fn externally_modified(&self, id: DocumentId) -> Result<bool, FileError> {
        let document = self
            .editors
            .get(&id)
            .ok_or(FileError::UnknownDocument)?
            .model()
            .document();
        let Some(path) = document.file().path() else {
            return Ok(false);
        };
        Ok(!self.service.check(path, document.file().saved.as_ref())?)
    }
    /// Explicitly reloads path-dependent configuration through the language
    /// command boundary, preserving text, selection and history.
    pub fn reload_configuration(&mut self, id: DocumentId) -> Result<bool, FileError> {
        let path = self
            .editors
            .get(&id)
            .ok_or(FileError::UnknownDocument)?
            .model()
            .document()
            .file()
            .path()
            .ok_or(FileError::Untitled)?
            .to_owned();
        let configuration = self.service.configuration(&path)?;
        let editor = self.editors.get_mut(&id).unwrap();
        let changed = editor.reload_file_configuration(configuration)?;
        Ok(changed)
    }
}
