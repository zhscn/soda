//! The waiting step of a departure. `close save`, `reload save` and
//! `quit save` request the save and wait here; success runs the departure
//! command again, which now finds the document clean or asks once more if
//! newer edits arrived. Failure reopens the command line to retry. Cancelling
//! stops the departure only; the write itself continues.
use super::{Command, Input, Presentation, Response, session::Transition};
use crate::{
    application::{Application, Effect, Operation, Update, ViewId},
    editor::DocumentId,
    files::SaveId,
};

pub struct SaveWait {
    document: DocumentId,
    view: Option<ViewId>,
    request: Option<SaveId>,
    name: String,
    then: String,
    retry: String,
}
impl SaveWait {
    /// Waits for the next save of `document`, then runs `then`; a failure
    /// reopens the command line with `retry`.
    pub fn new(app: &Application, document: DocumentId, then: String, retry: String) -> Self {
        Self {
            document,
            view: app.active_view(),
            request: None,
            name: app.document_name(document),
            then,
            retry,
        }
    }
    pub fn document(&self) -> DocumentId {
        self.document
    }
    pub(super) fn presentation(&self) -> Presentation {
        Presentation {
            text: format!("Saving {}; Esc cancels {}", self.name, self.then),
            cursor: None,
            selection: 0..0,
        }
    }
    pub(super) fn handle(&mut self, input: Input) -> Transition {
        match input {
            Input::Cancel => Transition::close(),
            _ => Transition::Blocked,
        }
    }
    fn failed(&self, error: String) -> Transition {
        Transition::finished(Response {
            commands: vec![Command::Ask {
                line: self.retry.clone(),
                note: format!("save failed: {error}"),
            }],
            redraw: true,
            ..Response::default()
        })
    }
    /// Save preflight and submission failures carry the operation identity.
    pub(super) fn operation_failed(
        &self,
        operation: Operation,
        error: String,
    ) -> Option<Transition> {
        (operation
            == Operation::Save {
                document: self.document,
                request: self.request,
            })
        .then(|| self.failed(error))
    }
    pub(super) fn observe(&mut self, app: &Application, update: &Update) -> Transition {
        // Like the command line, a departure acts on the view it started in.
        if app.active_view() != self.view || app.workspace().editor(self.document).is_none() {
            return Transition::close();
        }
        for effect in &update.effects {
            if let Effect::Save(request) = effect
                && request.document_id() == self.document
                && self.request.is_none()
            {
                self.request = Some(request.id());
            }
        }
        for file in &update.files {
            if file.document_id != self.document
                || self.request.is_none()
                || file.request != self.request
            {
                continue;
            }
            return match &file.result {
                Ok(_) => Transition::finished(Response {
                    commands: vec![Command::Named(self.then.clone())],
                    redraw: true,
                    ..Response::default()
                }),
                Err(error) => self.failed(error.to_string()),
            };
        }
        Transition::active(Response::default())
    }
}
