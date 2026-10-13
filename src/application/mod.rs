//! Owner-thread application reducer. Hosts execute returned file effects and
//! feed completions back as events; terminal input and rendering stay outside.
//!
//! Each view has a dedicated session and stays bound to one document. The
//! document's default session remains an internal fallback. Closing all views
//! leaves the document available for a later AddView; CloseDocument is explicit.
//! Only the latest accepted open request may activate a view, and only if focus
//! has not changed since that request. Cancelled reads cannot create views. Save
//! completions identify their document independently of focus and retain the exact
//! saved revision.
//!
//! Hosts consume Update after each dispatch, execute effects using a cloned
//! FileService, and enqueue the resulting completion events on the owner thread.
//! PollFiles drains request/completion drop notifications. Reading workspace and
//! view state after an error reveals the current document and reservation state.
//! Path/configuration preflight and explicit Reload currently run synchronously.
mod clipboard;
pub use clipboard::ClipboardAction;

use crate::{
    core::{Association, ByteOffset, EditError, Selection},
    editor::{Command, DocumentId, DocumentPosition, EditorUpdate, Language, SessionId},
    files::{
        FileError, FileResult, FileService, FileUpdate, OpenCompletion, OpenId, OpenPreparation,
        OpenRequest, SaveCompletion, SaveRequest, Workspace,
    },
};
use std::{collections::BTreeMap, fmt, path::PathBuf, time::Duration};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct ViewId(u64);

/// A view owns a dedicated editing session. Its anchor is a text position;
/// display rows and screen coordinates are resolved by the frontend.
#[derive(Clone, Debug)]
pub struct View {
    pub id: ViewId,
    pub document_id: DocumentId,
    pub session_id: SessionId,
    pub viewport: Viewport,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Viewport {
    pub anchor: DocumentPosition,
    pub horizontal_column: usize,
}

pub enum Event {
    Clipboard {
        view: ViewId,
        action: ClipboardAction,
        time: Duration,
    },
    NewDocument(Language),
    AddView(DocumentId),
    Focus(ViewId),
    CloseView(ViewId),
    CloseDocument {
        document: DocumentId,
        discard: bool,
    },
    Edit {
        view: ViewId,
        command: Command,
        time: Duration,
    },
    SetViewport {
        view: ViewId,
        anchor: ByteOffset,
        horizontal_column: usize,
    },
    Open(PathBuf),
    CancelOpen(OpenId),
    OpenFinished(OpenCompletion),
    Save {
        document: DocumentId,
        target: Option<PathBuf>,
    },
    SaveFinished(SaveCompletion),
    Reload {
        document: DocumentId,
        discard: bool,
    },
    PollFiles,
}
/// Single-use requests may run on a worker using `FileService`. The application
/// delegates file payload I/O to the host; path/configuration preflight remains
/// synchronous. The host chooses its executor and completion queue.
pub enum Effect {
    Open(OpenRequest),
    Save(Box<SaveRequest>),
}
#[derive(Default)]
pub struct Update {
    pub effects: Vec<Effect>,
    pub changed_views: Vec<ViewId>,
    pub closed_views: Vec<ViewId>,
    pub closed_documents: Vec<DocumentId>,
    pub active_changed: bool,
    pub edit: Option<EditorUpdate>,
    pub files: Vec<FileResult>,
}
#[derive(Debug)]
pub enum Error {
    UnknownView,
    File(FileError),
}
impl From<FileError> for Error {
    fn from(error: FileError) -> Self {
        Self::File(error)
    }
}
impl From<EditError> for Error {
    fn from(error: EditError) -> Self {
        Self::File(error.into())
    }
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownView => f.write_str("unknown view"),
            Self::File(e) => e.fmt(f),
        }
    }
}
impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::File(e) => Some(e),
            Self::UnknownView => None,
        }
    }
}

