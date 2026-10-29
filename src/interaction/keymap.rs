//! Context-scoped key tables. Defaults are command lines resolved through the
//! registry; user bindings shadow them and unbinding restores the default.
use super::{
    Command, EditMode, Input, InputKey, InputMotion, Key, KeyStroke, picker::ListMotion,
    registry::Registry, vim::VimCommand,
};
use crate::{
    application::ClipboardAction,
    editor::{Command as Edit, Direction, Motion},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub enum Context {
    Normal,
    Visual,
    Insert,
    Prompt,
}
impl Context {
    pub const ALL: [Self; 4] = [Self::Normal, Self::Visual, Self::Insert, Self::Prompt];
    pub fn name(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Visual => "visual",
            Self::Insert => "insert",
            Self::Prompt => "prompt",
        }
    }
    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|context| context.name() == name)
    }
}
impl From<EditMode> for Context {
    fn from(mode: EditMode) -> Self {
        match mode {
            EditMode::Normal => Self::Normal,
            EditMode::Visual | EditMode::VisualLine => Self::Visual,
            EditMode::Insert => Self::Insert,
        }
    }
}

/// Readline-style edits shared by Insert and every text field.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LineEdit {
    CharLeft,
    CharRight,
    WordLeft,
    WordRight,
    LineStart,
    LineEnd,
    DeleteBackward,
    DeleteForward,
    DeleteWordBackward,
    DeleteWordForward,
    KillLineStart,
    KillLineEnd,
    Yank,
}
pub(super) const LINE_EDITS: &[(&str, LineEdit, &str)] = &[
    ("char-left", LineEdit::CharLeft, "Move one character left"),
    (
        "char-right",
        LineEdit::CharRight,
        "Move one character right",
    ),
    ("word-left", LineEdit::WordLeft, "Move to the previous word"),
    ("word-right", LineEdit::WordRight, "Move to the next word"),
    ("line-start", LineEdit::LineStart, "Move to line start"),
    ("line-end", LineEdit::LineEnd, "Move to line end"),
    (
        "delete-backward",
        LineEdit::DeleteBackward,
        "Delete backward",
    ),
    ("delete-forward", LineEdit::DeleteForward, "Delete forward"),
    (
        "delete-word-backward",
        LineEdit::DeleteWordBackward,
        "Delete to the previous word boundary",
    ),
    (
        "delete-word-forward",
        LineEdit::DeleteWordForward,
        "Delete to the next word boundary",
    ),
    (
        "kill-line-start",
        LineEdit::KillLineStart,
        "Delete to line start",
    ),
    (
        "kill-line-end",
        LineEdit::KillLineEnd,
        "Cut to line end, or the line break at line end",
    ),
    ("yank", LineEdit::Yank, "Paste the last cut text"),
];
impl LineEdit {
    pub(super) fn is_motion(self) -> bool {
        matches!(
            self,
            Self::CharLeft
                | Self::CharRight
                | Self::WordLeft
                | Self::WordRight
                | Self::LineStart
                | Self::LineEnd
        )
    }
    /// Parses a line edit name, optionally prefixed by `extend-` for motions.
    pub(super) fn parse(name: &str) -> Option<(Self, bool)> {
        let (name, extend) = name
            .strip_prefix("extend-")
            .map_or((name, false), |name| (name, true));
        let (_, edit, _) = LINE_EDITS.iter().find(|(n, ..)| *n == name)?;
        (!extend || edit.is_motion()).then_some((*edit, extend))
    }
    pub(super) fn command(self, extend: bool) -> Command {
        let motion = |motion| Command::Edit(Edit::Move { motion, extend });
        match self {
            Self::CharLeft => motion(Motion::Backward),
            Self::CharRight => motion(Motion::Forward),
            Self::WordLeft => motion(Motion::WordBackward),
            Self::WordRight => motion(Motion::WordForward),
            Self::LineStart => motion(Motion::LineStart),
            Self::LineEnd => motion(Motion::LineEnd),
            Self::DeleteBackward => Command::Edit(Edit::Delete {
                direction: Direction::Backward,
                smart: true,
            }),
            Self::DeleteForward => Command::Edit(Edit::Delete {
                direction: Direction::Forward,
                smart: false,
            }),
            Self::DeleteWordBackward => Command::Vim(VimCommand::EraseWord),
            Self::DeleteWordForward => Command::Edit(Edit::DeleteWord(Direction::Forward)),
            Self::KillLineStart => Command::Vim(VimCommand::EraseLineStart),
            Self::KillLineEnd => Command::Clipboard(ClipboardAction::Kill {
                backward: false,
                word: false,
            }),
            Self::Yank => Command::Clipboard(ClipboardAction::Paste),
        }
    }
    pub(super) fn input(self, extend: bool) -> InputKey {
        let motion = |motion| InputKey::Move { motion, extend };
        match self {
            Self::CharLeft => motion(InputMotion::Left),
            Self::CharRight => motion(InputMotion::Right),
            Self::WordLeft => motion(InputMotion::WordLeft),
            Self::WordRight => motion(InputMotion::WordRight),
            Self::LineStart => motion(InputMotion::Start),
            Self::LineEnd => motion(InputMotion::End),
            Self::DeleteBackward => InputKey::Delete {
                backward: true,
                word: false,
            },
            Self::DeleteForward => InputKey::Delete {
                backward: false,
                word: false,
            },
            Self::DeleteWordBackward => InputKey::Kill(InputMotion::WordLeft),
            Self::DeleteWordForward => InputKey::Delete {
                backward: false,
                word: true,
            },
            Self::KillLineStart => InputKey::Kill(InputMotion::Start),
            Self::KillLineEnd => InputKey::Kill(InputMotion::End),
            Self::Yank => InputKey::Yank,
        }
    }
}

