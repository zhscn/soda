//! The modal editing model: selections first, then what acts on them, after
//! meow. Normal moves and selects, Insert types, Beacon holds many selections
//! inside a grabbed range. Each key is one command; a selection remembers the
//! kind of thing it covers, so that the next command can extend it.
mod beacon;
mod execute;
mod replay;
pub mod text;
use crate::{
    application::ViewId,
    core::{LogicalColumn, Selection},
    editor::{DocumentPosition, search::SearchQuery},
};
pub(super) use beacon::BeaconEdit;
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
    Insert(Entry),
    Leave,
    Kill,
    Change,
    Delete,
    Save,
    Yank,
    /// Puts the clipboard in place of the selection.
    Replace,
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
    EraseWord,
    EraseLineStart,
    /// Starts the selection at the caret for `C-Space`.
    SetMark,
    /// Enters Beacon inside the selection, or leaves a marker to swap with.
    Grab,
    SwapGrab,
    MacroStart,
    /// Ends recording, or plays the last macro.
    MacroEnd,
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
    /// Words for the end of a line, until the next key.
    Indicator(usize, String),
    /// A key on the row of a tree.
    Tree(TreeAction),
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
#[derive(Default)]
pub(in crate::interaction) struct State {
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
    pub beacons: Vec<Grab>,
    /// Insert was entered from Beacon, and goes back there.
    pub beacon_insert: bool,
    /// The undo depth when recording began: a macro played on beacons
    /// undoes as one step with its recording.
    pub macro_depth: usize,
    /// The last command, for `repeat`.
    pub last: Option<super::Command>,
}
impl State {
    /// Forgets what was typed toward a command.
    pub fn clear(&mut self) {
        self.count = None;
        self.negative = false;
        self.read = None;
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
        let negative = std::mem::take(&mut self.negative);
        (self.count.take().unwrap_or(1), negative)
    }
}
