//! Context-scoped key tables. Defaults are command lines resolved through the
//! registry; user bindings shadow them and unbinding restores the default.
use super::{
    Command, EditMode, Input, InputKey, InputMotion, Key, KeyStroke, picker::ListMotion,
    registry::{Choice, Registry, word},
};
use crate::{
    application::ClipboardAction,
    editor::{Command as Edit, Direction, Motion},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub enum Context {
    /// Under every editing mode: the home of `C-x`, `C-c` and the keypad.
    Global,
    Normal,
    /// Beacon; other keys go to Normal.
    Beacon,
    Insert,
    /// Insert while the completion list shows; other keys go to Insert.
    Completion,
    /// Insert while a snippet has places left; below `Completion`.
    Snippet,
    /// Normal with the caret on a marked symbol; other keys go to Normal.
    Mark,
    /// Normal in a document that shows a tree; other keys go to Normal.
    Tree,
    Prompt,
}
impl Context {
    pub const ALL: [Self; 9] = [
        Self::Global,
        Self::Normal,
        Self::Beacon,
        Self::Insert,
        Self::Completion,
        Self::Snippet,
        Self::Mark,
        Self::Tree,
        Self::Prompt,
    ];
    /// Each context's name and what its keys are for, in the order of
    /// `ALL`; `map` offers them.
    pub(super) const CHOICES: [Choice; 9] = [
        word("global", "Keys of every mode, and of the keypad"),
        word("normal", "Normal mode keys"),
        word("beacon", "Beacon keys, over Normal's"),
        word("insert", "Insert mode keys"),
        word("completion", "Keys while the completion list shows"),
        word("snippet", "Keys while a snippet has places left"),
        word("mark", "Keys with the caret on a marked symbol"),
        word("tree", "Keys in a document that shows a tree"),
        word("prompt", "Command line and prompt keys"),
    ];
    pub fn name(self) -> &'static str {
        Self::CHOICES[self as usize].word
    }
    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|context| context.name() == name)
    }
}
#[test]
fn every_context_has_its_choice_in_order() {
    for (index, context) in Context::ALL.into_iter().enumerate() {
        assert_eq!(context as usize, index);
    }
}
impl From<EditMode> for Context {
    fn from(mode: EditMode) -> Self {
        match mode {
            EditMode::Normal => Self::Normal,
            EditMode::Beacon => Self::Beacon,
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
    KillWordBackward,
    KillWordForward,
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
        "kill-word-backward",
        LineEdit::KillWordBackward,
        "Cut to the previous word boundary",
    ),
    (
        "kill-word-forward",
        LineEdit::KillWordForward,
        "Cut to the next word boundary",
    ),
    (
        "kill-line-start",
        LineEdit::KillLineStart,
        "Cut to line start",
    ),
    (
        "kill-line-end",
        LineEdit::KillLineEnd,
        "Cut to line end, or the line break at line end",
    ),
    ("yank", LineEdit::Yank, "Paste the last cut text"),
];
impl LineEdit {
    /// The motion of a moving edit, in a document and in an input field.
    fn motion(self) -> Option<(Motion, InputMotion)> {
        Some(match self {
            Self::CharLeft => (Motion::Backward, InputMotion::Left),
            Self::CharRight => (Motion::Forward, InputMotion::Right),
            Self::WordLeft => (Motion::WordBackward, InputMotion::WordLeft),
            Self::WordRight => (Motion::WordForward, InputMotion::WordRight),
            Self::LineStart => (Motion::LineStart, InputMotion::Start),
            Self::LineEnd => (Motion::LineEnd, InputMotion::End),
            _ => return None,
        })
    }
    pub(super) fn is_motion(self) -> bool {
        self.motion().is_some()
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
        if let Some((motion, _)) = self.motion() {
            return Command::Edit(Edit::Move { motion, extend });
        }
        match self {
            Self::DeleteBackward => Command::Edit(Edit::Delete {
                direction: Direction::Backward,
                smart: true,
            }),
            Self::DeleteForward => Command::Edit(Edit::Delete {
                direction: Direction::Forward,
                smart: false,
            }),
            Self::KillWordBackward => Command::Clipboard(ClipboardAction::Kill {
                backward: true,
                word: true,
            }),
            Self::KillWordForward => Command::Clipboard(ClipboardAction::Kill {
                backward: false,
                word: true,
            }),
            Self::KillLineStart => Command::Clipboard(ClipboardAction::Kill {
                backward: true,
                word: false,
            }),
            Self::KillLineEnd => Command::Clipboard(ClipboardAction::Kill {
                backward: false,
                word: false,
            }),
            Self::Yank => Command::Clipboard(ClipboardAction::Paste),
            _ => unreachable!("motions are handled above"),
        }
    }
    pub(super) fn input(self, extend: bool) -> InputKey {
        if let Some((_, motion)) = self.motion() {
            return InputKey::Move { motion, extend };
        }
        match self {
            Self::DeleteBackward => InputKey::Delete {
                backward: true,
                word: false,
            },
            Self::DeleteForward => InputKey::Delete {
                backward: false,
                word: false,
            },
            Self::KillWordBackward => InputKey::Kill(InputMotion::WordLeft),
            Self::KillWordForward => InputKey::Delete {
                backward: false,
                word: true,
            },
            Self::KillLineStart => InputKey::Kill(InputMotion::Start),
            Self::KillLineEnd => InputKey::Kill(InputMotion::End),
            Self::Yank => InputKey::Yank,
            _ => unreachable!("motions are handled above"),
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
    ("<c-w>", "kill-word-backward"),
    ("<c-bs>", "kill-word-backward"),
    ("<a-bs>", "kill-word-backward"),
    ("<c-del>", "kill-word-forward"),
    ("<a-d>", "kill-word-forward"),
    ("<c-u>", "kill-line-start"),
    ("<c-k>", "kill-line-end"),
    ("<c-y>", "yank"),
];
/// Keys of every editing mode. `<c-c>` is the leader: `<space>f` in Normal
/// reads as `<c-c>f`, so a module binds its keys here once.
const GLOBAL: &[(&str, &str)] = &[
    ("<c-x><c-s>", "write"),
    ("<c-x><c-w>", "saveas"),
    ("<c-x><c-f>", "open"),
    ("<c-x><c-r>", "recent"),
    ("<c-x><c-c>", "quit"),
    ("<c-x>b", "buffer"),
    ("<c-x><c-b>", "buffer"),
    ("<c-x>k", "close"),
    ("<c-x>0", "close-window"),
    ("<c-x>1", "only"),
    ("<c-x>2", "split"),
    ("<c-x>3", "vsplit"),
    ("<c-x>o", "window-next"),
    ("<c-x>^", "resize-window"),
    ("<c-x><c-o>", "window-pick"),
    ("<c-x>u", "undo"),
    ("<c-x>`", "next-result"),
    ("<c-x>pf", "project"),
    ("<c-x>pb", "buffer"),
    ("<c-x>pg", "grep"),
    ("<a-x>", "commands"),
    ("<a-!>", "shell"),
    ("<a-|>", "pipe"),
    ("<a-%>", "replace"),
    ("<a-g>g", "goto"),
    ("<a-g><a-g>", "goto"),
    ("<a-g>n", "next-result"),
    ("<a-g><a-n>", "next-result"),
    ("<a-g>p", "previous-result"),
    ("<a-g><a-p>", "previous-result"),
    ("<a-,>", "jump-back"),
    ("<c-a-,>", "jump-forward"),
    ("<c-v>", "half-page-down"),
    ("<a-v>", "half-page-up"),
    ("<c-l>", "recenter"),
    ("<c-/>", "undo"),
    ("<c-_>", "undo"),
    // Terminals without the kitty protocol send this for Ctrl-/.
    ("<c-7>", "undo"),
    ("<c-a-/>", "redo"),
    ("<c-a-_>", "redo"),
    ("<c-z>", "suspend"),
    ("<c-c><c-c>", "stop"),
    ("<f3>", "macro-start"),
    ("<f4>", "macro-end"),
    ("<c-x>(", "macro-start"),
    ("<c-x>)", "macro-end"),
    ("<c-x>e", "macro-end"),
    ("<c-c>[", "macro-start"),
    ("<c-c>]", "macro-end"),
    ("<c-c>1", "digit-argument 1"),
    ("<c-c>2", "digit-argument 2"),
    ("<c-c>3", "digit-argument 3"),
    ("<c-c>4", "digit-argument 4"),
    ("<c-c>5", "digit-argument 5"),
    ("<c-c>6", "digit-argument 6"),
    ("<c-c>7", "digit-argument 7"),
    ("<c-c>8", "digit-argument 8"),
    ("<c-c>9", "digit-argument 9"),
    ("<c-c>0", "digit-argument 0"),
    ("<c-c>f", "project"),
    ("<c-c>o", "window-pick"),
    ("<c-c>b", "buffer"),
    ("<c-c>:", "commands"),
    ("<c-c>j", "jump-to"),
    ("<c-c>w", "window-pick"),
    ("<c-c>r", "recent"),
    ("<c-c>H", "window-left"),
    ("<c-c>J", "window-down"),
    ("<c-c>K", "window-up"),
    ("<c-c>L", "window-right"),
    ("<c-c>W", "resize-window"),
];
/// The keys of `meow`, and Emacs keys for the same moves.
const NORMAL: &[(&str, &str)] = &[
    ("h", "left"),
    ("j", "down"),
    ("k", "up"),
    ("l", "right"),
    ("H", "left-expand"),
    ("J", "down-expand"),
    ("K", "up-expand"),
    ("L", "right-expand"),
    ("<left>", "left"),
    ("<down>", "down"),
    ("<up>", "up"),
    ("<right>", "right"),
    ("<s-left>", "left-expand"),
    ("<s-down>", "down-expand"),
    ("<s-up>", "up-expand"),
    ("<s-right>", "right-expand"),
    ("<c-b>", "left"),
    ("<c-n>", "down"),
    ("<c-p>", "up"),
    ("<c-f>", "right"),
    ("<home>", "line-start"),
    ("<end>", "line-end"),
    ("<c-a>", "line-start"),
    ("<c-e>", "line-end"),
    ("<a-lt>", "document-start"),
    ("<a-gt>", "document-end"),
    ("<a-b>", "word-left"),
    ("<a-f>", "word-right"),
    ("w", "next-word"),
    ("b", "back-word"),
    ("W", "next-symbol"),
    ("B", "back-symbol"),
    ("[", "mark-word"),
    ("]", "mark-symbol"),
    ("e", "select-line"),
    ("o", "block"),
    ("O", "to-block"),
    ("f", "find"),
    ("t", "till"),
    (",", "inner-of-thing"),
    (".", "bounds-of-thing"),
    (";", "reverse"),
    ("<esc>", "cancel"),
    ("<c-g>", "cancel"),
    ("<c-[>", "cancel"),
    ("z", "pop-selection"),
    ("Z", "pop-all-selection"),
    ("-", "negative-argument"),
    ("0", "expand 0"),
    ("1", "expand 1"),
    ("2", "expand 2"),
    ("3", "expand 3"),
    ("4", "expand 4"),
    ("5", "expand 5"),
    ("6", "expand 6"),
    ("7", "expand 7"),
    ("8", "expand 8"),
    ("9", "expand 9"),
    ("i", "insert"),
    ("a", "append"),
    ("A", "open-below"),
    ("I", "open-above"),
    ("r", "kill"),
    ("s", "change"),
    ("d", "delete"),
    ("y", "save"),
    ("p", "put"),
    ("<c-w>", "kill"),
    ("<a-w>", "save"),
    ("<c-y>", "put"),
    ("<a-y>", "yank-pop"),
    ("<c-d>", "delete"),
    ("<c-k>", "kill-line-end"),
    ("<a-d>", "kill-word-forward"),
    ("<a-bs>", "kill-word-backward"),
    ("<c-space>", "set-mark"),
    ("'", "join"),
    ("n", "search-next"),
    ("N", "search-pop"),
    ("v", "visit"),
    ("<c-s>", "search"),
    ("<c-r>", "search-backward"),
    ("u", "undo"),
    ("U", "redo"),
    ("q", "jump-to"),
    ("Q", "goto"),
    ("R", "replace"),
    ("/", "open"),
    ("`", "repeat"),
    ("G", "grab"),
    ("S", "swap-grab"),
    ("E", "macro-lines"),
    ("V", "macro-matches"),
    ("x", "keypad <c-x>"),
    ("c", "keypad <c-c>"),
    ("m", "keypad meta"),
    ("g", "keypad ctrl-meta"),
    ("<space>", "keypad leader"),
    ("<pagedown>", "page-down"),
    ("<pageup>", "page-up"),
    ("<ret>", "jump"),
    ("<c-o>", "jump-back"),
    ("<c-i>", "jump-forward"),
    // Terminals without the kitty protocol send Tab for Ctrl-I.
    ("<tab>", "jump-forward"),
    ("<f1>", "help"),
];
const COMPLETION: &[(&str, &str)] = &[
    ("<tab>", "completion-replace"),
    ("<ret>", "completion-accept"),
    ("<c-n>", "completion-next"),
    ("<down>", "completion-next"),
    ("<c-p>", "completion-previous"),
    ("<up>", "completion-previous"),
    ("<c-g>", "completion-dismiss"),
];
const SNIPPET: &[(&str, &str)] = &[
    ("<tab>", "snippet-next"),
    ("<backtab>", "snippet-previous"),
    ("<s-backtab>", "snippet-previous"),
    ("<s-tab>", "snippet-previous"),
];
const TREE: &[(&str, &str)] = &[
    ("<tab>", "tree-toggle"),
    ("<ret>", "tree-open"),
    ("<bs>", "tree-collapse"),
];
const INSERT: &[(&str, &str)] = &[
    ("<a-/>", "completion-trigger"),
    ("<a-y>", "yank-pop"),
    ("<up>", "move-up"),
    ("<down>", "move-down"),
    ("<s-up>", "extend-move-up"),
    ("<s-down>", "extend-move-down"),
    ("<c-p>", "move-up"),
    ("<c-n>", "move-down"),
    ("<a-lt>", "document-start"),
    ("<a-gt>", "document-end"),
    ("<c-s>", "search"),
    ("<c-r>", "search-backward"),
    ("<ret>", "newline"),
    ("<c-j>", "newline"),
    ("<tab>", "insert-tab"),
    ("<backtab>", "outdent"),
    ("<s-backtab>", "outdent"),
    ("<f1>", "help"),
];
const PROMPT: &[(&str, &str)] = &[
    ("<esc>", "cancel"),
    ("<c-c>", "cancel"),
    ("<c-g>", "cancel"),
    ("<ret>", "confirm"),
    ("<c-j>", "confirm"),
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
    ("<a-lt>", "candidate-first"),
    ("<a-gt>", "candidate-last"),
    ("<pageup>", "page-previous"),
    ("<pagedown>", "page-next"),
    ("<a-v>", "page-previous"),
    ("<c-v>", "page-next"),
    ("<c-s>", "match-next"),
    ("<c-r>", "match-previous"),
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
        && (!ch.is_alphabetic() || (ch.is_uppercase() && !key.control && !key.alt))
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
            || (key.control && matches!(key.code, Key::Char('[' | 'c' | 'g'))))
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
    // Ctrl-C may continue a sequence, as in `<c-x><c-c>`; elsewhere it cancels.
    let ctrl_c = |key: &KeyStroke| key.control && key.code == Key::Char('c');
    if keys
        .iter()
        .skip(1)
        .any(|key| is_cancel(key) && !ctrl_c(key))
    {
        return Err(BindingError::InvalidKey);
    }
    Ok(keys)
}

pub struct Keymap {
    edit: [Layer<Command>; 8],
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
            (Context::Global, GLOBAL),
            (Context::Normal, NORMAL),
            (Context::Insert, INSERT),
            (Context::Insert, READLINE),
            (Context::Completion, COMPLETION),
            (Context::Snippet, SNIPPET),
            (Context::Mark, &[]),
            (Context::Tree, TREE),
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
    /// The first table of `stack` that knows `keys`, as Emacs reads its
    /// active maps; `skip` passes over a binding that is off for now.
    pub(super) fn resolve(
        &self,
        stack: &[Context],
        keys: &[KeyStroke],
        skip: &dyn Fn(&Command) -> bool,
    ) -> (Resolution<Command>, Context) {
        for &context in stack {
            match self.edit[context as usize].resolve(keys) {
                Resolution::Pass => {}
                Resolution::Complete(command) if skip(&command) => {}
                resolution => return (resolution, context),
            }
        }
        (Resolution::Pass, Context::Global)
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
        stack: &[Context],
        prefix: &[KeyStroke],
    ) -> Vec<(KeyStroke, String)> {
        let mut out: Vec<(KeyStroke, String)> = vec![];
        let bindings = stack.iter().flat_map(|context| self.bindings(*context));
        for (keys, label) in bindings {
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
                format!("+{}", super::emacs_notation(&keys[..=prefix.len()]))
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

/// How the keypad starts: `x` reads as `<c-x>`, the leader as `<c-c>` with
/// its next key plain, `m` and `g` as Meta and Ctrl-Meta on the next key.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KeypadStart {
    Prefix(KeyStroke),
    Leader,
    Modifier { control: bool },
}
#[derive(Clone, Copy, Default)]
struct Keypad {
    /// The next key is taken as it is; Space asks for this.
    literal: bool,
    /// The next key takes Alt, and Ctrl if the flag says so.
    modifier: Option<bool>,
}
/// Pending key sequence of an editing context. In the keypad each plain key
/// is tried with Ctrl first, then as it is, in the global table alone: both
/// `x s` and `<c-x><c-s>` reach one binding, and `x <space> o` still reaches
/// `<c-x>o` next to `<c-x><c-o>`.
#[derive(Default)]
pub(super) struct Sequence {
    keys: Vec<KeyStroke>,
    keypad: Option<Keypad>,
    /// The table that gave the last complete binding.
    pub source: Option<Context>,
}
impl Sequence {
    pub fn active(&self) -> bool {
        !self.keys.is_empty() || self.keypad.is_some()
    }
    pub fn clear(&mut self) {
        self.keys.clear();
        self.keypad = None;
    }
    pub fn start(&mut self, start: KeypadStart) {
        self.clear();
        let mut keypad = Keypad::default();
        match start {
            KeypadStart::Prefix(key) => self.keys.push(key),
            KeypadStart::Leader => {
                self.keys.extend(canonical(CTRL_C));
                keypad.literal = true;
            }
            KeypadStart::Modifier { control } => keypad.modifier = Some(control),
        }
        self.keypad = Some(keypad);
    }
    pub fn in_keypad(&self) -> bool {
        self.keypad.is_some()
    }
    /// The keys a keypad key stands for, in the order to try them.
    fn candidates(key: KeyStroke, keypad: Keypad) -> Vec<KeyStroke> {
        if let Some(control) = keypad.modifier {
            return vec![KeyStroke {
                alt: true,
                control,
                ..key
            }];
        }
        let char_key = matches!(key.code, Key::Char(_)) && !key.control && !key.alt;
        if keypad.literal || !char_key {
            return vec![key];
        }
        let control = KeyStroke {
            control: true,
            ..key
        };
        vec![control, key]
    }
    pub fn push_keypad(
        &mut self,
        key: KeyStroke,
        stack: &[Context],
        map: &Keymap,
    ) -> Resolution<Command> {
        let keypad = self.keypad.unwrap_or_default();
        let Ok(key) = canonical(key) else {
            self.clear();
            return Resolution::Invalid;
        };
        if key.code == Key::Backspace {
            if self.keys.len() > 1 {
                self.keys.pop();
            } else {
                self.clear();
            }
            return Resolution::Prefix;
        }
        if key.code == Key::Char(' ') && !keypad.literal && keypad.modifier.is_none() {
            self.keypad = Some(Keypad {
                literal: true,
                modifier: None,
            });
            return Resolution::Prefix;
        }
        for candidate in Self::candidates(key, keypad) {
            let Ok(candidate) = canonical(candidate) else {
                continue;
            };
            let keys = [&self.keys[..], &[candidate]].concat();
            // A chord with Meta means what it means when typed; plain keys
            // of Normal stay out of what the keypad reads.
            let tables: &[Context] = if keypad.modifier.is_some() {
                stack
            } else {
                &[Context::Global]
            };
            match map.resolve(tables, &keys, &|_| false).0 {
                Resolution::Prefix => {
                    self.keys = keys;
                    self.keypad = Some(Keypad::default());
                    return Resolution::Prefix;
                }
                Resolution::Complete(command) => {
                    self.source = Some(Context::Global);
                    self.clear();
                    return Resolution::Complete(command);
                }
                _ => {}
            }
        }
        self.clear();
        Resolution::Invalid
    }
    pub fn push(
        &mut self,
        key: KeyStroke,
        stack: &[Context],
        map: &Keymap,
        skip: &dyn Fn(&Command) -> bool,
    ) -> Resolution<Command> {
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
        match map.resolve(stack, &self.keys, skip) {
            (Resolution::Prefix, _) => Resolution::Prefix,
            (Resolution::Complete(command), context) => {
                self.source = Some(context);
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
    pub fn keys(&self) -> &[KeyStroke] {
        &self.keys
    }
    /// The modifiers the keypad will give the next key, as Emacs writes
    /// them, after `m` or `g`; a plain key may or may not take Ctrl, so
    /// it says nothing and the key hints show what follows.
    pub fn keypad_hint(&self) -> &'static str {
        match self.keypad {
            Some(Keypad {
                modifier: Some(true),
                ..
            }) => "C-M-",
            Some(Keypad {
                modifier: Some(false),
                ..
            }) => "M-",
            _ => "",
        }
    }
    /// Next keys as the keypad reads them, each shown as the plain key to
    /// press. After `m` or `g` they are the chords with Meta of the whole
    /// stack, as the keypad resolves them; otherwise a Ctrl binding wins
    /// over a plain binding of that key, and chords with Meta, which the
    /// keypad cannot type after a prefix, are left out.
    pub fn keypad_continuations(
        &self,
        stack: &[Context],
        map: &Keymap,
    ) -> Vec<(KeyStroke, String)> {
        let keypad = self.keypad.unwrap_or_default();
        let plain = |key: KeyStroke| KeyStroke {
            control: false,
            alt: false,
            ..key
        };
        if let Some(control) = keypad.modifier {
            return map
                .continuations(stack, &self.keys)
                .into_iter()
                .filter(|(key, _)| key.alt && key.control == control)
                .map(|(key, label)| (plain(key), label))
                .collect();
        }
        let next = map.continuations(&[Context::Global], &self.keys);
        let mut out: Vec<(KeyStroke, String)> = vec![];
        if !keypad.literal {
            for (key, label) in next.iter().filter(|(key, _)| key.control && !key.alt) {
                out.push((plain(*key), label.clone()));
            }
        }
        for (key, label) in next.iter().filter(|(key, _)| !key.control && !key.alt) {
            if !out.iter().any(|(shown, _)| shown == key) {
                out.push((*key, label.clone()));
            }
        }
        out
    }
    /// Whether a key goes on with the pending sequence.
    pub fn continues(&self, key: KeyStroke, stack: &[Context], map: &Keymap) -> bool {
        let keys = [&self.keys[..], &[key]].concat();
        !self.keys.is_empty()
            && !matches!(map.resolve(stack, &keys, &|_| false).0, Resolution::Pass)
    }
}
const CTRL_C: KeyStroke = KeyStroke {
    code: Key::Char('c'),
    control: true,
    alt: false,
    shift: false,
    unsupported_modifiers: false,
    release: false,
};
