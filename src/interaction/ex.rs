//! The `:` command line. Text is resolved through the command registry after
//! the prompt closes, so errors appear in the status line.
use super::{
    Command, Input, Presentation, Response, TextInput,
    session::{Transition, edit_field, field_presentation},
};
#[derive(Default)]
pub struct ExSession {
    input: TextInput,
}
impl ExSession {
    pub fn new(text: &str) -> Self {
        Self {
            input: TextInput::new(text),
        }
    }
    pub(super) fn handle(&mut self, input: Input) -> Transition {
        match input {
            Input::Cancel => Transition::close(),
            Input::Confirm => {
                let text = self.input.text().trim();
                if text.is_empty() {
                    return Transition::close();
                }
                Transition::finished(Response {
                    commands: vec![Command::Named(text.into())],
                    redraw: true,
                    ..Response::default()
                })
            }
            input => match edit_field(&mut self.input, input) {
                Some(update) if update.text_changed || update.selection_changed => {
                    Transition::redraw()
                }
                _ => Transition::Blocked,
            },
        }
    }
    pub(super) fn presentation(&self) -> Presentation {
        field_presentation(":".into(), &self.input)
    }
}
