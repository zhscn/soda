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
            if !self.sequence.active() && !self.vim.active() {
                return Ok(InputResult::Blocked);
            }
            self.sequence.clear();
            self.vim.clear();
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
                UserInput::Key(key) => self
                    .keymap
                    .input(key)
                    .unwrap_or_else(|| bindings::modal_key(key)),
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
                    || (key.control && matches!(key.code, Key::Char('[' | 'c'))));
            if cancel && (self.sequence.active() || self.vim.active()) {
                let exit_visual = self.vim.active()
                    && matches!(
                        self.mode,
                        super::EditMode::Visual | super::EditMode::VisualLine
                    );
                self.sequence.clear();
                self.vim.clear();
                if exit_visual {
                    return self.execute(
                        Command::Vim(super::vim::VimCommand::Insert(super::vim::Insert::Leave)),
                        app,
                        time,
                        file_root,
                    );
                }
                return Ok(InputResult::Handled(super::Response {
                    redraw: true,
                    message: Message::Clear,
                    ..super::Response::default()
                }));
            }
            let mapped = if !self.vim.active() || self.sequence.active() {
                self.sequence.push(*key, self.mode, &self.keymap)
            } else {
                super::sequence::Resolution::Pass
            };
            match mapped {
                super::sequence::Resolution::Complete(command) => {
                    self.vim.clear();
                    return self.execute(command, app, time, file_root);
                }
                super::sequence::Resolution::Prefix => {
                    return Ok(InputResult::Handled(super::Response {
                        redraw: true,
                        message: Message::Clear,
                        ..super::Response::default()
                    }));
                }
                super::sequence::Resolution::Invalid => {
                    return Ok(InputResult::Handled(super::Response {
                        redraw: true,
                        message: Message::Set("Undefined key sequence".into()),
                        ..super::Response::default()
                    }));
                }
                super::sequence::Resolution::Pass => {}
            }
            let vim_key = match key.code {
                Key::Char(ch) => Some(ch),
                Key::Left => Some(if key.shift { 'b' } else { 'h' }),
                Key::Right => Some(if key.shift { 'w' } else { 'l' }),
                Key::Up if !key.shift => Some('k'),
                Key::Down if !key.shift => Some('j'),
                Key::Home => Some('0'),
                Key::End => Some('$'),
                _ => None,
            };
            if self.mode != super::EditMode::Insert
                && !key.alt
                && !key.control
                && !key.unsupported_modifiers
                && let Some(ch) = vim_key
            {
                return match self.vim.key(
                    ch,
                    matches!(
                        self.mode,
                        super::EditMode::Visual | super::EditMode::VisualLine
                    ),
                ) {
                    Ok(Some(command)) => self.execute(command, app, time, file_root),
                    Ok(None) => Ok(InputResult::Handled(super::Response {
                        redraw: true,
                        message: Message::Clear,
                        ..super::Response::default()
                    })),
                    Err(error) => Ok(InputResult::Handled(super::Response {
                        redraw: true,
                        message: Message::Set(format!("{error}: {ch}")),
                        ..super::Response::default()
                    })),
                };
            }
            if self.vim.active() && !cancel {
                self.vim.clear();
                return Ok(InputResult::Blocked);
            }
        } else if self.sequence.active() || self.vim.active() {
            self.sequence.clear();
            self.vim.clear();
            return Ok(InputResult::Handled(super::Response {
                redraw: true,
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