const fn candidate(motion: ListMotion) -> Input {
    Input::Candidate {
        motion,
        wrap: false,
    }
}
/// Field actions available to `map prompt`.
pub(super) const PROMPT_ACTIONS: &[(&str, Input, &str)] = &[
    ("confirm", Input::Confirm, "Accept the prompt"),
    ("cancel", Input::Cancel, "Close the prompt"),
    ("complete", Input::Complete { backward: false }, "Complete"),
    (
        "complete-backward",
        Input::Complete { backward: true },
        "Complete backward",
    ),
    (
        "candidate-next",
        candidate(ListMotion::Next),
        "Select the next candidate",
    ),
    (
        "candidate-previous",
        candidate(ListMotion::Previous),
        "Select the previous candidate",
    ),
    (
        "history-previous",
        Input::History { backward: true },
        "Recall the previous line from history",
    ),
    (
        "history-next",
        Input::History { backward: false },
        "Recall the next line from history",
    ),
    (
        "candidate-first",
        candidate(ListMotion::First),
        "Select the first candidate",
    ),
    (
        "candidate-last",
        candidate(ListMotion::Last),
        "Select the last candidate",
    ),
    (
        "page-next",
        candidate(ListMotion::PageNext),
        "Next candidate page",
    ),
    (
        "page-previous",
        candidate(ListMotion::PagePrevious),
        "Previous candidate page",
    ),
    (
        "match-next",
        Input::Navigate { backward: false },
        "Next search match",
    ),
    (
        "match-previous",
        Input::Navigate { backward: true },
        "Previous search match",
    ),
    ("replace-all", Input::ReplaceAll, "Replace every match"),
    ("help", Input::Help, "Help"),
    ("select-all", Input::Text(InputKey::SelectAll), "Select all"),
    ("nop", Input::Unrecognized, "Ignore the key"),
];
pub(super) fn prompt_action(name: &str) -> Option<Input> {
    if let Some((_, input, _)) = PROMPT_ACTIONS.iter().find(|(n, ..)| *n == name) {
        return Some(input.clone());
    }
    LineEdit::parse(name).map(|(edit, extend)| Input::Text(edit.input(extend)))
}

