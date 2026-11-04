//! Context-scoped key tables. Defaults are command lines resolved through the
//! registry; user bindings shadow them and unbinding restores the default.
use super::{
    Command, Input, InputKey, InputMotion, Key, KeyStroke,
    picker::ListMotion,
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
    /// A document of results, such as grep's, below `Tree`.
    Results,
    Prompt,
}
impl Context {
    pub const ALL: [Self; 10] = [
        Self::Global,
        Self::Normal,
        Self::Beacon,
        Self::Insert,
        Self::Completion,
        Self::Snippet,
        Self::Mark,
        Self::Tree,
        Self::Results,
        Self::Prompt,
    ];
    /// Each context's name and what its keys are for, in the order of
    /// `ALL`; `map` offers them.
    pub(super) const CHOICES: [Choice; 10] = [
        word("global", "Keys of every mode, and of the keypad"),
        word("normal", "Normal mode keys"),
        word("beacon", "Beacon keys, over Normal's"),
        word("insert", "Insert mode keys"),
        word("completion", "Keys while the completion list shows"),
        word("snippet", "Keys while a snippet has places left"),
        word("mark", "Keys with the caret on a marked symbol"),
        word("tree", "Keys in a document that shows a tree"),
        word("results", "Keys in a document of results, such as grep's"),
        word("prompt", "Command line and prompt keys"),
    ];
    pub fn name(self) -> &'static str {
        Self::CHOICES[self as usize].word
    }
    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|context| context.name() == name)
    }
}
/// A key table in a stack: one of the contexts, or a document keymap.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Table {
    Context(Context),
    /// By its place among the document keymaps.
    Document(usize),
}
impl From<Context> for Table {
    fn from(context: Context) -> Self {
        Self::Context(context)
    }
}
impl Table {
    /// Tables that hold keys for every mode, as `global` does: what the
    /// keypad reads its plain keys from.
    fn shared(self) -> bool {
        matches!(self, Self::Context(Context::Global) | Self::Document(_))
    }
}
/// Where a document keymap is in force.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Scope {
    /// Documents in this language.
    Language(String),
    /// Documents a language server of this name serves; `None` for any.
    Server(Option<String>),
}
/// A keymap that holds in some documents only, as an Emacs minor mode's.
struct DocumentKeymap {
    name: String,
    doc: String,
    scope: Scope,
    layer: Layer<Command>,
}