#[derive(Clone, Copy)]
struct OpenIntent {
    focus_revision: u64,
    open_revision: u64,
}
#[derive(Default)]
pub struct Application {
    workspace: Workspace,
    views: BTreeMap<ViewId, View>,
    active: Option<ViewId>,
    next_view: u64,
    focus_revision: u64,
    open_revision: u64,
    pending_opens: BTreeMap<OpenId, OpenIntent>,
    clipboard: String,
}
impl Application {
    pub fn new(service: FileService) -> Self {
        Self {
            workspace: Workspace::new(service),
            ..Self::default()
        }
    }
    /// Read-only access prevents edits from bypassing viewport/update mapping.
    pub fn workspace(&self) -> &Workspace {
        &self.workspace
    }
    pub fn views(&self) -> impl Iterator<Item = &View> {
        self.views.values()
    }
    pub fn view(&self, id: ViewId) -> Option<&View> {
        self.views.get(&id)
    }
    pub fn active_view(&self) -> Option<ViewId> {
        self.active
    }

    fn focus(&mut self, view: Option<ViewId>) {
        // Focus revisions distinguish switching away and back while a read runs.
        self.focus_revision = self
            .focus_revision
            .checked_add(1)
            .expect("focus revisions exhausted");
        self.active = view;
    }
    fn add_view(&mut self, document: DocumentId) -> Result<ViewId, Error> {
        let next = self
            .next_view
            .checked_add(1)
            .ok_or(EditError::VersionExhausted)?;
        let editor = self
            .workspace
            .editor(document)
            .ok_or(FileError::UnknownDocument)?;
        let anchor = editor
            .model()
            .document()
            .position(ByteOffset(0), Association::Before)?;
        let session = self
            .workspace
            .editor_mut(document)
            .unwrap()
            .add_session(Selection::caret(0))?;
        let id = ViewId(next);
        self.next_view = next;
        self.views.insert(
            id,
            View {
                id,
                document_id: document,
                session_id: session,
                viewport: Viewport {
                    anchor,
                    horizontal_column: 0,
                },
            },
        );
        Ok(id)
    }
    fn changed_document(&self, document: DocumentId, update: &mut Update) {
        update.changed_views.extend(
            self.views
                .values()
                .filter(|v| v.document_id == document)
                .map(|v| v.id),
        );
    }
    fn accept_edit(&mut self, edit: EditorUpdate, update: &mut Update) {
        if let Some(change) = &edit.document {
            for view in self
                .views
                .values_mut()
                .filter(|v| v.document_id == edit.document_id)
            {
                view.viewport.anchor = view
                    .viewport
                    .anchor
                    .map(change, false)
                    .expect("application maps every document revision")
                    .unwrap();
            }
        }
        self.changed_document(edit.document_id, update);
        update.edit = Some(edit);
    }
    fn accept_file(
        &self,
        file: FileUpdate,
        request: Option<crate::files::SaveId>,
        update: &mut Update,
    ) {
        self.changed_document(file.document_id, update);
        update.files.push(FileResult {
            request,
            document_id: file.document_id,
            result: Ok(file),
        });
    }
    fn edit(
        &mut self,
        view: ViewId,
        command: Command,
        time: Duration,
        update: &mut Update,
    ) -> Result<(), Error> {
        let view = self.views.get(&view).ok_or(Error::UnknownView)?;
        let edit = self
            .workspace
            .editor_mut(view.document_id)
            .unwrap()
            .execute_at(view.session_id, command, time)?;
        self.accept_edit(edit, update);
        Ok(())
    }
    /// Reduce one event. Effects are returned only after reservations are made.
    /// Closing a view retains its document, including unsaved edits. Closing a
    /// document validates dirty/pending-save constraints before removing views.
    pub fn dispatch(&mut self, event: Event) -> Result<Update, Error> {
        let before = self.active;
        let mut update = Update::default();
        match event {
            Event::NewDocument(language) => {
                let document = self.workspace.new_document(language);
                let view = self.add_view(document)?;
                update.changed_views.push(view);
                self.focus(Some(view));
            }
            Event::AddView(document) => {
                let view = self.add_view(document)?;
                update.changed_views.push(view);
                self.focus(Some(view));
            }
            Event::Focus(view) => {
                self.views.get(&view).ok_or(Error::UnknownView)?;
                self.focus(Some(view));
            }
            Event::CloseView(view) => {
                let state = self.views.get(&view).ok_or(Error::UnknownView)?;
                self.workspace
                    .editor_mut(state.document_id)
                    .unwrap()
                    .close_session(state.session_id)?;
                self.views.remove(&view);
                update.closed_views.push(view);
                if self.active == Some(view) {
                    self.focus(self.views.keys().next().copied());
                }
            }
            Event::CloseDocument { document, discard } => {
                if discard {
                    self.workspace.discard_document(document)?;
                } else {
                    self.workspace.close(document)?;
                }
                let ids: Vec<_> = self
                    .views
                    .values()
                    .filter(|v| v.document_id == document)
                    .map(|v| v.id)
                    .collect();
                for id in &ids {
                    self.views.remove(id);
                }
                if self.active.is_some_and(|id| ids.contains(&id)) {
                    self.focus(self.views.keys().next().copied());
                }
                update.closed_views = ids;
                update.closed_documents.push(document);
            }
            Event::Edit {
                view,
                command,
                time,
            } => {
                self.edit(view, command, time, &mut update)?;
            }
            Event::Clipboard { view, action, time } => {
                self.clipboard_action(view, action, time, &mut update)?;
            }
            Event::SetViewport {
                view,
                anchor,
                horizontal_column,
            } => {
                let state = self.views.get_mut(&view).ok_or(Error::UnknownView)?;
                let document = self
                    .workspace
                    .editor(state.document_id)
                    .unwrap()
                    .model()
                    .document();
                state.viewport = Viewport {
                    anchor: document.position(anchor, Association::Before)?,
                    horizontal_column,
                };
                update.changed_views.push(view);
            }
            Event::Open(path) => {
                let next = self
                    .open_revision
                    .checked_add(1)
                    .ok_or(EditError::VersionExhausted)?;
                let preparation = self.workspace.prepare_open(&path)?;
                self.open_revision = next;
                match preparation {
                    OpenPreparation::Existing(document) => {
                        let view = match self.views.values().find(|v| v.document_id == document) {
                            Some(view) => view.id,
                            None => {
                                let id = self.add_view(document)?;
                                update.changed_views.push(id);
                                id
                            }
                        };
                        self.focus(Some(view));
                    }
                    OpenPreparation::Request(request) => {
                        self.pending_opens.insert(
                            request.id(),
                            OpenIntent {
                                focus_revision: self.focus_revision,
                                open_revision: self.open_revision,
                            },
                        );
                        update.effects.push(Effect::Open(request));
                    }
                }
            }
            Event::CancelOpen(id) => {
                self.workspace.cancel_open(id)?;
                self.pending_opens.remove(&id);
            }
            Event::OpenFinished(completion) => {
                let revision = self.pending_opens.remove(&completion.id());
                let document = self.workspace.finish_open(completion)?;
                let view = self.add_view(document)?;
                update.changed_views.push(view);
                if revision.is_some_and(|intent| {
                    intent.focus_revision == self.focus_revision
                        && intent.open_revision == self.open_revision
                }) {
                    self.focus(Some(view));
                }
            }
            Event::Save { document, target } => {
                update.effects.push(Effect::Save(Box::new(
                    self.workspace.prepare_save(document, target.as_deref())?,
                )));
                self.changed_document(document, &mut update);
            }
            Event::SaveFinished(completion) => {
                let request = completion.id();
                let file = self.workspace.finish_save(completion)?;
                self.accept_file(file, Some(request), &mut update);
            }
            Event::Reload { document, discard } => {
                let result = self.workspace.reload(document, discard)?;
                self.accept_edit(result.edit, &mut update);
                self.accept_file(result.file, None, &mut update);
            }
            Event::PollFiles => {
                update.files = self.workspace.poll_file_results();
                self.pending_opens
                    .retain(|id, _| self.workspace.is_open_pending(*id));
                let documents: Vec<_> = update.files.iter().map(|r| r.document_id).collect();
                for document in documents {
                    self.changed_document(document, &mut update);
                }
            }
        }
        update.active_changed = before != self.active;
        update.changed_views.sort_unstable();
        update.changed_views.dedup();
        Ok(update)
    }
}
