//! Frontend-independent key vocabulary and focus routing.
use super::{
    Command, EditMode, Input, InputResult, Layers, Message,
    keymap::{self, Resolution},
    vim::{Insert, VimCommand},
};
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

const NAMED_KEYS: &[(&str, Key)] = &[
    ("esc", Key::Esc),
    ("ret", Key::Enter),
    ("cr", Key::Enter),
    ("enter", Key::Enter),
    ("tab", Key::Tab),
    ("backtab", Key::BackTab),
    ("bs", Key::Backspace),
    ("backspace", Key::Backspace),
    ("del", Key::Delete),
    ("space", Key::Char(' ')),
    ("lt", Key::Char('<')),
    ("left", Key::Left),
    ("right", Key::Right),
    ("up", Key::Up),
    ("down", Key::Down),
    ("home", Key::Home),
    ("end", Key::End),
    ("pageup", Key::PageUp),
    ("pagedown", Key::PageDown),
];
impl KeyStroke {
    /// Parses key notation such as `x`, `<c-x>`, `<a-f>`, `<s-tab>` or
    /// `<space>f`; modifier and key names are case-insensitive.
    pub fn parse_sequence(text: &str) -> Result<Vec<Self>, String> {
        let mut keys = Vec::new();
        let mut rest = text;
        while let Some(ch) = rest.chars().next() {
            if ch == '<'
                && let Some(end) = rest.find('>').filter(|&end| end > 1)
            {
                keys.push(Self::parse_named(&rest[1..end])?);
                rest = &rest[end + 1..];
            } else {
                keys.push(Self::plain(Key::Char(ch)));
                rest = &rest[ch.len_utf8()..];
            }
        }
        if keys.is_empty() {
            return Err("empty key sequence".into());
        }
        Ok(keys)
    }
    fn parse_named(spec: &str) -> Result<Self, String> {
        let mut key = Self::plain(Key::Unrecognized);
        let mut name = spec;
        while let Some((modifier, tail)) = name.split_once('-').filter(|(_, tail)| !tail.is_empty())
        {
            match modifier.to_ascii_lowercase().as_str() {
                "c" => key.control = true,
                "a" | "m" => key.alt = true,
                "s" => key.shift = true,
                _ => return Err(format!("unknown modifier in <{spec}>")),
            }
            name = tail;
        }
        let lower = name.to_ascii_lowercase();
        key.code = if let Some((_, code)) = NAMED_KEYS.iter().find(|(n, _)| *n == lower) {
            *code
        } else if let Some(number) = lower.strip_prefix('f').and_then(|n| n.parse().ok())
            && (1..=12).contains(&number)
        {
            Key::F(number)
        } else {
            let mut chars = name.chars();
            match (chars.next(), chars.next()) {
                (Some(ch), None) => Key::Char(ch),
                _ => return Err(format!("unknown key <{spec}>")),
            }
        };
        Ok(key)
    }
}
impl std::fmt::Display for KeyStroke {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self.code {
            Key::Char(' ') => "space".into(),
            Key::Char('<') => "lt".into(),
            Key::Char(ch) => ch.to_string(),
            Key::F(number) => format!("f{number}"),
            Key::Unrecognized => "?".into(),
            code => NAMED_KEYS
                .iter()
                .find(|(_, named)| *named == code)
                .unwrap()
                .0
                .into(),
        };
        let modifiers = [(self.control, "c-"), (self.alt, "a-"), (self.shift, "s-")];
        if name.chars().count() == 1 && modifiers.iter().all(|(on, _)| !on) {
            return f.write_str(&name);
        }
        f.write_str("<")?;
        for (on, prefix) in modifiers {
            if on {
                f.write_str(prefix)?;
            }
        }
        write!(f, "{name}>")
    }
}
/// Formats a key sequence in the notation accepted by `parse_sequence`.
pub fn key_notation(keys: &[KeyStroke]) -> String {
    keys.iter().map(ToString::to_string).collect()
}