#[test]
fn every_context_has_its_choice_in_order() {
    for (index, context) in Context::ALL.into_iter().enumerate() {
        assert_eq!(context as usize, index);
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
    ("C-b", "char-left"),
    ("C-f", "char-right"),
    ("S-<left>", "extend-char-left"),
    ("S-<right>", "extend-char-right"),
    ("C-<left>", "word-left"),
    ("C-<right>", "word-right"),
    ("M-b", "word-left"),
    ("M-f", "word-right"),
    ("C-S-<left>", "extend-word-left"),
    ("C-S-<right>", "extend-word-right"),
    ("<home>", "line-start"),
    ("<end>", "line-end"),
    ("C-a", "line-start"),
    ("C-e", "line-end"),
    ("S-<home>", "extend-line-start"),
    ("S-<end>", "extend-line-end"),
    ("DEL", "delete-backward"),
    ("C-h", "delete-backward"),
    ("<delete>", "delete-forward"),
    ("C-d", "delete-forward"),
    ("C-w", "kill-word-backward"),
    ("C-DEL", "kill-word-backward"),
    ("M-DEL", "kill-word-backward"),
    ("C-<delete>", "kill-word-forward"),
    ("M-d", "kill-word-forward"),
    ("C-u", "kill-line-start"),
    ("C-k", "kill-line-end"),
    ("C-y", "yank"),
];
/// Keys of every editing mode. `C-c` is the leader: `SPC f` in Normal
/// reads as `C-c f`, so a module binds its keys here once.
const GLOBAL: &[(&str, &str)] = &[
    ("C-x C-s", "write"),
    ("C-x C-w", "saveas"),
    ("C-x C-f", "open"),
    ("C-x C-r", "recent"),
    ("C-x C-c", "quit"),
    ("C-u", "universal-argument"),
    ("C-x b", "buffer"),
    ("C-x C-b", "buffer"),
    ("C-x k", "kill-buffer"),
    ("C-x <left>", "previous-buffer"),
    ("C-x C-<left>", "previous-buffer"),
    ("C-x <right>", "next-buffer"),
    ("C-x C-<right>", "next-buffer"),
    ("C-x s", "save-some-buffers"),
    ("C-x z", "repeat"),
    ("M-s .", "search-symbol"),
    ("C-x 0", "close-window"),
    ("C-x 1", "only"),
    ("C-x 2", "split"),
    ("C-x 3", "vsplit"),
    ("C-x o", "window-next"),
    ("C-x ^", "resize-window"),
    ("C-x u", "undo"),
    ("C-x h", "select-all"),
    ("C-x C-x", "reverse"),
    ("C-x `", "next-result"),
    ("C-x p f", "project"),
    ("C-x p p", "project-switch"),
    ("C-x p b", "buffer"),
    ("C-x p g", "grep"),
    ("M-x", "commands"),
    ("M-!", "shell"),
    ("M-|", "pipe"),
    ("M-%", "replace"),
    ("M-g g", "goto"),
    ("M-g M-g", "goto"),
    ("M-g n", "next-result"),
    ("M-g M-n", "next-result"),
    ("M-g p", "previous-result"),
    ("M-g M-p", "previous-result"),
    ("M-,", "jump-back"),
    ("C-M-,", "jump-forward"),
    ("C-v", "half-page-down"),
    ("M-v", "half-page-up"),
    ("C-l", "recenter"),
    ("C-/", "undo"),
    ("C-_", "undo"),
    // Terminals without the kitty protocol send this for Ctrl-/.
    ("C-7", "undo"),
    ("C-M-/", "redo"),
    ("C-M-_", "redo"),
    ("C-z", "suspend"),
    ("C-c C-c", "stop"),
    // Keyboard macros, as kmacro.el binds them.
    ("<f3>", "macro-start"),
    ("<f4>", "macro-end"),
    ("C-x (", "macro-record"),
    ("C-x )", "macro-stop"),
    ("C-x e", "macro-end-and-call"),
    ("C-x C-k s", "macro-record"),
    ("C-x C-k C-s", "macro-record"),
    ("C-x C-k C-k", "macro-end-repeat"),
    ("C-x C-k r", "macro-lines"),
    ("C-x C-k C-n", "macro-ring-next"),
    ("C-x C-k C-p", "macro-ring-previous"),
    ("C-x C-k C-v", "macro-view"),
    ("C-x C-k C-d", "macro-ring-delete"),
    ("C-x C-k C-t", "macro-ring-swap"),
    ("C-x C-k C-l", "macro-call-second"),
    ("C-x C-k C-f", "macro-set-format"),
    ("C-x C-k C-c", "macro-set-counter"),
    ("C-x C-k C-i", "macro-insert-counter"),
    ("C-x C-k TAB", "macro-insert-counter"),
    ("C-x C-k C-a", "macro-add-counter"),
    ("C-x C-k n", "macro-name"),
];
/// Normal's keys that type no character: Emacs's, for the same moves and
/// edits as in Insert. The keys of characters come from a layout, such as
/// the meow plugin's.
const NORMAL: &[(&str, &str)] = &[
    ("<left>", "left"),
    ("<down>", "down"),
    ("<up>", "up"),
    ("<right>", "right"),
    ("S-<left>", "left-expand"),
    ("S-<down>", "down-expand"),
    ("S-<up>", "up-expand"),
    ("S-<right>", "right-expand"),
    ("C-b", "left"),
    ("C-n", "down"),
    ("C-p", "up"),
    ("C-f", "right"),
    ("<home>", "line-start"),
    ("<end>", "line-end"),
    ("C-a", "line-start"),
    ("C-e", "line-end"),
    ("M-<", "document-start"),
    ("M->", "document-end"),
    ("M-b", "word-left"),
    ("M-f", "word-right"),
    ("ESC", "cancel"),
    ("C-g", "cancel"),
    ("C-[", "cancel"),
    ("C-w", "kill"),
    ("M-w", "save"),
    ("C-y", "put"),
    ("M-y", "yank-pop"),
    ("C-d", "delete"),
    ("C-k", "kill-line-end"),
    ("M-d", "kill-word-forward"),
    ("M-DEL", "kill-word-backward"),
    ("C-SPC", "set-mark"),
    ("C-s", "search"),
    ("C-r", "search-backward"),
    ("<next>", "page-down"),
    ("<prior>", "page-up"),
    ("RET", "jump"),
    ("C-o", "jump-back"),
    ("C-i", "jump-forward"),
    // Terminals without the kitty protocol send Tab for Ctrl-I.
    ("TAB", "jump-forward"),
    ("<f1>", "help"),
];
const COMPLETION: &[(&str, &str)] = &[
    ("TAB", "completion-replace"),
    ("RET", "completion-accept"),
    ("C-n", "completion-next"),
    ("<down>", "completion-next"),
    ("C-p", "completion-previous"),
    ("<up>", "completion-previous"),
    ("C-g", "completion-dismiss"),
];
const SNIPPET: &[(&str, &str)] = &[
    ("TAB", "snippet-next"),
    ("<backtab>", "snippet-previous"),
    ("S-<backtab>", "snippet-previous"),
    ("S-TAB", "snippet-previous"),
];
const TREE: &[(&str, &str)] = &[
    ("TAB", "tree-toggle"),
    ("RET", "tree-open"),
    ("DEL", "tree-collapse"),
];
const RESULTS: &[(&str, &str)] = &[("RET", "jump")];
const INSERT: &[(&str, &str)] = &[
    // Before readline's C-u, which kills to the line start in prompts.
    ("C-u", "universal-argument"),
    ("C-SPC", "set-mark"),
    ("C-w", "kill-region"),
    ("M-w", "kill-ring-save"),
    ("M-/", "completion-trigger"),
    ("M-y", "yank-pop"),
    ("<up>", "move-up"),
    ("<down>", "move-down"),
    ("S-<up>", "extend-move-up"),
    ("S-<down>", "extend-move-down"),
    ("C-p", "move-up"),
    ("C-n", "move-down"),
    ("M-<", "document-start"),
    ("M->", "document-end"),
    ("C-s", "search"),
    ("C-r", "search-backward"),
    ("RET", "newline"),
    ("C-j", "newline"),
    ("TAB", "indent-for-tab"),
    ("<backtab>", "outdent"),
    ("S-<backtab>", "outdent"),
    ("<f1>", "help"),
];
const PROMPT: &[(&str, &str)] = &[
    ("ESC", "cancel"),
    ("C-c", "cancel"),
    ("C-g", "cancel"),
    ("RET", "confirm"),
    ("C-j", "confirm"),
    ("C-RET", "replace-all"),
    ("<f4>", "replace-all"),
    ("TAB", "complete"),
    ("<backtab>", "complete-backward"),
    ("S-<backtab>", "complete-backward"),
    ("S-TAB", "complete-backward"),
    ("<up>", "candidate-previous"),
    ("<down>", "candidate-next"),
    ("C-p", "candidate-previous"),
    ("C-n", "candidate-next"),
    ("M-p", "history-previous"),
    ("M-n", "history-next"),
    ("C-<up>", "candidate-first"),
    ("C-<down>", "candidate-last"),
    ("M-<", "candidate-first"),
    ("M->", "candidate-last"),
    ("<prior>", "page-previous"),
    ("<next>", "page-next"),
    ("M-v", "page-previous"),
    ("C-v", "page-next"),
    ("C-s", "match-next"),
    ("C-r", "match-previous"),
    ("<f1>", "help"),
    ("<f3>", "match-next"),
    ("S-<f3>", "match-previous"),
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

/// Keys and what each shows, as listings give them.
pub type Bindings = Vec<(Vec<KeyStroke>, String)>;
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
    fn bind_default(
        &mut self,
        keys: &[KeyStroke],
        target: T,
        label: String,
    ) -> Result<(), BindingError> {
        let keys = sequence(keys)?;
        // The latest default wins over one it equals or overlaps, as a
        // later minor mode's keymap does.
        self.defaults
            .retain(|b| !(b.keys.starts_with(&keys) || keys.starts_with(&b.keys)));
        self.defaults.insert(
            0,
            Binding {
                keys,
                target,
                label,
            },
        );
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
    // Ctrl-C may continue a sequence, as in `C-x C-c`; elsewhere it cancels.
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
    edit: [Layer<Command>; 9],
    prompt: Layer<Input>,
    /// In the order defined; a later one is asked first.
    documents: Vec<DocumentKeymap>,
}
impl Default for Keymap {
    fn default() -> Self {
        let registry = Registry::default();
        let mut keymap = Self {
            edit: Default::default(),
            prompt: Layer::default(),
            documents: vec![],
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
            (Context::Results, RESULTS),
        ] {
            for (keys, line) in table {
                let target = registry.parse_builtin(line).unwrap();
                let keys = sequence(&parse(keys)).unwrap();
                // Insert's own keys come before the readline ones they replace.
                let layer = &mut keymap.edit[context as usize];
                if layer.defaults.iter().any(|binding| binding.keys == keys) {
                    continue;
                }
                layer.defaults.push(Binding {
                    keys,
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
    /// Defines a document keymap, or gives one its description and scope
    /// again. Its name may not be a context's or a language's.
    pub fn define(&mut self, name: &str, scope: Scope, doc: String) -> Result<(), String> {
        if Context::parse(name).is_some() {
            return Err(format!("{name} is a key context"));
        }
        let language = crate::language::catalog().by_id(name).is_some();
        if language != matches!(scope, Scope::Language(_)) {
            return Err(format!(
                "{name} is a language; its keymap needs no definition"
            ));
        }
        match self.documents.iter_mut().find(|keymap| keymap.name == name) {
            Some(keymap) => {
                keymap.scope = scope;
                keymap.doc = doc;
            }
            None => self.documents.push(DocumentKeymap {
                name: name.to_owned(),
                doc,
                scope,
                layer: Layer::default(),
            }),
        }
        Ok(())
    }
    /// The table a name stands for: a context, a document keymap, or the
    /// keymap of a language, made the first time it is named.
    pub(super) fn table(&mut self, name: &str) -> Option<Table> {
        if let Some(context) = Context::parse(name) {
            return Some(Table::Context(context));
        }
        if let Some(index) = self.documents.iter().position(|k| k.name == name) {
            return Some(Table::Document(index));
        }
        crate::language::catalog().by_id(name)?;
        let doc = format!("Keys of {name} documents");
        self.define(name, Scope::Language(name.to_owned()), doc)
            .ok()?;
        Some(Table::Document(self.documents.len() - 1))
    }
    /// The bindings of a table by name, for listings; `None` for a name
    /// that is no table yet.
    pub fn bindings_of(&self, name: &str) -> Option<Vec<(Vec<KeyStroke>, String)>> {
        if let Some(context) = Context::parse(name) {
            return Some(self.bindings(context));
        }
        let index = self.documents.iter().position(|k| k.name == name)?;
        Some(self.table_bindings(Table::Document(index)))
    }
    /// The document keymaps in force in a document of `language` that the
    /// servers named in `servers` serve: those of servers, the latest
    /// defined first, then the language's.
    pub(super) fn in_force(&self, language: &str, servers: &[String]) -> Vec<Table> {
        let mut tables: Vec<Table> = (0..self.documents.len())
            .rev()
            .filter(|&index| match &self.documents[index].scope {
                Scope::Server(None) => !servers.is_empty(),
                Scope::Server(Some(name)) => servers.contains(name),
                Scope::Language(_) => false,
            })
            .map(Table::Document)
            .collect();
        tables.extend(
            self.documents
                .iter()
                .position(|k| k.scope == Scope::Language(language.to_owned()))
                .map(Table::Document),
        );
        tables
    }
    /// Every table by name with what it is for: the contexts, then the
    /// document keymaps.
    pub fn names(&self) -> Vec<(String, String)> {
        Context::CHOICES
            .iter()
            .map(|choice| (choice.word.to_owned(), choice.doc.to_owned()))
            .chain(
                self.documents
                    .iter()
                    .map(|keymap| (keymap.name.clone(), keymap.doc.clone())),
            )
            .collect()
    }
    fn layer(&self, table: Table) -> &Layer<Command> {
        match table {
            Table::Context(context) => &self.edit[context as usize],
            Table::Document(index) => &self.documents[index].layer,
        }
    }
    pub(super) fn bind(
        &mut self,
        table: Table,
        keys: &[KeyStroke],
        command: Command,
        label: String,
    ) -> Result<(), BindingError> {
        match table {
            Table::Context(Context::Prompt) => Err(BindingError::InvalidKey),
            Table::Context(context) => self.edit[context as usize].bind(keys, command, label),
            Table::Document(index) => self.documents[index].layer.bind(keys, command, label),
        }
    }
    /// Binds keys as a default, as a plugin does: replaces a default of the
    /// same keys, and gives way to user bindings.
    pub(super) fn bind_default(
        &mut self,
        table: Table,
        keys: &[KeyStroke],
        command: Command,
        label: String,
    ) -> Result<(), BindingError> {
        match table {
            Table::Context(Context::Prompt) => Err(BindingError::InvalidKey),
            Table::Context(context) => {
                self.edit[context as usize].bind_default(keys, command, label)
            }
            Table::Document(index) => self.documents[index]
                .layer
                .bind_default(keys, command, label),
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
    pub(super) fn unbind(&mut self, table: Table, keys: &[KeyStroke]) -> Result<(), BindingError> {
        match table {
            Table::Context(Context::Prompt) => self.prompt.unbind(keys),
            Table::Context(context) => self.edit[context as usize].unbind(keys),
            Table::Document(index) => self.documents[index].layer.unbind(keys),
        }
    }
    /// The first table of `stack` that knows `keys`, as Emacs reads its
    /// active maps; `skip` passes over a binding that is off for now.
    pub(super) fn resolve(
        &self,
        stack: &[Table],
        keys: &[KeyStroke],
        skip: &dyn Fn(&Command) -> bool,
    ) -> (Resolution<Command>, Table) {
        for &table in stack {
            match self.layer(table).resolve(keys) {
                Resolution::Pass => {}
                Resolution::Complete(command) if skip(&command) => {}
                resolution => return (resolution, table),
            }
        }
        (Resolution::Pass, Table::Context(Context::Global))
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
    pub(super) fn continuations(
        &self,
        stack: &[Table],
        prefix: &[KeyStroke],
    ) -> Vec<(KeyStroke, String)> {
        let mut out: Vec<(KeyStroke, String)> = vec![];
        let bindings = stack.iter().flat_map(|table| self.table_bindings(*table));
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
    fn table_bindings(&self, table: Table) -> Vec<(Vec<KeyStroke>, String)> {
        match table {
            Table::Context(context) => self.bindings(context),
            Table::Document(index) => self.documents[index]
                .layer
                .effective()
                .map(|b| (b.keys.clone(), b.label.clone()))
                .collect(),
        }
    }
    /// Each document keymap's name, description and effective bindings,
    /// for help.
    pub fn document_bindings(&self) -> Vec<(&str, &str, Bindings)> {
        (0..self.documents.len())
            .map(|index| {
                let keymap = &self.documents[index];
                let bindings = self.table_bindings(Table::Document(index));
                (keymap.name.as_str(), keymap.doc.as_str(), bindings)
            })
            .collect()
    }
}

/// How the keypad starts: `x` reads as `C-x`, the leader as `C-c` with
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
/// `x s` and `C-x C-s` reach one binding, and `x SPC o` still reaches
/// `C-x o` next to `C-x C-o`.
#[derive(Default)]
pub(super) struct Sequence {
    keys: Vec<KeyStroke>,
    keypad: Option<Keypad>,
    /// The table that gave the last complete binding.
    pub source: Option<Table>,
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
        stack: &[Table],
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
            // of the modes stay out of what the keypad reads.
            let tables: Vec<Table> = if keypad.modifier.is_some() {
                stack.to_vec()
            } else {
                stack
                    .iter()
                    .copied()
                    .filter(|table| table.shared())
                    .collect()
            };
            match map.resolve(&tables, &keys, &|_| false) {
                (Resolution::Prefix, _) => {
                    self.keys = keys;
                    self.keypad = Some(Keypad::default());
                    return Resolution::Prefix;
                }
                (Resolution::Complete(command), table) => {
                    self.source = Some(table);
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
        stack: &[Table],
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
    pub fn keypad_continuations(&self, stack: &[Table], map: &Keymap) -> Vec<(KeyStroke, String)> {
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
        let shared: Vec<Table> = stack.iter().copied().filter(|t| t.shared()).collect();
        let next = map.continuations(&shared, &self.keys);
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
    pub fn continues(&self, key: KeyStroke, stack: &[Table], map: &Keymap) -> bool {
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
