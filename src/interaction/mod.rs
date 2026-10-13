//! Frontend-independent input routing, application commands and modal sessions.
//! Widgets emit intents; application events are the route to editor mutation.
mod bindings;
mod commands;
mod routing;
pub use commands::Command;
pub use routing::{Key, KeyStroke, UserInput};
mod input;
pub mod picker;
use picker::{ListMotion, PickerCompletion, PickerEffect, PickerSession};
mod search;
use crate::{
    application::{Application, Event, Update},
    core::EditError,
    editor::{Command as EditCommand, DocumentId},
};
pub use input::{InputKey, InputMotion, InputUpdate, TextInput};
pub use search::{SearchResults, SearchSession};
use std::{path::PathBuf, time::Duration};

pub enum Layer {
    Goto {
        view: crate::application::ViewId,
        input: TextInput,
        error: bool,
    },
    Open(TextInput),
    Save(DocumentId, TextInput),
    Quit,
    Picker(PickerSession),
    Search {
        input: TextInput,
        session: SearchSession,
    },
}
pub enum Input {
    Text(InputKey),
    Paste(String),
    Confirm,
    Cancel,
    Navigate { backward: bool },
    Candidate { motion: ListMotion, wrap: bool },
    Unrecognized,
}
enum Intent {
    Changed,
    SelectionChanged,
    Confirm,
    Cancel,
    Navigate { backward: bool },
    Candidate { motion: ListMotion, wrap: bool },
}
/// An unrecognized event is blocked by a modal layer rather than reaching the
/// editing surface. Pass is reserved for input with no active layer.
enum Route {
    Pass,
    Blocked,
    Handled(Intent),
}
/// Owns modal transitions and cancellation. Read state through `active()` and
/// execute the responses returned by `enter`, `handle` and `close`.
///
/// ```compile_fail
/// let mut layers = soda::interaction::Layers::default();
/// layers.active = None;
/// ```
#[derive(Default)]
pub struct Layers {
    active: Option<Layer>,
    page_rows: usize,
}
/// A modal layer blocks unrecognized input. Handled input may change only its
/// selection, so redraw is independent of application commands and queries.
pub enum InputResult {
    Pass,
    Blocked,
    Handled(Response),
}
fn route_update(update: InputUpdate) -> Route {
    if update.text_changed {
        Route::Handled(Intent::Changed)
    } else if update.selection_changed {
        Route::Handled(Intent::SelectionChanged)
    } else {
        Route::Blocked
    }
}
impl Layers {
    pub fn active(&self) -> Option<&Layer> {
        self.active.as_ref()
    }
    /// Replace a modal layer through its cancellation contract. Hosts execute
    /// returned effects and events before accepting further input.
    pub fn enter(
        &mut self,
        layer: Layer,
        app: &Application,
        time: Duration,
    ) -> Result<Response, EditError> {
        let mut response = self.close(app, time)?;
        if let Layer::Picker(session) = &layer {
            response.effects.push(PickerEffect::Run(session.task()));
        }
        self.active = Some(layer);
        response.redraw = true;
        Ok(response)
    }
    pub fn close(&mut self, app: &Application, time: Duration) -> Result<Response, EditError> {
        self.respond(Intent::Cancel, app, time)
    }
    pub fn picker_failed(&mut self, error: String) -> Response {
        let Some(Layer::Picker(session)) = &mut self.active else {
            return Response::default();
        };
        session.fail(error);
        Response {
            redraw: true,
            ..Response::default()
        }
    }
    /// Route and reduce in one call; intents cannot outlive their owning layer.
    pub fn handle(
        &mut self,
        input: Input,
        app: &Application,
        time: Duration,
    ) -> Result<InputResult, EditError> {
        match self.route(input) {
            Route::Pass => Ok(InputResult::Pass),
            Route::Blocked => Ok(InputResult::Blocked),
            Route::Handled(intent) => self.respond(intent, app, time).map(InputResult::Handled),
        }
    }
    fn route(&mut self, event: Input) -> Route {
        let Some(layer) = &mut self.active else {
            return Route::Pass;
        };
        match event {
            Input::Candidate { motion, wrap } if matches!(layer, Layer::Picker(_)) => {
                Route::Handled(Intent::Candidate { motion, wrap })
            }
            Input::Cancel => Route::Handled(Intent::Cancel),
            Input::Confirm if matches!(layer, Layer::Quit) => Route::Handled(Intent::Cancel),
            Input::Confirm => Route::Handled(Intent::Confirm),
            Input::Navigate { backward } if matches!(layer, Layer::Search { .. }) => {
                Route::Handled(Intent::Navigate { backward })
            }
            Input::Text(InputKey::Char('y')) if matches!(layer, Layer::Quit) => {
                Route::Handled(Intent::Confirm)
            }
            Input::Text(InputKey::Char(_)) if matches!(layer, Layer::Quit) => {
                Route::Handled(Intent::Cancel)
            }
            Input::Text(_) if matches!(layer, Layer::Quit) => Route::Blocked,
            Input::Text(key) => route_update(layer.field_mut().unwrap().key(key)),
            Input::Paste(text) if !matches!(layer, Layer::Quit) => {
                route_update(layer.field_mut().unwrap().insert(&text))
            }
            _ => Route::Blocked,
        }
    }
}
pub struct Presentation {
    pub text: String,
    pub cursor: Option<usize>,
    pub selection: std::ops::Range<usize>,
}
impl Layer {
    fn field_mut(&mut self) -> Option<&mut TextInput> {
        match self {
            Self::Open(input)
            | Self::Save(_, input)
            | Self::Search { input, .. }
            | Self::Goto { input, .. } => Some(input),
            Self::Picker(session) => Some(session.input_mut()),
            Self::Quit => None,
        }
    }
    pub fn presentation(&self) -> Presentation {
        let (label, field) = match self {
            Self::Goto { input, error, .. } => (
                if *error {
                    "Go to line[:column] (positive numbers required): "
                } else {
                    "Go to line[:column]: "
                }
                .to_owned(),
                input,
            ),
            Self::Open(field) => ("Open: ".to_owned(), field),
            Self::Save(_, field) => ("Save as: ".to_owned(), field),
            Self::Search { input, session } => {
                (format!("Find [{}]: ", session.results().count), input)
            }
            Self::Picker(session) => {
                let status = match session.status() {
                    picker::PickerStatus::Loading => "loading".to_owned(),
                    picker::PickerStatus::Failed(error) => error.clone(),
                    picker::PickerStatus::Ready => {
                        let results = session.results();
                        format!(
                            "{}/{}{}{}",
                            results.rows.len(),
                            results.matched,
                            if results.truncated {
                                "; catalog truncated"
                            } else {
                                ""
                            },
                            if results.warnings.is_empty() {
                                ""
                            } else {
                                "; scan warnings"
                            }
                        )
                    }
                };
                (format!("Files [{status}]: "), session.input())
            }
            Self::Quit => {
                return Presentation {
                    text: "Unsaved changes: discard and quit? (y/N)".into(),
                    cursor: None,
                    selection: 0..0,
                };
            }
        };
        let selection = field.selection().range();
        Presentation {
            text: format!("{label}{}", field.text()),
            cursor: Some(label.len() + field.cursor()),
            selection: label.len() + selection.start..label.len() + selection.end,
        }
    }
}