pub enum UserInput {
    Key(KeyStroke),
    Paste(String),
    Pointer(super::Pointer),
    Unrecognized,
    FocusLost,
}

fn pending(message: Message) -> InputResult {
    InputResult::Handled(super::Response {
        redraw: true,
        message,
        ..super::Response::default()
    })
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
        if let UserInput::Pointer(pointer) = input {
            return Ok(self.pointer(pointer, app, time));
        }
        if matches!(input, UserInput::FocusLost) {
            if !self.sequence.active() && !self.vim.active() {
                return Ok(InputResult::Blocked);
            }
            self.sequence.clear();
            self.vim.clear();
            return Ok(pending(Message::Clear));
        }
        if matches!(&input, UserInput::Key(key) if key.release) {
            return Ok(InputResult::Blocked);
        }
        if self.active().is_some() {
            let input = match input {
                UserInput::Key(key) => self.keymap.input(key),
                UserInput::Paste(text) => Input::Paste(text),
                UserInput::Unrecognized | UserInput::FocusLost | UserInput::Pointer(_) => {
                    Input::Unrecognized
                }
            };
            return self.handle(input, app, time);
        }
        let key = match input {
            UserInput::Key(key) => key,
            UserInput::Paste(_) | UserInput::Unrecognized
                if self.sequence.active() || self.vim.active() =>
            {
                self.sequence.clear();
                self.vim.clear();
                return Ok(pending(Message::Keep));
            }
            UserInput::Paste(text) if self.mode == EditMode::Insert => {
                let mut result = self.execute(
                    Command::Edit(EditCommand::InsertText(text)),
                    app,
                    time,
                    file_root,
                )?;
                if let InputResult::Handled(response) = &mut result {
                    response.message = Message::Keep;
                }
                return Ok(result);
            }
            _ => return Ok(InputResult::Blocked),
        };
        let cancel = keymap::is_cancel(&key);
        if cancel && (self.sequence.active() || self.vim.active()) {
            let exit_visual =
                self.vim.active() && matches!(self.mode, EditMode::Visual | EditMode::VisualLine);
            self.sequence.clear();
            self.vim.clear();
            if !exit_visual {
                return Ok(pending(Message::Clear));
            }
        } else if !self.vim.active() || self.sequence.active() {
            match self.sequence.push(key, self.mode.into(), &self.keymap) {
                Resolution::Complete(command) => {
                    self.vim.clear();
                    return self.execute(command, app, time, file_root);
                }
                Resolution::Prefix => return Ok(pending(Message::Clear)),
                Resolution::Invalid => {
                    return Ok(pending(Message::Set("Undefined key sequence".into())));
                }
                Resolution::Pass => {}
            }
        }
        if cancel {
            return self.execute(
                Command::Vim(VimCommand::Insert(Insert::Leave)),
                app,
                time,
                file_root,
            );
        }
        let plain = !key.alt && !key.control && !key.unsupported_modifiers;
        if self.mode == EditMode::Insert {
            return match key.code {
                Key::Char(ch) if plain => self.execute(
                    Command::Edit(EditCommand::TypeChar(ch)),
                    app,
                    time,
                    file_root,
                ),
                _ => Ok(InputResult::Blocked),
            };
        }
        // Normal and Visual keys without a binding feed the Vim grammar;
        // arrows take part in counts and operator motions.
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
        if let Some(ch) = vim_key.filter(|_| plain) {
            let visual = matches!(self.mode, EditMode::Visual | EditMode::VisualLine);
            return match self.vim.key(ch, visual) {
                Ok(Some(command)) => self.execute(command, app, time, file_root),
                Ok(None) => Ok(pending(Message::Clear)),
                Err(error) => Ok(pending(Message::Set(format!("{error}: {ch}")))),
            };
        }
        if self.vim.active() {
            self.vim.clear();
        }
        Ok(InputResult::Blocked)
    }
}
