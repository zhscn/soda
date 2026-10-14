//! File path and location prompts. Targets remain bound to their initiating
//! document or view; field editing is independent of command execution.
use super::{
    Input, Presentation, Response, TextInput,
    session::{Transition, edit_field, field_presentation},
};
use crate::{
    application::{Application, Event, ViewId},
    editor::{Command, DocumentId},
};
use std::time::Duration;
#[derive(Clone, Copy)]
pub(super) enum PathTarget {
    Open,
    Save(DocumentId),
}
pub(super) fn path_presentation(
    target: PathTarget,
    field: &super::path::PathInput,
) -> Presentation {
    field.presentation(match target {
        PathTarget::Open => "Open",
        PathTarget::Save(_) => "Save as",
    })
}
pub(super) fn path_observe(target: PathTarget, app: &Application) -> Transition {
    match target {
        PathTarget::Save(document) if app.workspace().editor(document).is_none() => {
            Transition::close()
        }
        _ => Transition::active(Response::default()),
    }
}
pub(super) fn path_input(
    target: PathTarget,
    field: &mut super::path::PathInput,
    input: Input,
) -> Transition {
    match field.handle(input) {
        super::path::PathAction::Active(response) => Transition::active(response),
        super::path::PathAction::Blocked => Transition::Blocked,
        super::path::PathAction::Cancel => Transition::close(),
        super::path::PathAction::Submit(path) => Transition::finished(Response {
            events: vec![match target {
                PathTarget::Open => Event::Open(path),
                PathTarget::Save(document) => Event::Save {
                    document,
                    target: Some(path),
                },
            }],
            redraw: true,
            ..Response::default()
        }),
    }
}
pub struct GotoSession {
    view: ViewId,
    input: TextInput,
    error: bool,
}
impl GotoSession {
    pub fn new(view: ViewId) -> Self {
        Self {
            view,
            input: TextInput::default(),
            error: false,
        }
    }
    pub fn view(&self) -> ViewId {
        self.view
    }
    pub fn input(&self) -> &TextInput {
        &self.input
    }
    pub(super) fn handle(&mut self, input: Input, app: &Application, time: Duration) -> Transition {
        match input {
            Input::Cancel => Transition::close(),
            Input::Confirm => {
                let Some((line, column)) = location(self.input.text()) else {
                    self.error = true;
                    return Transition::redraw();
                };
                let mut response = Response {
                    redraw: true,
                    ..Response::default()
                };
                if app.view(self.view).is_some() {
                    response.events.push(Event::Edit {
                        view: self.view,
                        command: Command::Goto { line, column },
                        time,
                    });
                }
                Transition::finished(response)
            }
            input => match edit_field(&mut self.input, input) {
                Some(update) if update.text_changed || update.selection_changed => {
                    if update.text_changed {
                        self.error = false;
                    }
                    Transition::redraw()
                }
                _ => Transition::Blocked,
            },
        }
    }
    pub(super) fn observe(&self, app: &Application) -> Transition {
        if app.view(self.view).is_none() || app.active_view() != Some(self.view) {
            Transition::close()
        } else {
            Transition::active(Response::default())
        }
    }
    pub(super) fn presentation(&self) -> Presentation {
        field_presentation(
            if self.error {
                "Go to line[:column] (positive numbers required): "
            } else {
                "Go to line[:column]: "
            }
            .to_owned(),
            &self.input,
        )
    }
}
fn location(text: &str) -> Option<(usize, usize)> {
    let (line, column) = text.trim().split_once(':').unwrap_or((text.trim(), "1"));
    Some((
        line.parse::<usize>().ok()?.checked_sub(1)?,
        column.parse::<usize>().ok()?.checked_sub(1)?,
    ))
}