const READLINE: &[(&str, &str)] = &[
    ("<left>", "char-left"),
    ("<right>", "char-right"),
    ("<c-b>", "char-left"),
    ("<c-f>", "char-right"),
    ("<s-left>", "extend-char-left"),
    ("<s-right>", "extend-char-right"),
    ("<c-left>", "word-left"),
    ("<c-right>", "word-right"),
    ("<a-b>", "word-left"),
    ("<a-f>", "word-right"),
    ("<c-s-left>", "extend-word-left"),
    ("<c-s-right>", "extend-word-right"),
    ("<home>", "line-start"),
    ("<end>", "line-end"),
    ("<c-a>", "line-start"),
    ("<c-e>", "line-end"),
    ("<s-home>", "extend-line-start"),
    ("<s-end>", "extend-line-end"),
    ("<bs>", "delete-backward"),
    ("<c-h>", "delete-backward"),
    ("<del>", "delete-forward"),
    ("<c-d>", "delete-forward"),
    ("<c-w>", "delete-word-backward"),
    ("<c-bs>", "delete-word-backward"),
    ("<a-bs>", "delete-word-backward"),
    ("<c-del>", "delete-word-forward"),
    ("<a-d>", "delete-word-forward"),
    ("<c-u>", "kill-line-start"),
    ("<c-k>", "kill-line-end"),
    ("<c-y>", "yank"),
];
const NORMAL: &[(&str, &str)] = &[
    ("<c-r>", "redo"),
    ("<c-f>", "page-down"),
    ("<c-b>", "page-up"),
    ("<c-d>", "half-page-down"),
    ("<c-u>", "half-page-up"),
    ("<c-w>s", "split"),
    ("<c-w>v", "vsplit"),
    ("<c-w>c", "close-window"),
    ("<c-w>q", "close-window"),
    ("<c-w>o", "only"),
    ("<c-w>h", "window-left"),
    ("<c-w>j", "window-down"),
    ("<c-w>k", "window-up"),
    ("<c-w>l", "window-right"),
    ("<c-w><left>", "window-left"),
    ("<c-w><down>", "window-down"),
    ("<c-w><up>", "window-up"),
    ("<c-w><right>", "window-right"),
    ("<c-w>w", "window-next"),
    ("<c-w><c-w>", "window-next"),
    ("<c-w>W", "window-previous"),
    ("<ret>", "jump"),
    ("]q", "next-result"),
    ("[q", "previous-result"),
    ("<c-c>", "stop"),
    ("<f1>", "help"),
    ("<space>f", "project"),
    ("<space>b", "buffers"),
    ("<space>:", "commands"),
    ("<space>j", "jump-to"),
    ("<space>w", "window-pick"),
];
const VISUAL: &[(&str, &str)] = &[
    ("<c-f>", "page-down"),
    ("<c-b>", "page-up"),
    ("<c-d>", "half-page-down"),
    ("<c-u>", "half-page-up"),
    ("<f1>", "help"),
];
const INSERT: &[(&str, &str)] = &[
    ("<up>", "move-up"),
    ("<down>", "move-down"),
    ("<s-up>", "extend-move-up"),
    ("<s-down>", "extend-move-down"),
    ("<ret>", "newline"),
    ("<tab>", "insert-tab"),
    ("<backtab>", "outdent"),
    ("<s-backtab>", "outdent"),
    ("<f1>", "help"),
];
const PROMPT: &[(&str, &str)] = &[
    ("<esc>", "cancel"),
    ("<c-c>", "cancel"),
    ("<ret>", "confirm"),
    ("<c-ret>", "replace-all"),
    ("<f4>", "replace-all"),
    ("<tab>", "complete"),
    ("<backtab>", "complete-backward"),
    ("<s-backtab>", "complete-backward"),
    ("<s-tab>", "complete-backward"),
    ("<up>", "candidate-previous"),
    ("<down>", "candidate-next"),
    ("<c-p>", "candidate-previous"),
    ("<c-n>", "candidate-next"),
    ("<a-p>", "history-previous"),
    ("<a-n>", "history-next"),
    ("<c-up>", "candidate-first"),
    ("<c-down>", "candidate-last"),
    ("<pageup>", "page-previous"),
    ("<pagedown>", "page-next"),
    ("<f1>", "help"),
    ("<f3>", "match-next"),
    ("<s-f3>", "match-previous"),
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BindingError {
    Empty,
    TooLong,
    InvalidKey,
    PrefixConflict,
}
impl std::fmt::Display for BindingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Empty => "empty key sequence",
            Self::TooLong => "key sequences have at most four keys",
            Self::InvalidKey => "key cannot be bound",
            Self::PrefixConflict => "binding conflicts with a longer or shorter binding",
        })
    }
}
impl std::error::Error for BindingError {}
const MAX_KEYS: usize = 4;
pub(super) fn canonical(mut key: KeyStroke) -> Result<KeyStroke, BindingError> {
    if key.release || key.unsupported_modifiers || key.code == Key::Unrecognized {
        return Err(BindingError::InvalidKey);
    }
    // Printable characters already encode Shift in their character value.
    if let Key::Char(ch) = key.code
        && !key.control
        && !key.alt
        && (ch.is_uppercase() || !ch.is_alphabetic())
    {
        key.shift = false;
    }
    Ok(key)
}
pub(super) fn is_cancel(key: &KeyStroke) -> bool {
    !key.alt
        && !key.shift
        && !key.unsupported_modifiers
        && ((key.code == Key::Esc && !key.control)
            || (key.control && matches!(key.code, Key::Char('[' | 'c'))))
}

