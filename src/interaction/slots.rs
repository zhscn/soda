//! What each kind of argument does besides listing its candidates, as
//! data: whether an answer must be one of them, the history it goes to,
//! the row it starts on, what choosing previews, how a path is written.
//! The command line asks this table instead of naming kinds, so a kind is
//! described in one place, as a completion table in Emacs carries its
//! metadata, and Lua knows kinds by the names given here.
use crate::application::Application;

/// How the command line completes an argument and whether Enter requires
/// one of the candidates.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SlotKind {
    Source(&'static Source),
    Choice(&'static [Choice]),
    Computed(u64),
    Word,
    Rest,
}

#[allow(non_upper_case_globals)]
impl SlotKind {
    pub const Path: Self = Self::Source(&super::command_line::sources::PATH);
    pub const File: Self = Self::Source(&super::command_line::sources::FILE);
    pub const Buffer: Self = Self::Source(&super::command_line::sources::BUFFER);
    pub const CurrentBuffer: Self = Self::Source(&super::command_line::sources::CURRENT_BUFFER);
    pub const Option: Self = Self::Source(&super::command_line::sources::OPTION);
    pub const Face: Self = Self::Source(&super::command_line::sources::FACE);
    pub const Theme: Self = Self::Source(&super::command_line::sources::THEME);
    pub const Language: Self = Self::Source(&super::command_line::sources::LANGUAGE);
    pub const Keymap: Self = Self::Source(&super::command_line::sources::KEYMAP);
    pub const Recent: Self = Self::Source(&super::command_line::sources::RECENT);
    pub const Project: Self = Self::Source(&super::command_line::sources::PROJECT);
    pub const Item: Self = Self::Source(&super::command_line::sources::ITEM);
    pub const Symbol: Self = Self::Source(&super::command_line::sources::SYMBOL);
}

/// A reusable source for a command argument. A slot can reference a source
/// directly from its declaration. Sources are identified by their address.
pub struct Source {
    pub name: &'static str,
    pub behavior: Behavior,
    pub(super) provider: Provider,
    pub(super) waiting: Option<fn(&super::command_line::sources::PendingSources) -> bool>,
}

pub(super) enum Provider {
    Words(fn(&Application, &str) -> Vec<Item>),
    Builtin(super::command_line::sources::ListCandidates),
}

impl Source {
    /// Defines a source of words and descriptions. The command line matches
    /// the words against the input and applies the slot's history policy.
    pub const fn words(
        name: &'static str,
        behavior: Behavior,
        list: fn(&Application, &str) -> Vec<Item>,
    ) -> Self {
        Self {
            name,
            behavior: Behavior {
                completes: true,
                ..behavior
            },
            provider: Provider::Words(list),
            waiting: None,
        }
    }
    pub(super) const fn with_waiting(
        mut self,
        waiting: fn(&super::command_line::sources::PendingSources) -> bool,
    ) -> Self {
        self.waiting = Some(waiting);
        self
    }
}

impl std::fmt::Debug for Source {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Source").field(&self.name).finish()
    }
}
impl PartialEq for Source {
    fn eq(&self, other: &Self) -> bool {
        std::ptr::eq(self, other)
    }
}
impl Eq for Source {}