/// Status-line message changes are explicit so widget updates can preserve the
/// current message while command invocation clears or replaces it.
#[derive(Default)]
pub enum Message {
    #[default]
    Keep,
    Clear,
    Set(String),
}

/// Commands are applied after routing ends, so layer removal never occurs during
/// widget event handling. The host executes events and platform effects.
#[derive(Default)]
pub struct Response {
    pub events: Vec<Event>,
    pub message: Message,
    pub effects: Vec<PickerEffect>,
    pub quit: bool,
    pub redraw: bool,
}
impl Layers {
    fn respond(
        &mut self,
        intent: Intent,
        app: &Application,
        time: Duration,
    ) -> Result<Response, EditError> {
        match intent {
            Intent::SelectionChanged => Ok(Response {
                redraw: true,
                ..Response::default()
            }),
            Intent::Changed if matches!(self.active, Some(Layer::Picker(_))) => {
                let Some(Layer::Picker(session)) = &mut self.active else {
                    unreachable!()
                };
                Ok(Response {
                    effects: session
                        .query_changed()
                        .map(PickerEffect::Run)
                        .into_iter()
                        .collect(),
                    redraw: true,
                    ..Response::default()
                })
            }
            Intent::Candidate { motion, wrap } => {
                let Some(Layer::Picker(session)) = &mut self.active else {
                    return Ok(Response::default());
                };
                Ok(Response {
                    redraw: session.navigate(motion, wrap),
                    ..Response::default()
                })
            }
            Intent::Changed => {
                if let Some(Layer::Goto { error, .. }) = &mut self.active {
                    *error = false;
                }
                let mut response = self.preview(app, false, false, time)?;
                response.redraw = true;
                Ok(response)
            }
            Intent::Navigate { backward } => self.preview(app, backward, true, time),
            Intent::Confirm | Intent::Cancel => {
                if matches!(intent, Intent::Confirm)
                    && matches!(&self.active, Some(Layer::Picker(session)) if session.selected_path().is_none())
                {
                    return Ok(Response::default());
                }
                if matches!(intent, Intent::Confirm)
                    && let Some(Layer::Goto { input, .. }) = &self.active
                    && parse_location(input.text()).is_none()
                {
                    if let Some(Layer::Goto { error, .. }) = &mut self.active {
                        *error = true;
                    }
                    return Ok(Response {
                        redraw: true,
                        ..Response::default()
                    });
                }
                let Some(layer) = self.active.take() else {
                    return Ok(Response::default());
                };
                let confirm = matches!(intent, Intent::Confirm);
                let mut response = Response {
                    redraw: true,
                    ..Response::default()
                };
                match layer {
                    Layer::Goto { view, input, .. } if confirm => {
                        let (line, column) = parse_location(input.text()).unwrap();
                        if app.view(view).is_some() {
                            response.events.push(Event::Edit {
                                view,
                                command: EditCommand::Goto { line, column },
                                time,
                            });
                        }
                    }
                    Layer::Picker(session) => {
                        response.effects.push(PickerEffect::Cancel(session.id()));
                        if confirm && let Some(path) = session.selected_path() {
                            response.events.push(Event::Open(path.to_owned()));
                        }
                    }
                    Layer::Search { session, .. } => {
                        if confirm {
                            response.events.push(Event::Edit {
                                view: session.view(),
                                command: EditCommand::SetSearchQuery(session.query().clone()),
                                time,
                            });
                        } else {
                            response.events = session.cancel(app, time)?;
                        }
                    }
                    Layer::Open(field) if confirm && !field.text().is_empty() => response
                        .events
                        .push(Event::Open(PathBuf::from(field.text()))),
                    Layer::Save(document, field) if confirm && !field.text().is_empty() => {
                        response.events.push(Event::Save {
                            document,
                            target: Some(PathBuf::from(field.text())),
                        })
                    }
                    Layer::Quit if confirm => response.quit = true,
                    _ => {}
                }
                Ok(response)
            }
        }
    }
    fn preview(
        &mut self,
        app: &Application,
        backward: bool,
        advance: bool,
        time: Duration,
    ) -> Result<Response, EditError> {
        let Some(Layer::Search { input, session }) = &mut self.active else {
            return Ok(Response::default());
        };
        session.set_query(input.text());
        let command = session.preview(app, backward, advance)?;
        if session.results().current.is_none() {
            return Ok(Response {
                events: session.cancel(app, time)?,
                redraw: true,
                ..Response::default()
            });
        }
        Ok(Response {
            events: vec![Event::Edit {
                view: session.view(),
                command,
                time,
            }],
            redraw: true,
            ..Response::default()
        })
    }
    /// Hosts must observe every successful application update in order, including
    /// updates from other views. A focus change ends the active search session.
    pub fn observe(
        &mut self,
        app: &Application,
        update: &Update,
        time: Duration,
    ) -> Result<Response, EditError> {
        if let Some(Layer::Goto { view, .. }) = &self.active
            && (app.view(*view).is_none() || app.active_view() != Some(*view))
        {
            return self.close(app, time);
        }
        if let Some(Layer::Save(document, _)) = &self.active
            && app.workspace().editor(*document).is_none()
        {
            self.active = None;
            return Ok(Response {
                redraw: true,
                ..Response::default()
            });
        }
        let Some(Layer::Search { session, .. }) = &mut self.active else {
            return Ok(Response::default());
        };
        if !session.observe(app, update)? {
            self.active = None;
            return Ok(Response {
                redraw: true,
                ..Response::default()
            });
        }
        if app.active_view() != Some(session.view()) {
            return self.respond(Intent::Cancel, app, time);
        }
        if update.edit.as_ref().is_some_and(|edit| {
            edit.text_changed && edit.document_id == app.view(session.view()).unwrap().document_id
        }) {
            return self.preview(app, false, false, time);
        }
        Ok(Response::default())
    }
}

impl Layers {
    /// End the preceding modal session before installing a new picker.
    pub fn start_picker(
        &mut self,
        session: PickerSession,
        app: &Application,
        time: Duration,
    ) -> Result<Response, EditError> {
        self.enter(Layer::Picker(session), app, time)
    }

    pub fn picker_finished(&mut self, completion: PickerCompletion) -> Response {
        let Some(Layer::Picker(session)) = &mut self.active else {
            return Response::default();
        };
        Response {
            redraw: session.accept(completion),
            ..Response::default()
        }
    }
    pub fn resize_picker(&mut self, rows: usize) -> bool {
        match &mut self.active {
            Some(Layer::Picker(session)) => session.resize(rows),
            _ => false,
        }
    }
}

fn parse_location(text: &str) -> Option<(usize, usize)> {
    let (line, column) = text.trim().split_once(':').unwrap_or((text.trim(), "1"));
    Some((
        line.parse::<usize>().ok()?.checked_sub(1)?,
        column.parse::<usize>().ok()?.checked_sub(1)?,
    ))
}
