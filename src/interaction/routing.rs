//! Frontend-independent key vocabulary and focus routing.
use super::{Command, Input, InputResult, Layers, Message, bindings};
use crate::{application::Application, core::EditError, editor::Command as EditCommand};
use std::{path::Path, time::Duration};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Key {
    Char(char),
    Enter,
    Esc,
    Backspace,
    Delete,
    Tab,
    BackTab,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    F(u8),
    Unrecognized,
}

/// Press and repeat events share bindings. Release events are ignored.
/// Platform modifiers outside the supported vocabulary block key resolution.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeyStroke {
    pub code: Key,
    pub control: bool,
    pub shift: bool,
    pub unsupported_modifiers: bool,
    pub release: bool,
}
impl KeyStroke {
    pub fn plain(code: Key) -> Self {
        Self {
            code,
            control: false,
            shift: false,
            unsupported_modifiers: false,
            release: false,
        }
    }
}

pub enum UserInput {
    Key(KeyStroke),
    Paste(String),
    Unrecognized,
}

impl Layers {
    /// Route to the active modal layer before resolving document bindings.
    /// A consumed event is never replayed after a layer closes. Execute the
    /// response and observe every resulting update before routing more input.
    pub fn route_input(
        &mut self,
        input: UserInput,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<InputResult, EditError> {
        if self.active().is_some() {
            let input = match input {
                UserInput::Key(key) => bindings::modal_key(key),
                UserInput::Paste(text) => Input::Paste(text),
                UserInput::Unrecognized => Input::Unrecognized,
            };
            return self.handle(input, app, time);
        }
        let paste = matches!(input, UserInput::Paste(_));
        let command = match input {
            UserInput::Key(key) => bindings::binding(key),
            UserInput::Paste(text) => Some(Command::Edit(EditCommand::InsertText(text))),
            UserInput::Unrecognized => None,
        };
        match command {
            Some(command) => {
                let mut result = self.execute(command, app, time, file_root)?;
                if paste && let InputResult::Handled(response) = &mut result {
                    response.message = Message::Keep;
                }
                Ok(result)
            }
            None => Ok(InputResult::Pass),
        }
    }
}
