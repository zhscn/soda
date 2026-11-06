//! The modal editing model: selections first, then what acts on them, after
//! meow. Normal moves and selects, Insert types, Beacon holds many selections
//! inside a grabbed range. Each key is one command; a selection remembers the
//! kind of thing it covers, so that the next command can extend it.
mod beacon;
mod execute;
mod kmacro;
mod replay;
pub mod text;
use crate::{
    application::ViewId,
    core::{LogicalColumn, Selection},
    editor::{DocumentPosition, search::SearchQuery},
};
pub(super) use beacon::{BeaconEntry, BeaconPlay, BeaconShape, Beacons};
pub use kmacro::MacroAction;
/// The selection of the active view, if there is one.
pub(super) fn execute_place(app: &crate::application::Application) -> Option<Selection> {
    execute::place(app, Default::default()).map(|at| at.selection)
}
pub(super) use replay::Replay;

/// What a selection covers. Repeating the command of a kind, or a digit,
/// extends the selection by more of the same.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
    Char,
    Word,
    Symbol,
    Line,
    Block,
    Find,
    Till,
    Visit,
    Join,
    Thing,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Step {
    Left,
    Right,
    Up,
    Down,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Entry {
    Before,
    After,
    Below,
    Above,
}
/// A question for the language structure, which the runtime can ask.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Query {
    /// The group around the selection, or its parent.
    Block,
    /// From the head to the end of the next group at this depth.
    ToBlock,
    /// The group around the caret opened by a delimiter.
    Pair { open: char, inner: bool },
}
#[derive(Clone, Copy, Debug)]
pub enum Action {
    /// `h j k l`, or `H J K L` extending a character selection.
    Move {
        step: Step,
        extend: bool,
    },
    /// `w b W B`.
    Thing {
        symbol: bool,
        backward: bool,
    },
    /// `[` and `]`: the word or symbol here, which also becomes the search.
    Mark {
        symbol: bool,
    },
    Line,
    Query(Query),
    /// The answer to a query, selected as `kind`.
    Found {
        anchor: usize,
        head: usize,
        kind: Kind,
        expand: bool,
    },
    Find {
        till: bool,
    },
    /// `,` and `.`: reads which thing, then selects inside or around it.
    ThingAt {
        inner: bool,
    },
    Reverse,
    Cancel,
    PopSelection {
        all: bool,
    },
    /// A digit: more of what the selection covers.
    Expand(usize),
    Negative,
    Digit(usize),
    /// `C-u`: a count of 4, or four times the count `C-u` gave; digits and
    /// `-` typed next make the count, as Emacs's universal-argument.
    Universal,
    Insert(Entry),
    Leave,
    Kill,
    /// Emacs's `kill-region`: the selection, and nothing without one.
    KillRegion,
    /// Emacs's `kill-ring-save`: copies the selection, and nothing without one.
    KillRingSave,
    Change,
    Delete,
    /// meow's `backward-delete`, Emacs's `delete-backward-char`: the
    /// selection, or the character before the caret.
    BackwardDelete,
    Save,
    Yank,
    Join,
    /// `n`: the next match of the search, or of the selection.
    Search,
    /// `N`: forgets the current search for the one before it.
    PopSearch,
    Undo {
        redo: bool,
    },
    Recenter,
    HalfPage {
        down: bool,
    },
    /// Starts the selection at the caret for `C-Space`.
    SetMark,
    /// Enters Beacon inside the selection, or leaves a marker to swap with.
    Grab,
    SwapGrab,
    /// Keyboard macros, as Emacs's kmacro.
    Macro(MacroAction),
    /// Plays the keys Beacon set aside at each of its other places; queued
    /// after the edits at the main selection, so that it finds them done.
    PlayAtBeacons,
    /// The main selection back where it was before the keys played at the
    /// other places, as `save-mark-and-excursion` keeps it in meow.
    ReturnFromBeacons,
    /// The last macro on each selected line.
    MacroLines,
    /// The last macro on each match of the search.
    MacroMatches,
    Repeat,
}
/// What a command asks of the runtime.
#[derive(Clone, Debug)]
pub enum Effect {
    /// A question about the language structure and the selection it is
    /// about; the answer comes back as `Action::Found`.
    Structure(Query, Selection),
    /// The groups around a selection, for `flash-structure` to label;
    /// the answer comes back as `Command::LabelGroups`.
    Groups(Selection),
    /// Words for the end of a line, until the next key.
    Indicator(usize, String),
    /// A key on the row of a tree.
    Tree(TreeAction),
    /// A replacement to make over the files of the project, its query and
    /// replacement typed.
    ProjectReplace(crate::interaction::ProjectReplace),
    /// How the review of one of those files ended.
    FileLoop(crate::interaction::LoopStep),
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TreeAction {
    /// Opens or closes the node.
    Toggle,
    /// Hands the node to the tree's owner, as a jump to it.
    Open,
    /// Closes the node, or goes to its parent.
    Collapse,
}
/// One key to read for the command that asked.
#[derive(Clone, Copy, Debug)]
pub(super) enum Read {
    Find { till: bool },
    Thing { inner: bool },
}
#[derive(Clone, Copy, Debug)]
pub(super) struct Tag {
    pub selection: Selection,
    pub kind: Kind,
    pub expand: bool,
}
#[derive(Clone, Copy, Debug)]
pub(super) struct LastFind {
    pub ch: char,
    pub till: bool,
}
/// Text set aside by `G`: a range, or the place a marker holds.
#[derive(Clone, Copy, Debug)]
pub(super) struct Grab {
    pub start: DocumentPosition,
    pub end: DocumentPosition,
}
/// What a thing key selects, after `,` or `.`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Thing {
    /// A balanced group opened by this bracket, from the language's structure.
    Pair(char),
    String,
    Symbol,
    Word,
    Paragraph,
    Line,
    Buffer,
}
impl Thing {
    /// Each kind by the name `soda.thing` takes.
    pub const NAMES: [(&'static str, Thing); 10] = [
        ("round", Thing::Pair('(')),
        ("square", Thing::Pair('[')),
        ("curly", Thing::Pair('{')),
        ("angle", Thing::Pair('<')),
        ("string", Thing::String),
        ("symbol", Thing::Symbol),
        ("word", Thing::Word),
        ("paragraph", Thing::Paragraph),
        ("line", Thing::Line),
        ("buffer", Thing::Buffer),
    ];
    pub fn parse(name: &str) -> Option<Self> {
        Self::NAMES
            .iter()
            .find(|(word, _)| *word == name)
            .map(|(_, thing)| *thing)
    }
}
/// The thing each key names: meow's `meow-char-thing-table` to begin with.
pub(in crate::interaction) struct Things(Vec<(char, Thing)>);
impl Default for Things {
    fn default() -> Self {
        Self(vec![
            ('r', Thing::Pair('(')),
            ('s', Thing::Pair('[')),
            ('c', Thing::Pair('{')),
            ('g', Thing::String),
            ('e', Thing::Symbol),
            ('w', Thing::Word),
            ('p', Thing::Paragraph),
            ('l', Thing::Line),
            ('b', Thing::Buffer),
        ])
    }
}
impl Things {
    pub fn get(&self, key: char) -> Option<Thing> {
        self.0
            .iter()
            .find(|(k, _)| *k == key)
            .map(|(_, thing)| *thing)
    }
    /// Makes `key` name `thing`, or nothing when `None`.
    pub fn set(&mut self, key: char, thing: Option<Thing>) {
        self.0.retain(|(k, _)| *k != key);
        if let Some(thing) = thing {
            self.0.push((key, thing));
        }
    }
}
/// What `C-u` has read so far.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(in crate::interaction) struct UniversalArgument {
    /// Digits were typed after it, so more extend them.
    pub digits: bool,
}
#[derive(Default)]
pub(in crate::interaction) struct State {
    /// The things `,` and `.` select, by key.
    pub things: Things,
    /// The prefix argument: `None` until `SPC 3` or `-` start one.
    pub count: Option<usize>,
    pub negative: bool,
    pub read: Option<Read>,
    /// The kind of the selection, while the selection is still that one.
    pub tag: Option<Tag>,
    pub history: Vec<(Selection, Option<Tag>)>,
    /// The column moving up and down keeps to, with the view and the head
    /// it left the caret at: once anything else moves the caret, such as
    /// `C-a`, a click or a search, the next move takes the caret's column.
    pub goal: Option<(LogicalColumn, ViewId, usize)>,
    pub last_find: Option<LastFind>,
    pub searches: Vec<SearchQuery>,
    pub insert_view: Option<ViewId>,
    pub replay: Replay,
    pub grab: Option<Grab>,
    /// The other selections of Beacon; the session holds the main one.
    pub beacons: Beacons,
    /// Insert was entered from Beacon: what is typed is recorded, to play
    /// at the other places when Esc ends it.
    pub beacon_insert: Option<BeaconEntry>,
    /// The shape of the other selections when they were derived.
    pub beacon_shape: BeaconShape,
    /// Keys waiting to play at the other places.
    pub play: Option<BeaconPlay>,
    /// The main selection while keys play at the other places.
    pub held: Option<Grab>,
    /// The last command, for `repeat`.
    pub last: Option<super::Command>,
    /// `C-u` was typed and its count is still open: digits and `-` typed
    /// next are the count's, and the first digit replaces the 4.
    pub universal: Option<UniversalArgument>,
    /// Where `recenter` put the caret's line last: middle, top, bottom.
    pub recenter_step: u8,
    /// The buffers `previous-buffer` and `next-buffer` go through, in the
    /// order of use when the first of them ran, and the place among them.
    pub buffer_cycle: Option<(Vec<crate::editor::DocumentId>, usize)>,
}
impl State {
    /// Forgets what was typed toward a command.
    pub fn clear(&mut self) {
        self.count = None;
        self.negative = false;
        self.read = None;
        self.universal = None;
    }
    pub fn active(&self) -> bool {
        self.count.is_some() || self.negative || self.read.is_some()
    }
    pub fn hint(&self) -> String {
        let mut keys = String::new();
        if self.negative {
            keys.push('-');
        }
        if let Some(count) = self.count {
            keys.push_str(&count.to_string());
        }
        match self.read {
            Some(Read::Find { till: false }) => keys.push('f'),
            Some(Read::Find { till: true }) => keys.push('t'),
            Some(Read::Thing { inner: true }) => keys.push(','),
            Some(Read::Thing { inner: false }) => keys.push('.'),
            None => {}
        }
        keys
    }
    /// The kind of `selection`, if it is still the one tagged. A character
    /// selection is a mark: it lasts while its anchor stays, whatever moves
    /// the head.
    pub fn tag(&self, selection: Selection) -> Option<Tag> {
        self.tag.filter(|tag| {
            tag.selection == selection
                || (tag.kind == Kind::Char && tag.selection.anchor == selection.anchor)
        })
    }
    pub fn search(&self) -> Option<&SearchQuery> {
        self.searches.last()
    }
    pub fn set_search(&mut self, query: SearchQuery) {
        if self.search().map(SearchQuery::text) != Some(query.text()) {
            self.searches.push(query);
        }
    }
    /// The count of the prefix argument and whether it is negative.
    pub fn take_prefix(&mut self) -> (usize, bool) {
        self.universal = None;
        let negative = std::mem::take(&mut self.negative);
        (self.count.take().unwrap_or(1), negative)
    }
}
