//! Frontend-independent key vocabulary and focus routing.
use super::{
    Command, EditMode, Input, InputResult, Layers, Message,
    keymap::{self, Resolution},
    modal::{Action, BeaconEdit},
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

/// Keys Emacs names in capitals.
const SPECIAL_KEYS: &[(&str, Key)] = &[
    ("RET", Key::Enter),
    ("SPC", Key::Char(' ')),
    ("TAB", Key::Tab),
    ("ESC", Key::Esc),
    ("DEL", Key::Backspace),
];
/// Function keys, written in angle brackets: `<left>`, `<f1>`.
const FUNCTION_KEYS: &[(&str, Key)] = &[
    ("return", Key::Enter),
    ("tab", Key::Tab),
    ("backtab", Key::BackTab),
    ("escape", Key::Esc),
    ("backspace", Key::Backspace),
    ("delete", Key::Delete),
    ("deletechar", Key::Delete),
    ("left", Key::Left),
    ("right", Key::Right),
    ("up", Key::Up),
    ("down", Key::Down),
    ("home", Key::Home),
    ("end", Key::End),
    ("prior", Key::PageUp),
    ("next", Key::PageDown),
];
impl KeyStroke {
    /// Parses keys as Emacs's `kbd` does: keys apart by spaces, each with
    /// `C-`, `M-` and `S-` before it, as in `C-x C-s`, `M-<`, `C-M-SPC`,
    /// `S-<left>`, `<f1>`, `RET`. A word with no modifier and no name is
    /// its characters, one key each: `abc` is three keys.
    pub fn parse_sequence(text: &str) -> Result<Vec<Self>, String> {
        let mut keys = Vec::new();
        for word in text.split_whitespace() {
            Self::parse_word(word, &mut keys)?;
        }
        if keys.is_empty() {
            return Err("empty key sequence".into());
        }
        Ok(keys)
    }
    fn parse_word(word: &str, keys: &mut Vec<Self>) -> Result<(), String> {
        let mut key = Self::plain(Key::Unrecognized);
        let mut name = word;
        let mut modified = false;
        // `C--` is Ctrl and `-`; a lone `C-` is two characters.
        while name.len() > 2 && name.as_bytes()[0].is_ascii() && name.as_bytes()[1] == b'-' {
            match &name[..1] {
                "C" => key.control = true,
                "M" => key.alt = true,
                "S" => key.shift = true,
                "s" | "H" | "A" => {
                    return Err(format!("{word}: only C-, M- and S- are modifiers"));
                }
                _ => break,
            }
            modified = true;
            name = &name[2..];
        }
        let function = name
            .strip_prefix('<')
            .and_then(|name| name.strip_suffix('>'))
            .filter(|name| !name.is_empty());
        key.code = if let Some(function) = function {
            if let Some((_, code)) = FUNCTION_KEYS.iter().find(|(n, _)| *n == function) {
                *code
            } else if let Some(number) = function.strip_prefix('f').and_then(|n| n.parse().ok())
                && (1..=12).contains(&number)
            {
                Key::F(number)
            } else {
                return Err(format!("unknown key {name}"));
            }
        } else if let Some((_, code)) = SPECIAL_KEYS.iter().find(|(n, _)| *n == name) {
            *code
        } else {
            let mut chars = name.chars();
            match (chars.next(), chars.next()) {
                (Some(ch), None) => Key::Char(ch),
                // A word of characters, as `kbd` reads `abc`.
                _ if !modified => {
                    keys.extend(name.chars().map(|ch| Self::plain(Key::Char(ch))));
                    return Ok(());
                }
                _ => return Err(format!("{word}: a modifier takes one key")),
            }
        };
        keys.push(key);
        Ok(())
    }
}
impl std::fmt::Display for KeyStroke {
    /// The key as Emacs writes it, which `parse_sequence` reads.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.emacs())
    }
}
impl KeyStroke {
    /// The key as Emacs describes it: `C-x`, `M-f`, `C-M-S-<left>`, `SPC`,
    /// `RET`.
    pub fn emacs(&self) -> String {
        let name = match self.code {
            Key::Char(' ') => "SPC".into(),
            Key::Char(ch) => ch.to_string(),
            Key::Enter => "RET".into(),
            Key::Esc => "ESC".into(),
            Key::Tab => "TAB".into(),
            Key::Backspace => "DEL".into(),
            Key::Delete => "<delete>".into(),
            Key::BackTab => "<backtab>".into(),
            Key::Left => "<left>".into(),
            Key::Right => "<right>".into(),
            Key::Up => "<up>".into(),
            Key::Down => "<down>".into(),
            Key::Home => "<home>".into(),
            Key::End => "<end>".into(),
            Key::PageUp => "<prior>".into(),
            Key::PageDown => "<next>".into(),
            Key::F(number) => format!("<f{number}>"),
            Key::Unrecognized => "?".into(),
        };
        let mut out = String::new();
        for (on, prefix) in [(self.control, "C-"), (self.alt, "M-"), (self.shift, "S-")] {
            if on {
                out.push_str(prefix);
            }
        }
        out + &name
    }
}
/// A key sequence as Emacs describes it, keys apart: `C-x C-s`.
pub fn emacs_notation(keys: &[KeyStroke]) -> String {
    keys.iter()
        .map(KeyStroke::emacs)
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Clone, Debug)]
pub enum UserInput {
    Key(KeyStroke),
    Paste(String),
    /// A snippet a candidate expanded, as a macro replays it.
    Snippet(String),
    Pointer(super::Pointer),
    Unrecognized,
    FocusLost,
    /// The terminal has focus again; files may have changed meanwhile.
    FocusGained,
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
        self.route_recorded(input, false, app, time, file_root)
    }
    /// Routes a key once more, as typed but not recorded again: the commit
    /// character after the candidate it accepted.
    pub fn route_again(
        &mut self,
        input: UserInput,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<InputResult, EditError> {
        self.route(input, app, time, file_root)
    }
    /// Routes input replayed by a macro; a macro being recorded
    /// keeps the keys that started the replay, not the replayed ones.
    pub fn route_replayed(
        &mut self,
        input: UserInput,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<InputResult, EditError> {
        self.route_recorded(input, true, app, time, file_root)
    }
    /// The key tables in force, first to be asked first: what the caret is
    /// on or in, the mode, the keymaps of the document, then what every
    /// mode shares.
    pub(super) fn stack(&self, app: &Application) -> Vec<keymap::Table> {
        use keymap::Context;
        let mut stack: Vec<keymap::Table> = vec![];
        if self.mode == EditMode::Insert {
            // Over the choices of a place, Tab goes on to the next.
            let choosing = self.completion.choosing();
            if choosing && self.snippet.active() {
                stack.push(Context::Snippet.into());
            }
            if self.completion.visible() {
                stack.push(Context::Completion.into());
            }
            if !choosing && self.snippet.active() {
                stack.push(Context::Snippet.into());
            }
        }
        // What the caret is on or in holds over the table that moves it:
        // Normal's, or Insert's when editing is not modal, as Emacs's
        // overlay and special buffer keymaps hold over typing.
        let moving = match self.mode {
            EditMode::Normal => !self.modal.active(),
            EditMode::Insert => !super::modal_on(app) && !self.completion.visible(),
            EditMode::Beacon => false,
        };
        let document = app
            .active_view()
            .and_then(|view| app.view(view))
            .map(|view| view.document_id);
        if moving && app.options().bool(document, "mark-keys") && app.on_mark() {
            stack.push(Context::Mark.into());
        } else if moving && document.is_some_and(|document| app.is_tree(document)) {
            stack.push(Context::Tree.into());
        } else if moving
            && document
                .and_then(|document| app.workspace().file(document))
                .and_then(|file| file.scratch())
                .and_then(super::grep::results_kind)
                .is_some()
        {
            stack.push(Context::Results.into());
        }
        if self.mode == EditMode::Beacon {
            stack.push(Context::Beacon.into());
        }
        stack.push(
            match self.mode {
                EditMode::Insert => Context::Insert,
                EditMode::Normal | EditMode::Beacon => Context::Normal,
            }
            .into(),
        );
        if let Some(document) = app
            .active_view()
            .and_then(|view| app.view(view))
            .map(|view| view.document_id)
        {
            let editor = app.workspace().editor(document).unwrap();
            let language = editor.model().document().language();
            let servers = self.servers.get(&document).map_or(&[][..], Vec::as_slice);
            stack.extend(self.keymap.in_force(&language.profile().id, servers));
        }
        stack.push(Context::Global.into());
        stack
    }
    fn route_recorded(
        &mut self,
        input: UserInput,
        replayed: bool,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<InputResult, EditError> {
        let typed = match &input {
            UserInput::Key(key) => !key.release,
            UserInput::Paste(_) => true,
            UserInput::Pointer(_)
            | UserInput::Snippet(_)
            | UserInput::Unrecognized
            | UserInput::FocusLost
            | UserInput::FocusGained => false,
        };
        if typed && !replayed {
            let fresh = !self.sequence.active();
            self.modal.replay.typed(&input, fresh);
        }
        self.replaying = replayed;
        self.route(input, app, time, file_root)
    }
    fn route(
        &mut self,
        input: UserInput,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<InputResult, EditError> {
        if let UserInput::Pointer(pointer) = input {
            return Ok(self.pointer(pointer, app, time));
        }
        if matches!(input, UserInput::FocusGained) {
            if self.active().is_some() {
                return Ok(InputResult::Blocked);
            }
            return self.execute(super::Command::CheckFiles, app, time, file_root);
        }
        if matches!(input, UserInput::FocusLost) {
            if !self.sequence.active() && !self.modal.active() {
                return Ok(InputResult::Blocked);
            }
            self.sequence.clear();
            self.modal.clear();
            return Ok(pending(Message::Clear));
        }
        if matches!(&input, UserInput::Key(key) if key.release) {
            return Ok(InputResult::Blocked);
        }
        if let (Some(super::Layer::Resize(session)), UserInput::Key(key)) =
            (&mut self.active, &input)
        {
            // Ctrl changes the step, so the mode reads keys before the
            // prompt keys turn them into editing.
            let transition = session.key(*key);
            return Ok(self
                .transition(transition)
                .map_or(InputResult::Blocked, InputResult::Handled));
        }
        if self.active().is_some() {
            let input = match input {
                UserInput::Key(key) => self.keymap.input(key),
                UserInput::Paste(text) => Input::Paste(text),
                UserInput::Snippet(_)
                | UserInput::Unrecognized
                | UserInput::FocusLost
                | UserInput::FocusGained
                | UserInput::Pointer(_) => Input::Unrecognized,
            };
            return self.handle(input, app, time);
        }
        let key = match input {
            UserInput::Key(key) => key,
            UserInput::Paste(_) | UserInput::Snippet(_) | UserInput::Unrecognized
                if self.sequence.active() || self.modal.active() =>
            {
                self.sequence.clear();
                self.modal.clear();
                return Ok(pending(Message::Keep));
            }
            UserInput::Snippet(body) if self.mode == EditMode::Insert => {
                return self.execute(Command::Snippet(body), app, time, file_root);
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
        // A command waits for one more key.
        if let Some(read) = self.modal.read.take() {
            let ch = match key.code {
                Key::Char(ch) if !key.alt && !key.control => ch,
                Key::Enter => '\n',
                _ => {
                    self.modal.clear();
                    return Ok(pending(Message::Clear));
                }
            };
            return Ok(InputResult::Handled(self.modal_read(read, ch, app, time)));
        }
        // A count goes on with digits, as the transient map of `digit-argument`.
        if self.modal.count.is_some()
            && !self.sequence.active()
            && !key.alt
            && !key.control
            && let Key::Char(ch) = key.code
            && let Some(digit) = ch.to_digit(10)
        {
            return self.execute(
                Command::Modal(Action::Digit(digit as usize)),
                app,
                time,
                file_root,
            );
        }
        // Typing with beacons is the same edit at every caret; bindings that
        // know one caret, as auto-pairs do, stay out of it.
        if self.mode == EditMode::Insert
            && self.modal.beacon_insert
            && !self.sequence.active()
            && !key.alt
            && !key.control
        {
            let edit = match key.code {
                Key::Char(ch) => Some(BeaconEdit::Text(ch.to_string())),
                Key::Enter => Some(BeaconEdit::Text("\n".into())),
                Key::Backspace => Some(BeaconEdit::Backward),
                Key::Delete => Some(BeaconEdit::Forward),
                _ => None,
            };
            if let Some(edit) = edit {
                return Ok(InputResult::Handled(self.beacon_type(edit, app, time)));
            }
        }
        // A commit character takes the chosen candidate, then goes in as
        // typed, unless the list itself binds it.
        if self.mode == EditMode::Insert
            && !self.sequence.active()
            && !key.alt
            && !key.control
            && let Key::Char(ch) = key.code
            && self.completion.commits(ch)
            && matches!(
                self.keymap
                    .resolve(&[keymap::Context::Completion.into()], &[key], &|_| false)
                    .0,
                Resolution::Pass
            )
        {
            let result = self.execute(
                Command::Completion(super::completion::Action::Accept),
                app,
                time,
                file_root,
            );
            if matches!(result, Ok(InputResult::Handled(_))) {
                self.retype = Some(key);
            }
            return result;
        }
        let stack = self.stack(app);
        let cancel = keymap::is_cancel(&key) && !self.sequence.continues(key, &stack, &self.keymap);
        if cancel && (self.sequence.active() || self.modal.active()) {
            self.sequence.clear();
            self.modal.clear();
            return Ok(pending(Message::Clear));
        }
        // Enter is a line break until a candidate is chosen.
        let chosen = self.completion.selected();
        let skip = move |command: &Command| {
            !chosen
                && matches!(
                    command,
                    Command::Completion(super::completion::Action::Accept)
                )
        };
        // What the keys read as, for when they turn out to mean nothing.
        let typed = {
            let keys = super::emacs_notation(self.sequence.keys());
            let plain = matches!(key.code, Key::Char(_)) && !key.control && !key.alt;
            let hint = if plain {
                self.sequence.keypad_hint()
            } else {
                ""
            };
            let key = format!("{hint}{}", key.emacs());
            if keys.is_empty() {
                key
            } else {
                format!("{keys} {key}")
            }
        };
        let resolution = if self.sequence.in_keypad() {
            self.sequence.push_keypad(key, &stack, &self.keymap)
        } else {
            self.sequence.push(key, &stack, &self.keymap, &skip)
        };
        match resolution {
            Resolution::Complete(command) => {
                // `repeat` runs again what a key ran, not what that went on
                // to run, nor itself.
                let repeat = matches!(&command, Command::Named(line) if line.trim() == "repeat");
                // Keys a macro replays are not what was typed.
                if !repeat
                    && !self.replaying
                    && !matches!(
                        command,
                        Command::Keypad(_)
                            | Command::Modal(Action::Repeat | Action::Digit(_) | Action::Negative)
                    )
                {
                    self.modal.last = Some(command.clone());
                }
                // Choosing from a list is no use to a replay; moving
                // through a snippet is, as it replays as one.
                if self.sequence.source == Some(keymap::Context::Completion.into()) {
                    self.modal.replay.unrecord();
                }
                return self.execute(command, app, time, file_root);
            }
            Resolution::Prefix => return Ok(pending(Message::Clear)),
            Resolution::Invalid => {
                return Ok(pending(Message::Set(format!("{typed} is undefined"))));
            }
            Resolution::Pass => {}
        }
        if self.mode != EditMode::Insert {
            if cancel {
                self.modal.clear();
            }
            return Ok(InputResult::Blocked);
        }
        if cancel {
            return self.execute(Command::Modal(Action::Leave), app, time, file_root);
        }
        let plain = !key.alt && !key.control && !key.unsupported_modifiers;
        match key.code {
            Key::Char(ch) if plain => {
                self.completion.typed = !self.replaying;
                self.execute(
                    Command::Edit(EditCommand::TypeChar(ch)),
                    app,
                    time,
                    file_root,
                )
            }
            _ => Ok(InputResult::Blocked),
        }
    }
}
