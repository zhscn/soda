//! What each kind of argument does besides listing its candidates, as
//! data: whether an answer must be one of them, the history it goes to,
//! the row it starts on, what choosing previews, how a path is written.
//! The command line asks this table instead of naming kinds, so a kind is
//! described in one place, as a completion table in Emacs carries its
//! metadata, and Lua knows kinds by the names given here.
use super::registry::{Slot, SlotKind};
use crate::application::Application;

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

/// The behavior of a kind.
pub fn behavior(kind: SlotKind) -> Behavior {
    let words = |history| Behavior {
        requires_match: true,
        history: Some(history),
        completes: true,
        ..Behavior::default()
    };
    match kind {
        SlotKind::Path => Behavior {
            requires_match: false,
            input_first: Some(|text| super::command_line::split_path(text).1.is_empty()),
            path: Some(PathForm::Typed),
            ..words(super::history::FILE)
        },
        SlotKind::File => Behavior {
            path: Some(PathForm::Project),
            ..words(super::history::FILE)
        },
        SlotKind::Recent => Behavior {
            path: Some(PathForm::Recent),
            ..words(super::history::FILE)
        },
        SlotKind::Project => Behavior {
            requires_match: false,
            input_first: Some(|text| text.starts_with(['/', '~', '.'])),
            path: Some(PathForm::Typed),
            ..words("project")
        },
        SlotKind::Buffer => Behavior {
            live: true,
            ..words("buffer")
        },
        SlotKind::CurrentBuffer => Behavior {
            live: true,
            current: Some(|app| {
                let view = app.view(app.active_view()?)?;
                Some(app.document_name(view.document_id))
            }),
            ..words("buffer")
        },
        SlotKind::Option => words("option"),
        SlotKind::Face => words("face"),
        SlotKind::Theme => Behavior {
            current: Some(|app| Some(app.options().text(None, "theme").to_owned())),
            preview: Some(Preview::Theme),
            ..words("theme")
        },
        SlotKind::Language => words("language"),
        SlotKind::Keymap => words("keymap"),
        SlotKind::Symbol => Behavior {
            requires_match: false,
            ..words("symbol")
        },
        // Fixed words, a question's items and what Lua lists are not
        // worth remembering across uses.
        SlotKind::Choice(_) | SlotKind::Item | SlotKind::Computed(_) => Behavior {
            history: None,
            ..words("")
        },
        SlotKind::Word | SlotKind::Rest => Behavior::default(),
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
