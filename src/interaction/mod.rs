//! Frontend-independent routing and built-in sessions. Layers own lifecycle;
//! feature reducers return transitions and Runtime executes their responses.
mod bindings;
mod commands;
pub use commands::Command;
mod exit;
pub use exit::{ExitScope, ExitSession};
pub mod help;
pub use help::HelpSession;
mod input;
pub use input::{InputKey, InputMotion, InputUpdate, TextInput};
mod layer;
pub use layer::Layer;
pub mod picker;
use picker::{ListMotion, PickerCompletion, PickerEffect, PickerSession};
mod prompt;
pub use prompt::GotoSession;
mod replace;
pub use replace::{ReplacePhase, ReplaceSession};
mod routing;
pub use routing::{Key, KeyStroke, UserInput};
mod search;
pub use search::{SearchResults, SearchSession};
mod session;
use crate::{
    application::{Application, Event, Operation, Update},
    core::EditError,
};
use session::Transition;
use std::time::Duration;

pub enum Input {
    Help,
    Text(InputKey),
    Paste(String),
    Confirm,
    ReplaceAll,
    Cancel,
    Navigate { backward: bool },
    Candidate { motion: ListMotion, wrap: bool },
    Unrecognized,
}
pub enum InputResult {
    Pass,
    Blocked,
    Handled(Response),
}
pub struct Presentation {
    pub text: String,
    pub cursor: Option<usize>,
    pub selection: std::ops::Range<usize>,
}
#[derive(Default)]
pub enum Message {
    #[default]
    Keep,
    Clear,
    Set(String),
}
/// Events execute in order after session reduction. Runtime stops the batch at
/// its first failure and requests quit only after its events succeed.
#[derive(Default)]
pub struct Response {
    pub events: Vec<Event>,
    pub message: Message,
    pub effects: Vec<PickerEffect>,
    pub quit: bool,
    pub redraw: bool,
}
/// Owns one modal layer. Read-only access keeps lifecycle transitions inside
/// this manager; callers must execute responses and observe resulting updates.
///
/// ```compile_fail
/// let mut layers = soda::interaction::Layers::default();
/// layers.active = None;
/// ```
#[derive(Default)]
pub struct Layers {
    active: Option<Layer>,
    page_rows: usize,
    help_rows: usize,
    picker_rows: usize,
}
impl Layers {
    pub fn active(&self) -> Option<&Layer> {
        self.active.as_ref()
    }
    pub fn enter(
        &mut self,
        mut layer: Layer,
        app: &Application,
        time: Duration,
    ) -> Result<Response, EditError> {
        let mut response = self.close(app, time)?;
        if let Layer::Picker(session) = &layer {
            response.effects.push(PickerEffect::Run(session.task()));
        }
        layer.resize(self.help_rows, self.picker_rows);
        self.active = Some(layer);
        response.redraw = true;
        Ok(response)
    }
    pub fn close(&mut self, app: &Application, time: Duration) -> Result<Response, EditError> {
        let Some(mut layer) = self.active.take() else {
            return Ok(Response::default());
        };
        Ok(match layer.handle(Input::Cancel, app, time)? {
            Transition::Active(response) | Transition::Closed(response) => response,
            Transition::Blocked => Response::default(),
        })
    }
    fn transition(&mut self, transition: Transition) -> Option<Response> {
        match transition {
            Transition::Blocked => None,
            Transition::Active(response) => Some(response),
            Transition::Closed(response) => {
                self.active = None;
                Some(response)
            }
        }
    }
    pub fn handle(
        &mut self,
        input: Input,
        app: &Application,
        time: Duration,
    ) -> Result<InputResult, EditError> {
        let Some(layer) = &mut self.active else {
            return Ok(InputResult::Pass);
        };
        let transition = layer.handle(input, app, time)?;
        Ok(self
            .transition(transition)
            .map_or(InputResult::Blocked, InputResult::Handled))
    }
    /// Observe every successful application update, including other views.
    pub fn observe(
        &mut self,
        app: &Application,
        update: &Update,
        time: Duration,
    ) -> Result<Response, EditError> {
        let Some(layer) = &mut self.active else {
            return Ok(Response::default());
        };
        let transition = layer.observe(app, update, time)?;
        Ok(self.transition(transition).unwrap_or_default())
    }
    pub fn application_failed(&mut self, operation: Operation, error: String) -> Response {
        match &mut self.active {
            Some(Layer::Exit(session)) => session.operation_failed(operation, error),
            _ => Response::default(),
        }
    }
    pub fn start_picker(
        &mut self,
        session: PickerSession,
        app: &Application,
        time: Duration,
    ) -> Result<Response, EditError> {
        self.enter(Layer::Picker(session), app, time)
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
    pub fn picker_finished(&mut self, completion: PickerCompletion) -> Response {
        match &mut self.active {
            Some(Layer::Picker(session)) => Response {
                redraw: session.accept(completion),
                ..Response::default()
            },
            _ => Response::default(),
        }
    }
    pub fn resize_help(&mut self, rows: usize) {
        self.help_rows = rows;
        if let Some(layer) = &mut self.active {
            layer.resize(self.help_rows, self.picker_rows);
        }
    }
    pub fn resize_picker(&mut self, rows: usize) -> bool {
        self.picker_rows = rows;
        match &mut self.active {
            Some(Layer::Picker(session)) => session.resize(rows),
            _ => false,
        }
    }
}
