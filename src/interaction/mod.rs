//! Frontend-independent modal input and feature sessions. Widgets emit intents;
//! application commands remain the only route to editor mutation.
mod input;
mod search;
use crate::{
    application::{Application, Event, Update},
    core::EditError,
    editor::{Command, DocumentId},
};
pub use input::{InputKey, InputMotion, InputUpdate, TextInput};
pub use search::{SearchResults, SearchSession};
use std::{path::PathBuf, time::Duration};

pub enum Layer {
    Open(TextInput),
    Save(DocumentId, TextInput),
    Quit,
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
    Unrecognized,
}
enum Intent {
    Changed,
    SelectionChanged,
    Confirm,
    Cancel,
    Navigate { backward: bool },
}
/// An unrecognized event is blocked by a modal layer rather than reaching the
/// editing surface. Pass is reserved for input with no active layer.
enum Route {
    Pass,
    Blocked,
    Handled(Intent),
}
#[derive(Default)]
pub struct Layers {
    pub active: Option<Layer>,
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
            Self::Open(input) | Self::Save(_, input) | Self::Search { input, .. } => Some(input),
            Self::Quit => None,
        }
    }
    pub fn presentation(&self) -> Presentation {
        let (label, field) = match self {
            Self::Open(field) => ("Open: ".to_owned(), field),
            Self::Save(_, field) => ("Save as: ".to_owned(), field),
            Self::Search { input, session } => {
                (format!("Find [{}]: ", session.results().count), input)
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

/// Commands are applied after routing ends, so layer removal never occurs during
/// widget event handling. The host executes events and platform effects.
#[derive(Default)]
pub struct Response {
    pub events: Vec<Event>,
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
            Intent::Changed => {
                let mut response = self.preview(app, false, false, time)?;
                response.redraw = true;
                Ok(response)
            }
            Intent::Navigate { backward } => self.preview(app, backward, true, time),
            Intent::Confirm | Intent::Cancel => {
                let Some(layer) = self.active.take() else {
                    return Ok(Response::default());
                };
                let confirm = matches!(intent, Intent::Confirm);
                let mut response = Response {
                    redraw: true,
                    ..Response::default()
                };
                match layer {
                    Layer::Search { session, .. } => {
                        if confirm {
                            response.events.push(Event::Edit {
                                view: session.view(),
                                command: Command::SetSearchQuery(session.query().clone()),
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
                quit: false,
                redraw: true,
            });
        }
        Ok(Response {
            events: vec![Event::Edit {
                view: session.view(),
                command,
                time,
            }],
            quit: false,
            redraw: true,
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
