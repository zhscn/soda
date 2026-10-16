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
    pub alt: bool,
    pub shift: bool,
    pub unsupported_modifiers: bool,
    pub release: bool,
}
impl KeyStroke {
    pub fn plain(code: Key) -> Self {
        Self {
            code,
            control: false,
            alt: false,
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
    FocusLost,
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
        if matches!(input, UserInput::FocusLost) {
            if !self.sequence.active() {
                return Ok(InputResult::Blocked);
            }
            self.sequence.clear();
            return Ok(InputResult::Handled(super::Response {
                redraw: true,
                message: Message::Clear,
                ..super::Response::default()
            }));
        }
        if matches!(&input, UserInput::Key(key) if key.release) {
            return Ok(InputResult::Blocked);
        }
        if self.active().is_some() {
            let input = match input {
                UserInput::Key(key) => bindings::modal_key(key),
                UserInput::Paste(text) => Input::Paste(text),
                UserInput::Unrecognized | UserInput::FocusLost => Input::Unrecognized,
            };
            return self.handle(input, app, time);
        }
        if let UserInput::Key(key) = &input {
            let cancel = !key.alt
                && !key.shift
                && !key.unsupported_modifiers
                && ((key.code == Key::Esc && !key.control)
                    || (key.code == Key::Char('g') && key.control));
            if cancel && self.sequence.active() {
                self.sequence.clear();
                return Ok(InputResult::Handled(super::Response {
                    redraw: true,
                    message: Message::Clear,
                    ..super::Response::default()
                }));
            }
            if self.sequence.active()
                || super::sequence::Sequence::starts(*key, self.mode == super::EditMode::Normal)
            {
                return match self.sequence.push(*key) {
                    super::sequence::Resolution::Complete(command) => {
                        self.execute(command, app, time, file_root)
                    }
                    super::sequence::Resolution::Prefix => {
                        Ok(InputResult::Handled(super::Response {
                            redraw: true,
                            message: Message::Clear,
                            ..super::Response::default()
                        }))
                    }
                    super::sequence::Resolution::Invalid => {
                        Ok(InputResult::Handled(super::Response {
                            redraw: true,
                            message: Message::Set("Undefined key sequence".into()),
                            ..super::Response::default()
                        }))
                    }
                };
            }
        } else if self.sequence.active() {
            self.sequence.clear();
            return Ok(InputResult::Handled(super::Response {
                redraw: true,
                message: Message::Clear,
                ..super::Response::default()
            }));
        }
        let paste = matches!(input, UserInput::Paste(_));
        let command = match input {
            UserInput::Key(key) => bindings::binding(key, self.mode),
            UserInput::Paste(text) if self.mode == super::EditMode::Insert => {
                Some(Command::Edit(EditCommand::InsertText(text)))
            }
            _ => None,
        };
        match command {
            Some(command) => {
                let mut result = self.execute(command, app, time, file_root)?;
                if paste && let InputResult::Handled(response) = &mut result {
                    response.message = Message::Keep;
                }
                Ok(result)
            }
            None => Ok(InputResult::Blocked),
        }
    }
}
