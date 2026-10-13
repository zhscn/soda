//! Document-bound departure workflows. Save effects are observed to completion
//! before closing, reloading or quitting; cancellation leaves writes independent.
use super::{Input, InputKey, Message, Presentation, Response, TextInput};
use crate::{
    application::{Application, Effect, Event, Update},
    editor::DocumentId,
};
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Clone, Copy, Debug)]
pub enum ExitScope {
    Close(DocumentId),
    Reload(DocumentId),
    Quit,
}
enum Phase {
    Question,
    Path(TextInput),
    Saving {
        target: Option<PathBuf>,
        revision: Option<u64>,
    },
}
pub struct ExitSession {
    scope: ExitScope,
    current: DocumentId,
    phase: Phase,
    discarded: BTreeMap<DocumentId, u64>,
    name: String,
    error: Option<String>,
}
pub(super) struct Transition {
    pub response: Response,
    pub finished: bool,
}
impl Transition {
    fn active(response: Response) -> Self {
        Self {
            response,
            finished: false,
        }
    }
    fn finished(response: Response) -> Self {
        Self {
            response,
            finished: true,
        }
    }
}
impl ExitSession {
    pub fn new(app: &Application, scope: ExitScope) -> Option<Self> {
        let current = match scope {
            ExitScope::Close(document) | ExitScope::Reload(document) => document,
            ExitScope::Quit => app.workspace().documents().find(|id| {
                app.workspace()
                    .editor(*id)
                    .unwrap()
                    .model()
                    .document()
                    .is_dirty()
            })?,
        };
        app.workspace().editor(current)?;
        Some(Self {
            scope,
            current,
            phase: Phase::Question,
            discarded: BTreeMap::new(),
            name: document_name(app, current),
            error: None,
        })
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
                let label = format!("Save as{error}: ");
                let selected = input.selection().range();
                (
                    format!("{label}{}", input.text()),
                    Some(label.len() + input.cursor()),
                    label.len() + selected.start..label.len() + selected.end,
                )
            }
        };
        Presentation {
            text,
            cursor,
            selection,
        }
    }
    pub(super) fn handle(&mut self, input: Input, app: &Application) -> Option<Transition> {
        let redraw = || Response {
            redraw: true,
            ..Response::default()
        };
        match input {
            Input::Cancel => Some(Transition::finished(redraw())),
            Input::Confirm if matches!(self.phase, Phase::Question) => {
                Some(Transition::finished(redraw()))
            }
            Input::Text(InputKey::Char('s' | 'S')) if matches!(self.phase, Phase::Question) => {
                Some(self.save(app, None))
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
                Some(self.advance(app, true))
            }
            Input::Text(InputKey::Char(_)) if matches!(self.phase, Phase::Question) => {
                Some(Transition::finished(redraw()))
            }
            Input::Confirm if matches!(self.phase, Phase::Path(_)) => {
                let Phase::Path(field) = &self.phase else {
                    unreachable!()
                };
                if field.text().is_empty() {
                    return None;
                }
                Some(self.save(app, Some(PathBuf::from(field.text()))))
            }
            input if matches!(self.phase, Phase::Path(_)) => {
                let Phase::Path(field) = &mut self.phase else {
                    unreachable!()
                };
                let update = match input {
                    Input::Text(key) => field.key(key),
                    Input::Paste(text) => field.insert(&text),
                    _ => return None,
                };
                if update.text_changed {
                    self.error = None;
                }
                if update.text_changed || update.selection_changed {
                    Some(Transition::active(redraw()))
                } else {
                    None
                }
            }
            _ => None,
        }
    }
    fn save(&mut self, app: &Application, target: Option<PathBuf>) -> Transition {
        let Some(editor) = app.workspace().editor(self.current) else {
            return self.advance(app, false);
        };
        if target.is_none() && editor.model().document().file().path().is_none() {
            self.phase = Phase::Path(TextInput::default());
            return Transition::active(Response {
                redraw: true,
                ..Response::default()
            });
        }
        self.phase = Phase::Saving {
            target: target.clone(),
            revision: None,
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
    /// Save preflight failures do not emit updates. Hosts report the error here.
    pub(super) fn failed(&mut self, error: String) -> Response {
        let target = match &self.phase {
            Phase::Saving { target, .. } => target.clone(),
            _ => return Response::default(),
        };
        self.phase = target.map_or(Phase::Question, |path| {
            Phase::Path(TextInput::new(&path.to_string_lossy()))
        });
        self.error = Some(error);
        Response {
            redraw: true,
            ..Response::default()
        }
    }
    pub(super) fn observe(&mut self, app: &Application, update: &Update) -> Transition {
        if app.workspace().editor(self.current).is_none() {
            return self.advance(app, false);
        }
        self.name = document_name(app, self.current);
        if let Phase::Saving { revision, .. } = &mut self.phase {
            for effect in &update.effects {
                if let Effect::Save(request) = effect
                    && request.document_id() == self.current
                {
                    *revision = Some(request.revision());
                }
            }
            for file in &update.files {
                if file.document_id != self.current {
                    continue;
                }
                match &file.result {
                    Ok(file) if Some(file.saved_revision) == *revision => {
                        if app
                            .workspace()
                            .editor(self.current)
                            .unwrap()
                            .model()
                            .document()
                            .is_dirty()
                        {
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
                    _ => {}
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
            ExitScope::Reload(document) => {
                if app.workspace().editor(document).is_some() {
                    response.events.push(Event::Reload { document, discard });
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
                        && app
                            .workspace()
                            .editor(*id)
                            .unwrap()
                            .model()
                            .document()
                            .is_dirty()
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
        .editor(document)
        .and_then(|editor| editor.model().document().file().path())
        .map_or_else(
            || "[untitled]".to_owned(),
            |path| path.display().to_string(),
        )
}