/// A word of a `Choice` slot. A key makes the slot's keymap: typed while
/// the slot is empty, it chooses the word and confirms at once.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Choice {
    pub word: &'static str,
    pub key: Option<char>,
    pub doc: &'static str,
}
/// A positional argument. Every slot but the last is one word; the last
/// takes the rest of the line.
#[derive(Clone, Copy, Debug)]
pub struct Slot {
    pub name: &'static str,
    pub kind: SlotKind,
    pub required: bool,
}
/// How a kind of argument behaves.
#[derive(Clone, Copy, Default)]
pub struct Behavior {
    /// Whether the answer must be one of the candidates, as
    /// `completing-read`'s REQUIRE-MATCH.
    pub requires_match: bool,
    /// The history answers go to and words are ordered by; arguments
    /// without candidates have their command's, which `history::of_slot`
    /// names.
    pub history: Option<&'static str>,
    /// Whether there are candidates at all.
    pub completes: bool,
    /// While nothing is typed, the row of what is in force, so Enter alone
    /// keeps it: its text as it fills the argument.
    pub current: Option<fn(&Application) -> Option<String>>,
    /// Whether the input itself is selected first, for this text: where
    /// the text names a directory to go on in rather than a row.
    pub input_first: Option<fn(&str) -> bool>,
    /// What the screen shows of the selected row before it is taken.
    pub preview: Option<Preview>,
    /// Whether the candidates change with the editor while the line is
    /// open, so they are listed again as it changes.
    pub live: bool,
    /// How the argument writes a file, if it names one.
    pub path: Option<PathForm>,
    /// Keeps source order when the provider ranks its candidates.
    pub source_order: bool,
    /// The part of the input that identifies a candidate list.
    pub list_key: Option<fn(&str) -> &str>,
    /// Keep browsing when the slot contains a directory and has no chosen row.
    pub browse_directories: bool,
    /// What to report when both the input and candidate list are empty.
    pub empty_hint: Option<&'static str>,
    /// A row fills the slot with its index, while history keeps its text.
    pub numbered_items: bool,
}
/// What choosing a row shows before it is taken.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Preview {
    /// The theme of that name.
    Theme,
}
/// How an argument writes a file.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PathForm {
    /// As typed: relative to the document's directory, or under `~`.
    Typed,
    /// Relative to the project root; other projects' files are not
    /// written there.
    Project,
    /// Relative to the project root, or in full outside it.
    Recent,
}

impl Behavior {
    pub const TEXT: Self = Self {
        requires_match: false,
        history: None,
        completes: false,
        current: None,
        input_first: None,
        preview: None,
        live: false,
        path: None,
        source_order: false,
        list_key: None,
        browse_directories: false,
        empty_hint: None,
        numbered_items: false,
    };
}

pub(super) const fn words(history: Option<&'static str>) -> Behavior {
    Behavior {
        requires_match: true,
        history,
        completes: true,
        ..Behavior::TEXT
    }
}

/// The behavior of a kind.
pub fn behavior(kind: SlotKind) -> Behavior {
    match kind {
        SlotKind::Source(source) => source.behavior,
        SlotKind::Choice(_) | SlotKind::Computed(_) => words(None),
        SlotKind::Word | SlotKind::Rest => Behavior::TEXT,
    }
}

/// The kinds Lua names, each with the slot a question of that kind
/// answers, so that `args` and `soda.choose` know the same ones.
pub const NAMED: &[(&str, Slot)] = &[
    ("path", answer(SlotKind::Path)),
    ("file", answer(SlotKind::File)),
    ("recent", answer(SlotKind::Recent)),
    ("project", answer(SlotKind::Project)),
    ("buffer", answer(SlotKind::Buffer)),
    ("current-buffer", answer(SlotKind::CurrentBuffer)),
    ("option", answer(SlotKind::Option)),
    ("face", answer(SlotKind::Face)),
    ("theme", answer(SlotKind::Theme)),
    ("language", answer(SlotKind::Language)),
    ("keymap", answer(SlotKind::Keymap)),
    ("symbol", answer(SlotKind::Symbol)),
    ("word", answer(SlotKind::Word)),
    ("rest", answer(SlotKind::Rest)),
];
const fn answer(kind: SlotKind) -> Slot {
    Slot {
        name: "ANSWER",
        kind,
        required: false,
    }
}
/// The kind of a name Lua gives.
pub fn named(name: &str) -> Option<SlotKind> {
    NAMED
        .iter()
        .find(|(known, _)| *known == name)
        .map(|(_, slot)| slot.kind)
}
/// The names of the kinds, for messages.
pub fn names() -> String {
    let names: Vec<_> = NAMED.iter().map(|(name, _)| *name).collect();
    names.join(", ")
}
/// The one argument of a question of `kind`, read as the `answer`
/// command's.
pub fn answer_slots(kind: SlotKind) -> &'static [Slot] {
    NAMED
        .iter()
        .find(|(_, slot)| slot.kind == kind)
        .map_or(&[], |(_, slot)| std::slice::from_ref(slot))
}

/// A word given from outside, by a question's items or a Lua list, with
/// what is said of it.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Item {
    pub text: String,
    pub doc: String,
}
/// What a question asks for.
#[derive(Clone, Debug, PartialEq)]
pub enum Asked {
    /// A line of text, starting as this.
    Text(String),
    /// One of these.
    Items(Vec<Item>),
    /// What an argument of this kind takes.
    Kind(SlotKind),
    /// A typed argument with editable initial text.
    KindInitial(SlotKind, String),
}
