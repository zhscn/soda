//! Document-bound departure workflows. Save effects are observed to completion
//! before closing, reloading or quitting; cancellation leaves writes independent.
use super::{
    Input, InputKey, Message, Presentation, Response,
    path::{PathAction, PathCompletion, PathInput},
    session::Transition,
};
use crate::{
    application::{Application, Effect, Event, Update},
    editor::DocumentId,
};
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Clone, Copy, Debug)]
pub enum ExitScope {
    Close(DocumentId),
    Reload(crate::application::ViewId),
    Quit,
}
enum Phase {
    Question,
    Path(PathInput),
    Saving {
        target: Option<PathBuf>,
        request: Option<crate::files::SaveId>,
    },
}
pub struct ExitSession {
    root: PathBuf,
    page_rows: usize,
    scope: ExitScope,
    current: DocumentId,
    phase: Phase,
    discarded: BTreeMap<DocumentId, u64>,
    name: String,
    error: Option<String>,
}
impl ExitSession {
    pub fn new(app: &Application, scope: ExitScope) -> Option<Self> {
        Self::new_with_root(app, scope, std::env::current_dir().ok()?)
    }
    pub(super) fn new_with_root(
        app: &Application,
        scope: ExitScope,
        root: PathBuf,
    ) -> Option<Self> {
        let current = match scope {
            ExitScope::Close(document) => document,
            ExitScope::Reload(view) => app.view(view)?.document_id,
            ExitScope::Quit => app
                .workspace()
                .documents()
                .find(|id| app.workspace().is_dirty(*id))?,
        };
        app.workspace().editor(current)?;
        Some(Self {
            root,
            page_rows: 0,
            scope,
            current,
            phase: Phase::Question,
            discarded: BTreeMap::new(),
            name: document_name(app, current),
            error: None,
        })
    }
    pub(super) fn write_quit(app: &Application, root: PathBuf) -> Option<Self> {
        let current = app.view(app.active_view()?)?.document_id;
        if !app.workspace().is_dirty(current) {
            return None;
        }
        let mut session = Self::new_with_root(app, ExitScope::Quit, root)?;
        session.current = current;
        session.name = document_name(app, current);
        Some(session)
    }
    pub fn document(&self) -> DocumentId {
        self.current
    }
    pub(super) fn presentation(&self) -> Presentation {
        let name = &self.name;
        let error = self
            .error
            .as_ref()
            .map_or(String::new(), |error| format!(" [{error}]"));
        let action = match self.scope {
            ExitScope::Close(_) => "close",
            ExitScope::Reload(_) => "reload",
            ExitScope::Quit => "quit",
        };
        let (text, cursor, selection) = match &self.phase {
            Phase::Question => (
                format!("Unsaved changes: {name}{error} — {action}: (s)ave, (d)iscard, (c)ancel"),
                None,
                0..0,
            ),
            Phase::Saving { .. } => (format!("Saving {name}; Esc cancels departure"), None, 0..0),
            Phase::Path(input) => {
                let p = input.presentation(&format!("Save as{error}"));
                (p.text, p.cursor, p.selection)
            }
        };
        Presentation {
            text,
            cursor,
            selection,
        }
    }
    pub(super) fn handle(&mut self, input: Input, app: &Application) -> Transition {
        let redraw = || Response {
            redraw: true,
            ..Response::default()
        };
        match input {
            Input::Cancel if !matches!(self.phase, Phase::Path(_)) => {
                Transition::finished(redraw())
            }
            Input::Confirm if matches!(self.phase, Phase::Question) => {
                Transition::finished(redraw())
            }
            Input::Text(InputKey::Char('s' | 'S')) if matches!(self.phase, Phase::Question) => {
                self.save(app, None)
            }
            Input::Text(InputKey::Char('d' | 'D' | 'y'))
                if matches!(self.phase, Phase::Question) =>
            {
                if matches!(self.scope, ExitScope::Quit) {
                    self.discarded.insert(
                        self.current,
                        app.workspace()
                            .editor(self.current)
                            .unwrap()
                            .model()
                            .document()
                            .snapshot()
                            .version(),
                    );
                }
                self.advance(app, true)
            }
            Input::Text(InputKey::Char(_)) if matches!(self.phase, Phase::Question) => {
                Transition::finished(redraw())
            }
            input if matches!(self.phase, Phase::Path(_)) => {
                let Phase::Path(field) = &mut self.phase else {
                    unreachable!()
                };
                match field.handle(input) {
                    PathAction::Active(response) => {
                        self.error = None;
                        Transition::active(response)
                    }
                    PathAction::Submit(path) => self.save(app, Some(path)),
                    PathAction::Cancel => Transition::close(),
                    PathAction::Blocked => Transition::Blocked,
                }
            }
            _ => Transition::Blocked,
        }
    }
    pub fn path_input(&self) -> Option<&PathInput> {
        match &self.phase {
            Phase::Path(field) => Some(field),
            _ => None,
        }
    }
    pub(super) fn path_finished(&mut self, completion: PathCompletion) -> bool {
        match &mut self.phase {
            Phase::Path(field) => field.accept(completion),
            _ => false,
        }
    }
    pub(super) fn resize(&mut self, rows: usize) {
        self.page_rows = rows;
        if let Phase::Path(field) = &mut self.phase {
            field.resize(rows);
        }
    }
    fn save(&mut self, app: &Application, target: Option<PathBuf>) -> Transition {
        let Some(file) = app.workspace().file(self.current) else {
            return self.advance(app, false);
        };
        if target.is_none() && file.path().is_none() {
            self.phase = Phase::Path(PathInput::new(self.root.clone(), ""));
            self.resize(self.page_rows);
            return Transition::active(Response {
                redraw: true,
                ..Response::default()
            });
        }
        self.phase = Phase::Saving {
            target: target.clone(),
            request: None,
        };
        self.error = None;
        Transition::active(Response {
            events: vec![Event::Save {
                document: self.current,
                target,
            }],
            redraw: true,
            ..Response::default()
        })
    }
    pub(super) fn operation_failed(
        &mut self,
        operation: crate::application::Operation,
        error: String,
    ) -> Response {
        let Phase::Saving {
            request: pending, ..
        } = &self.phase
        else {
            return Response::default();
        };
        if operation
            == (crate::application::Operation::Save {
                document: self.current,
                request: *pending,
            })
        {
            self.failed(error)
        } else {
            Response::default()
        }
    }
    /// Save preflight failures do not emit updates. Hosts report the error here.
    pub(super) fn failed(&mut self, error: String) -> Response {
        let target = match &self.phase {
            Phase::Saving { target, .. } => target.clone(),
            _ => return Response::default(),
        };
        self.phase = target.map_or(Phase::Question, |path| {
            Phase::Path(PathInput::new(self.root.clone(), &path.to_string_lossy()))
        });
        self.resize(self.page_rows);
        self.error = Some(error);
        Response {
            redraw: true,
            ..Response::default()
        }
    }
    pub(super) fn observe(&mut self, app: &Application, update: &Update) -> Transition {
        if matches!(self.scope, ExitScope::Reload(view) if app.view(view).is_none()) {
            return Transition::finished(Response {
                redraw: true,
                ..Response::default()
            });
        }
        if app.workspace().editor(self.current).is_none() {
            return self.advance(app, false);
        }
        self.name = document_name(app, self.current);
        if let Phase::Saving {
            request: pending, ..
        } = &mut self.phase
        {
            for effect in &update.effects {
                if let Effect::Save(request) = effect
                    && request.document_id() == self.current
                    && pending.is_none()
                {
                    *pending = Some(request.id());
                }
            }
            for file in &update.files {
                if file.document_id != self.current || file.request != *pending || pending.is_none()
                {
                    continue;
                }
                match &file.result {
                    Ok(_) => {
                        if app.workspace().is_dirty(self.current) {
                            self.phase = Phase::Question;
                            self.error = Some("Newer edits remain; save again or cancel".into());
                            return Transition::active(Response {
                                redraw: true,
                                ..Response::default()
                            });
                        }
                        return self.advance(app, false);
                    }
                    Err(error) => return Transition::active(self.failed(error.to_string())),
                }
            }
        }
        Transition::active(Response::default())
    }
    fn advance(&mut self, app: &Application, discard: bool) -> Transition {
        let mut response = Response {
            redraw: true,
            ..Response::default()
        };
        match self.scope {
            ExitScope::Close(document) => {
                if app.workspace().editor(document).is_some() {
                    response
                        .events
                        .push(Event::CloseDocument { document, discard });
                }
            }
            ExitScope::Reload(view) => {
                if app.view(view).is_some() {
                    response.events.push(Event::Reload { view, discard });
                }
            }
            ExitScope::Quit => {
                if let Some(document) = app.workspace().documents().find(|id| {
                    self.discarded.get(id).copied()
                        != Some(
                            app.workspace()
                                .editor(*id)
                                .unwrap()
                                .model()
                                .document()
                                .snapshot()
                                .version(),
                        )
                        && app.workspace().is_dirty(*id)
                }) {
                    self.current = document;
                    self.name = document_name(app, document);
                    self.phase = Phase::Question;
                    self.error = None;
                    return Transition::active(response);
                }
                if app
                    .workspace()
                    .documents()
                    .any(|id| app.workspace().is_saving(id))
                {
                    response.message =
                        Message::Set("Save in progress; quit after it completes".into());
                } else {
                    response.quit = true;
                }
            }
        }
        Transition::finished(response)
    }
}

fn document_name(app: &Application, document: DocumentId) -> String {
    app.workspace()
        .file(document)
        .and_then(|file| file.path())
        .map_or_else(
            || "[untitled]".to_owned(),
            |path| path.display().to_string(),
        )
}