/// A binding target and the text shown for it in help.
#[derive(Clone, Debug)]
pub struct Binding<T> {
    pub keys: Vec<KeyStroke>,
    pub target: T,
    pub label: String,
}
struct Layer<T> {
    user: Vec<Binding<T>>,
    defaults: Vec<Binding<T>>,
}
impl<T> Default for Layer<T> {
    fn default() -> Self {
        Self {
            user: vec![],
            defaults: vec![],
        }
    }
}
pub(super) enum Resolution<T> {
    Pass,
    Prefix,
    Complete(T),
    Invalid,
}
impl<T: Clone> Layer<T> {
    fn bind(&mut self, keys: &[KeyStroke], target: T, label: String) -> Result<(), BindingError> {
        let keys = sequence(keys)?;
        if self
            .user
            .iter()
            .any(|b| b.keys != keys && (keys.starts_with(&b.keys) || b.keys.starts_with(&keys)))
        {
            return Err(BindingError::PrefixConflict);
        }
        let binding = Binding {
            keys,
            target,
            label,
        };
        match self.user.iter_mut().find(|b| b.keys == binding.keys) {
            Some(existing) => *existing = binding,
            None => self.user.push(binding),
        }
        Ok(())
    }
    fn unbind(&mut self, keys: &[KeyStroke]) -> Result<(), BindingError> {
        let keys = keys
            .iter()
            .copied()
            .map(canonical)
            .collect::<Result<Vec<_>, _>>()?;
        self.user.retain(|b| b.keys != keys);
        Ok(())
    }
    /// User bindings, including prefixes, take precedence over defaults.
    fn resolve(&self, keys: &[KeyStroke]) -> Resolution<T> {
        for bindings in [&self.user, &self.defaults] {
            if let Some(binding) = bindings.iter().find(|b| b.keys == keys) {
                return Resolution::Complete(binding.target.clone());
            }
            if bindings.iter().any(|b| b.keys.starts_with(keys)) {
                return Resolution::Prefix;
            }
        }
        Resolution::Pass
    }
}
impl<T> Layer<T> {
    /// Effective bindings: user entries, then defaults they do not shadow.
    fn effective(&self) -> impl Iterator<Item = &Binding<T>> {
        self.user.iter().chain(self.defaults.iter().filter(|d| {
            !self
                .user
                .iter()
                .any(|u| u.keys.starts_with(&d.keys) || d.keys.starts_with(&u.keys))
        }))
    }
}
fn sequence(keys: &[KeyStroke]) -> Result<Vec<KeyStroke>, BindingError> {
    if keys.is_empty() {
        return Err(BindingError::Empty);
    }
    if keys.len() > MAX_KEYS {
        return Err(BindingError::TooLong);
    }
    let keys = keys
        .iter()
        .copied()
        .map(canonical)
        .collect::<Result<Vec<_>, _>>()?;
    if keys.iter().skip(1).any(is_cancel) {
        return Err(BindingError::InvalidKey);
    }
    Ok(keys)
}

