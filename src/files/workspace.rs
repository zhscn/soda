use super::{
    Editing, FileError, FileService, LoadedFile, SaveCompletion, SaveRequest,
    request::{
        FileEvent, FileRoute, OpenCompletion, OpenId, OpenPreparation, OpenRequest, SavePayload,
        SavePlan,
    },
    state::{DiskImage, FileState},
};
use crate::editor::{Command, DocumentId, Editor, EditorUpdate, Language};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::mpsc::{self, Receiver},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
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
#[derive(Debug)]
pub struct FileResult {
    pub request: Option<super::SaveId>,
    pub document_id: DocumentId,
    pub result: Result<FileUpdate, FileError>,
}
pub struct ReloadUpdate {
    pub edit: EditorUpdate,
    pub file: FileUpdate,
}
struct PendingSave {
    token: u64,
    path: PathBuf,
}

/// Document registry and file lifecycle coordinator. Editing remains in each
/// document's controller; the file service performs reads and writes separately.
pub struct Workspace {
    service: FileService,
    editors: BTreeMap<DocumentId, Editor>,
    files: BTreeMap<DocumentId, FileState>,
    paths: BTreeMap<PathBuf, DocumentId>,
    pending: BTreeMap<DocumentId, PendingSave>,
    next_save: u64,
    open_requests: BTreeMap<OpenId, PathBuf>,
    route: FileRoute,
    _owner: Arc<AtomicBool>,
    events: Receiver<FileEvent>,
    ready_results: Vec<FileResult>,
}
impl Drop for Workspace {
    fn drop(&mut self) {
        self._owner.store(false, Ordering::Release);
    }
}
impl Default for Workspace {
    fn default() -> Self {
        let (sender, events) = mpsc::channel();
        let owner = Arc::new(AtomicBool::new(true));
        let route = FileRoute::new(sender, &owner);
        Self {
            service: FileService::default(),
            editors: BTreeMap::new(),
            files: BTreeMap::new(),
            paths: BTreeMap::new(),
            pending: BTreeMap::new(),
            next_save: 0,
            open_requests: BTreeMap::new(),
            route,
            _owner: owner,
            events,
            ready_results: Vec::new(),
        }
    }
}
impl Workspace {
    pub fn new(service: FileService) -> Self {
        let mut workspace = Self::default();
        workspace.service = service;
        workspace
    }
    /// Reservation state after the most recent owner-thread event collection.
    /// Call `poll_file_results` to apply request/completion drop notifications.
    pub fn is_open_pending(&self, id: OpenId) -> bool {
        self.open_requests.contains_key(&id)
    }
    pub fn is_saving(&self, id: DocumentId) -> bool {
        self.pending.contains_key(&id)
    }
    pub fn service(&self) -> &FileService {
        &self.service
    }
    pub fn editor(&self, id: DocumentId) -> Option<&Editor> {
        self.editors.get(&id)
    }
    pub fn editor_mut(&mut self, id: DocumentId) -> Option<Editing<'_>> {
        self.editors.get_mut(&id).map(|editor| Editing { editor })
    }
    pub fn documents(&self) -> impl Iterator<Item = DocumentId> + '_ {
        self.editors.keys().copied()
    }
    pub fn file(&self, id: DocumentId) -> Option<&FileState> {
        self.files.get(&id)
    }
    /// Whether text or encoding differs from the loaded or saved baseline.
    pub fn is_dirty(&self, id: DocumentId) -> bool {
        match (self.editors.get(&id), self.files.get(&id)) {
            (Some(editor), Some(file)) => file.is_dirty(editor.model().document().snapshot()),
            _ => false,
        }
    }
    fn insert(&mut self, editor: Editor, file: FileState) -> DocumentId {
        let id = editor.model().document().id();
        if let Some(path) = &file.path {
            self.paths.insert(path.clone(), id);
        }
        self.editors.insert(id, editor);
        self.files.insert(id, file);
        id
    }
    pub fn new_document(&mut self, language: impl Into<Language>) -> DocumentId {
        self.insert(Editor::new("", language), FileState::default())
    }
    pub fn open(&mut self, path: &Path) -> Result<DocumentId, FileError> {
        match self.prepare_open(path)? {
            OpenPreparation::Existing(id) => Ok(id),
            OpenPreparation::Request(request) => {
                let completion = self.service.read_request(request);
                self.finish_open(completion)
            }
        }
    }
    /// Opens an existing file or registers an empty, unsaved named document.
    pub fn open_or_create(&mut self, path: &Path) -> Result<DocumentId, FileError> {
        self.collect_events();
        let path = self.service.resolve_path(path)?;
        match self.open(&path) {
            Ok(id) => Ok(id),
            Err(FileError::Io { source, .. }) if source.kind() == std::io::ErrorKind::NotFound => {
                let configuration = self.service.configuration(&path)?;
                let editor = Editor::new("", FileService::language(&configuration));
                Ok(self.insert(
                    editor,
                    FileState {
                        path: Some(path),
                        configuration,
                        ..Default::default()
                    },
                ))
            }
            Err(error) => Err(error),
        }
    }
    /// Explicit disk reload. Local edits require discard=true; history retains
    /// the replaced contents as one undo unit and document identity is stable.
    pub fn reload(&mut self, id: DocumentId, discard: bool) -> Result<ReloadUpdate, FileError> {
        let session = self
            .editors
            .get(&id)
            .ok_or(FileError::UnknownDocument)?
            .model()
            .default_session();
        self.reload_for(id, session, discard)
    }
    /// Reload on behalf of an editing session, which owns the undo selection.
    pub fn reload_for(
        &mut self,
        id: DocumentId,
        session: crate::editor::SessionId,
        discard: bool,
    ) -> Result<ReloadUpdate, FileError> {
        self.editors
            .get(&id)
            .ok_or(FileError::UnknownDocument)?
            .model()
            .session(session)
            .ok_or(crate::core::EditError::UnknownSession)?;
        self.collect_events();
        if self.pending.contains_key(&id) {
            return Err(FileError::Busy);
        }
        if self.is_dirty(id) && !discard {
            return Err(FileError::UnsavedChanges);
        }
        let path = self.files[&id]
            .path()
            .ok_or(FileError::Untitled)?
            .to_owned();
        let loaded = self.service.read(&path)?;
        if self
            .paths
            .get(&loaded.path)
            .is_some_and(|owner| *owner != id)
        {
            return Err(FileError::PathInUse(loaded.path));
        }
        let language = FileService::language(&loaded.configuration);
        let document = self.editors.get(&id).unwrap().model().document();
        if document.language() != language {
            document
                .config_generation()
                .checked_add(1)
                .ok_or(crate::core::EditError::VersionExhausted)?;
        }
        let editor = self.editors.get_mut(&id).unwrap();
        let mut edit = editor.execute_for(session, Command::ReloadText(loaded.text))?;
        let language_changed = editor
            .execute(Command::SetLanguage(language))?
            .language_changed;
        edit.language_changed = language_changed;
        edit.config_generation = editor.model().document().config_generation();
        let snapshot = editor.model().document().snapshot().for_history();
        let revision = snapshot.version();
        editor.checkpoint_history();
        self.files.insert(
            id,
            FileState {
                path: Some(loaded.path.clone()),
                bom: loaded.bom,
                saved: Some(DiskImage {
                    snapshot,
                    bom: loaded.bom,
                }),
                saved_revision: Some(revision),
                configuration: loaded.configuration,
            },
        );
        self.paths.remove(&path);
        self.paths.insert(loaded.path.clone(), id);
        Ok(ReloadUpdate {
            edit,
            file: FileUpdate {
                document_id: id,
                path: loaded.path,
                saved_revision: revision,
                dirty: false,
                language_changed,
            },
        })
    }
    pub fn prepare_open(&mut self, path: &Path) -> Result<OpenPreparation, FileError> {
        self.collect_events();
        let path = self.service.resolve_path(path)?;
        if let Some(id) = self.paths.get(&path) {
            return Ok(OpenPreparation::Existing(*id));
        }
        if self.pending.values().any(|pending| pending.path == path) {
            return Err(FileError::PathInUse(path));
        }
        if self.open_requests.values().any(|pending| *pending == path) {
            return Err(FileError::Busy);
        }
        let id = OpenId::allocate()?;
        self.open_requests.insert(id, path.clone());
        Ok(OpenPreparation::Request(OpenRequest {
            id,
            path,
            route: self.route.clone(),
            active: true,
        }))
    }
    /// Cancelling a read invalidates its result even while the service is running.
    pub fn cancel_open(&mut self, id: OpenId) -> Result<(), FileError> {
        self.open_requests
            .remove(&id)
            .map(|_| ())
            .ok_or(FileError::StaleCompletion)
    }
    pub fn finish_open(&mut self, mut completion: OpenCompletion) -> Result<DocumentId, FileError> {
        self.collect_events();
        if self.open_requests.get(&completion.id) != Some(&completion.path) {
            return Err(FileError::StaleCompletion);
        }
        self.open_requests.remove(&completion.id);
        let loaded = completion.result.take().unwrap()?;
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
        self.insert_loaded(loaded)
    }
    fn insert_loaded(&mut self, loaded: LoadedFile) -> Result<DocumentId, FileError> {
        let editor = Editor::new(loaded.text, FileService::language(&loaded.configuration));
        let snapshot = editor.model().document().snapshot().for_history();
        let file = FileState {
            path: Some(loaded.path),
            bom: loaded.bom,
            saved: Some(DiskImage {
                snapshot,
                bom: loaded.bom,
            }),
            saved_revision: Some(0),
            configuration: loaded.configuration,
        };
        Ok(self.insert(editor, file))
    }
    pub fn close(&mut self, id: DocumentId) -> Result<(), FileError> {
        self.collect_events();
        if self.pending.contains_key(&id) {
            return Err(FileError::Busy);
        }
        if !self.editors.contains_key(&id) {
            return Err(FileError::UnknownDocument);
        }
        if self.is_dirty(id) {
            return Err(FileError::UnsavedChanges);
        }
        self.discard_document(id)
    }
    /// Explicitly discard local edits. Outstanding saves must finish first.
    pub fn discard_document(&mut self, id: DocumentId) -> Result<(), FileError> {
        self.collect_events();
        if self.pending.contains_key(&id) {
            return Err(FileError::Busy);
        }
        self.editors.remove(&id).ok_or(FileError::UnknownDocument)?;
        if let Some(path) = self.files.remove(&id).and_then(|file| file.path) {
            self.paths.remove(&path);
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
        self.collect_events();
        if self.pending.contains_key(&id) {
            return Err(FileError::Busy);
        }
        let document = self
            .editors
            .get(&id)
            .ok_or(FileError::UnknownDocument)?
            .model()
            .document();
        let file = &self.files[&id];
        let target = target.or_else(|| file.path()).ok_or(FileError::Untitled)?;
        let path = self.service.resolve_path(target)?;
        if self.paths.get(&path).is_some_and(|owner| *owner != id)
            || self.pending.values().any(|pending| pending.path == path)
            || self.open_requests.values().any(|pending| *pending == path)
        {
            return Err(FileError::PathInUse(path));
        }
        let same_path = file.path() == Some(path.as_path());
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
        let plan = SavePlan {
            token,
            document_id: id,
            path: path.clone(),
            image: DiskImage {
                snapshot: document.snapshot().clone(),
                bom: file.has_utf8_bom(),
            },
            expected: if same_path { file.saved.clone() } else { None },
            configuration,
            config_generation: document.config_generation(),
        };
        self.editors.get_mut(&id).unwrap().checkpoint_history();
        self.pending.insert(id, PendingSave { token, path });
        self.next_save = next;
        Ok(SaveRequest {
            plan: Some(plan),
            route: self.route.clone(),
            started: false,
        })
    }
    /// Releases an unexecuted request. Consuming it prevents a later write.
    pub fn cancel_save(&mut self, request: SaveRequest) -> Result<(), FileError> {
        let plan = request.plan.as_ref().unwrap();
        self.validate_save(plan)?;
        drop(request);
        self.collect_events();
        Ok(())
    }
    fn validate_save(&self, plan: &SavePlan) -> Result<(), FileError> {
        let pending = self
            .pending
            .get(&plan.document_id)
            .ok_or(FileError::StaleCompletion)?;
        if pending.token != plan.token || pending.path != plan.path {
            return Err(FileError::StaleCompletion);
        }
        Ok(())
    }
    pub fn finish_save(&mut self, mut completion: SaveCompletion) -> Result<FileUpdate, FileError> {
        self.collect_events();
        self.validate_save(&completion.payload.as_ref().unwrap().plan)?;
        self.apply_save(completion.payload.take().unwrap())
    }
    fn apply_save(&mut self, payload: SavePayload) -> Result<FileUpdate, FileError> {
        let SavePayload { plan, result } = payload;
        self.validate_save(&plan)?;
        self.pending.remove(&plan.document_id);
        result?;
        let editor = self
            .editors
            .get_mut(&plan.document_id)
            .ok_or(FileError::UnknownDocument)?;
        let file = self.files.get_mut(&plan.document_id).unwrap();
        let old_path = file.path.clone();
        let changing_path = old_path.as_deref() != Some(plan.path.as_path());
        let language_changed = if changing_path
            && editor.model().document().config_generation() == plan.config_generation
        {
            editor
                .execute(Command::SetLanguage(FileService::language(
                    &plan.configuration,
                )))?
                .language_changed
        } else {
            false
        };
        file.path = Some(plan.path.clone());
        file.saved = Some(DiskImage {
            snapshot: plan.image.snapshot.for_history(),
            bom: plan.image.bom,
        });
        file.saved_revision = Some(plan.image.snapshot.version());
        if changing_path {
            file.configuration = plan.configuration;
        }
        editor.checkpoint_history();
        if let Some(old_path) = old_path {
            self.paths.remove(&old_path);
        }
        self.paths.insert(plan.path.clone(), plan.document_id);
        Ok(FileUpdate {
            document_id: plan.document_id,
            path: plan.path,
            saved_revision: plan.image.snapshot.version(),
            dirty: self.is_dirty(plan.document_id),
            language_changed,
        })
    }
    /// Applies drop notifications on the owner thread. Successful writes retain
    /// their exact saved baseline even when the completion was abandoned.
    pub fn poll_file_results(&mut self) -> Vec<FileResult> {
        self.collect_events();
        std::mem::take(&mut self.ready_results)
    }
    fn collect_events(&mut self) {
        let mut results = Vec::new();
        while let Ok(event) = self.events.try_recv() {
            match event {
                FileEvent::CancelSave { token, document_id } => {
                    if self
                        .pending
                        .get(&document_id)
                        .is_some_and(|pending| pending.token == token)
                    {
                        self.pending.remove(&document_id);
                        results.push(FileResult {
                            document_id,
                            request: Some(super::SaveId(token)),
                            result: Err(FileError::Cancelled),
                        });
                    }
                }
                FileEvent::FinishSave(payload) => {
                    let document_id = payload.plan.document_id;
                    let request = Some(super::SaveId(payload.plan.token));
                    results.push(FileResult {
                        request,
                        document_id,
                        result: self.apply_save(*payload),
                    });
                }
                FileEvent::CancelOpen(id) => {
                    self.open_requests.remove(&id);
                }
                FileEvent::RecoverSave(plan) => {
                    let result = match self.service.check(&plan.path, Some(&plan.image)) {
                        Ok(true) => Ok(()),
                        Ok(false) => Err(FileError::Interrupted),
                        Err(error) => Err(error),
                    };
                    let document_id = plan.document_id;
                    let request = Some(super::SaveId(plan.token));
                    results.push(FileResult {
                        request,
                        document_id,
                        result: self.apply_save(SavePayload {
                            plan: *plan,
                            result,
                        }),
                    });
                }
            }
        }
        self.ready_results.extend(results);
    }
    pub fn save(&mut self, id: DocumentId, target: Option<&Path>) -> Result<FileUpdate, FileError> {
        let request = self.prepare_save(id, target)?;
        let completion = self.service.write(request);
        self.finish_save(completion)
    }
    /// Compares disk bytes to the loaded/saved baseline, independently of local
    /// edits. A missing previously saved file is also an external change.
    pub fn externally_modified(&self, id: DocumentId) -> Result<bool, FileError> {
        let file = self.files.get(&id).ok_or(FileError::UnknownDocument)?;
        let Some(path) = file.path() else {
            return Ok(false);
        };
        Ok(!self.service.check(path, file.saved.as_ref())?)
    }
    /// Explicitly reloads path-dependent configuration through the language
    /// command boundary, preserving text, selection and history.
    pub fn reload_configuration(&mut self, id: DocumentId) -> Result<bool, FileError> {
        let path = self
            .files
            .get(&id)
            .ok_or(FileError::UnknownDocument)?
            .path()
            .ok_or(FileError::Untitled)?
            .to_owned();
        let configuration = self.service.configuration(&path)?;
        let editor = self.editors.get_mut(&id).unwrap();
        let changed = editor
            .execute(Command::SetLanguage(FileService::language(&configuration)))?
            .language_changed;
        self.files.get_mut(&id).unwrap().configuration = configuration;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn interrupted_writes_reconcile_disk_before_releasing_reservation() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("new.txt");
        let mut workspace = Workspace::default();
        let id = workspace.new_document(Language::PlainText);
        workspace
            .editor_mut(id)
            .unwrap()
            .execute(Command::InsertText("saved".into()))
            .unwrap();
        let mut request = workspace.prepare_save(id, Some(&path)).unwrap();
        request.started = true;
        std::fs::write(&path, "saved").unwrap();
        drop(request);
        let result = workspace.poll_file_results().pop().unwrap().result.unwrap();
        assert!(!result.dirty);
        workspace.close(id).unwrap();
        let id = workspace.new_document(Language::PlainText);
        let mut request = workspace
            .prepare_save(id, Some(&directory.path().join("missing.txt")))
            .unwrap();
        request.started = true;
        drop(request);
        assert!(matches!(
            workspace.poll_file_results().pop().unwrap().result,
            Err(FileError::Interrupted)
        ));
        workspace.close(id).unwrap();
    }
}
