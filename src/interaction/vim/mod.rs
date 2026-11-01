//! Vim input grammar and edit planning. Public commands are also mapping targets.
mod execute;
mod motion;
mod object;
mod parser;
mod replay;
pub(super) use execute::visual_selection;
pub use motion::Motion;
pub use object::Object;
pub(super) use parser::State;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Operator {
    Delete,
    Change,
    Yank,
    Indent,
    Outdent,
    Lower,
    Upper,
    ToggleCase,
}
/// What an operator acts on.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Target {
    /// Whole lines, as when the operator is doubled (`dd`, `>>`).
    Line,
    Motion(Motion),
    Object(Object),
}
#[derive(Clone, Copy, Debug)]
pub enum Insert {
    Before,
    After,
    Start,
    End,
    Below,
    Above,
    Leave,
}
#[derive(Clone, Copy, Debug)]
pub enum VimCommand {
    Move(Motion, usize),
    Operate(Operator, Target, usize),
    /// Selects a text object in Visual mode.
    Select(Object, usize),
    Insert(Insert),
    Put {
        before: bool,
        count: usize,
    },
    DeleteChar {
        backward: bool,
        count: usize,
    },
    ReplaceChar(char, usize),
    ToggleCaseChar(usize),
    Join(usize),
    EraseLineStart,
    EraseWord,
    Undo {
        redo: bool,
        count: usize,
    },
    Visual {
        linewise: bool,
    },
    /// Selects a range in Visual mode: `anchor` and `head` are between
    /// characters, as in a `Selection`, and `head` may come first.
    VisualRange {
        anchor: usize,
        head: usize,
    },
    /// Swaps the Visual anchor and head.
    VisualOther,
    Search {
        backward: bool,
    },
    RepeatSearch {
        reverse: bool,
        count: usize,
    },
    /// Searches for the whole word under the caret (`*`, `#`).
    SearchWord {
        backward: bool,
        count: usize,
    },
    /// Repeats the last change, with a new count if one is given.
    RepeatChange(Option<usize>),
    /// Starts recording keys into a register, or stops with `None`.
    Record(Option<char>),
    /// Replays a register's keys; `@` replays the last one played.
    Play(char, usize),
    SetMark(char),
    /// Jumps to a mark: exactly, or to its line's first non-blank.
    JumpMark {
        mark: char,
        exact: bool,
    },
    /// Moves half a page and scrolls the view by as much.
    /// Scrolls the caret's line to the middle of the window.
    Recenter,
    HalfPage {
        down: bool,
        count: usize,
    },
}