pub struct Keymap {
    edit: [Layer<Command>; 3],
    prompt: Layer<Input>,
}
impl Default for Keymap {
    fn default() -> Self {
        let registry = Registry::default();
        let mut keymap = Self {
            edit: Default::default(),
            prompt: Layer::default(),
        };
        let parse = |keys: &str| KeyStroke::parse_sequence(keys).unwrap();
        for (context, table) in [
            (Context::Normal, NORMAL),
            (Context::Visual, VISUAL),
            (Context::Insert, INSERT),
            (Context::Insert, READLINE),
        ] {
            for (keys, line) in table {
                let target = registry.parse_builtin(line).unwrap();
                keymap.edit[context as usize].defaults.push(Binding {
                    keys: sequence(&parse(keys)).unwrap(),
                    target,
                    label: (*line).into(),
                });
            }
        }
        for (keys, name) in PROMPT.iter().chain(READLINE) {
            keymap.prompt.defaults.push(Binding {
                keys: sequence(&parse(keys)).unwrap(),
                target: prompt_action(name).unwrap(),
                label: (*name).into(),
            });
        }
        keymap
    }
}
impl Keymap {
    pub fn bind(
        &mut self,
        context: Context,
        keys: &[KeyStroke],
        command: Command,
        label: String,
    ) -> Result<(), BindingError> {
        match context {
            Context::Prompt => Err(BindingError::InvalidKey),
            context => self.edit[context as usize].bind(keys, command, label),
        }
    }
    pub fn bind_input(
        &mut self,
        key: KeyStroke,
        input: Input,
        label: String,
    ) -> Result<(), BindingError> {
        self.prompt.bind(&[key], input, label)
    }
    pub fn unbind(&mut self, context: Context, keys: &[KeyStroke]) -> Result<(), BindingError> {
        match context {
            Context::Prompt => self.prompt.unbind(keys),
            context => self.edit[context as usize].unbind(keys),
        }
    }
    pub(super) fn resolve(&self, context: Context, keys: &[KeyStroke]) -> Resolution<Command> {
        self.edit[context as usize].resolve(keys)
    }
    /// Field keys are single strokes; printable characters insert text.
    pub(super) fn input(&self, key: KeyStroke) -> Input {
        let Ok(key) = canonical(key) else {
            return Input::Unrecognized;
        };
        match self.prompt.resolve(&[key]) {
            Resolution::Complete(input) => input,
            _ => match key.code {
                Key::Char(ch) if !key.control && !key.alt => Input::Text(InputKey::Char(ch)),
                _ => Input::Unrecognized,
            },
        }
    }
    /// Next keys after a pending prefix and the label of each binding;
    /// a key that continues a longer sequence reports its own keys.
    pub fn continuations(
        &self,
        context: Context,
        prefix: &[KeyStroke],
    ) -> Vec<(KeyStroke, String)> {
        let mut out: Vec<(KeyStroke, String)> = vec![];
        for (keys, label) in self.bindings(context) {
            if keys.len() <= prefix.len() || !keys.starts_with(prefix) {
                continue;
            }
            let next = keys[prefix.len()];
            if out.iter().any(|(key, _)| *key == next) {
                continue;
            }
            let label = if keys.len() == prefix.len() + 1 {
                label
            } else {
                format!("+{}", super::key_notation(&keys[..=prefix.len()]))
            };
            out.push((next, label));
        }
        out
    }
    /// Effective bindings of a context, for help and listings.
    pub fn bindings(&self, context: Context) -> Vec<(Vec<KeyStroke>, String)> {
        fn pairs<T>(layer: &Layer<T>) -> Vec<(Vec<KeyStroke>, String)> {
            layer
                .effective()
                .map(|b| (b.keys.clone(), b.label.clone()))
                .collect()
        }
        match context {
            Context::Prompt => pairs(&self.prompt),
            context => pairs(&self.edit[context as usize]),
        }
    }
}

/// Pending literal key sequence of an editing context.
#[derive(Default)]
pub(super) struct Sequence {
    keys: Vec<KeyStroke>,
}
impl Sequence {
    pub fn active(&self) -> bool {
        !self.keys.is_empty()
    }
    pub fn clear(&mut self) {
        self.keys.clear();
    }
    pub fn push(&mut self, key: KeyStroke, context: Context, map: &Keymap) -> Resolution<Command> {
        let active = self.active();
        let Ok(key) = canonical(key) else {
            self.clear();
            return if active {
                Resolution::Invalid
            } else {
                Resolution::Pass
            };
        };
        self.keys.push(key);
        match map.resolve(context, &self.keys) {
            Resolution::Prefix => Resolution::Prefix,
            Resolution::Complete(command) => {
                self.clear();
                Resolution::Complete(command)
            }
            _ => {
                self.clear();
                if active {
                    Resolution::Invalid
                } else {
                    Resolution::Pass
                }
            }
        }
    }
    pub fn hint(&self) -> String {
        format!("{} …  (Esc cancels)", super::key_notation(&self.keys))
    }
    pub fn keys(&self) -> &[KeyStroke] {
        &self.keys
    }
}
