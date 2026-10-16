//! Vim input grammar and edit planning. Public commands are also mapping targets.
mod execute;
mod motion;
mod parser;
pub use motion::Motion;
pub(super) use parser::State;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Operator {
    Delete,
    Change,
    Yank,
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
    Operate(Operator, Option<Motion>, usize),
    Insert(Insert),
    Put { before: bool, count: usize },
    DeleteChar { backward: bool, count: usize },
    ReplaceChar(char, usize),
    EraseLineStart,
    EraseWord,
    Undo { redo: bool, count: usize },
    Visual { linewise: bool },
    Search { backward: bool },
    RepeatSearch { reverse: bool, count: usize },
}
