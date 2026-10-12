//! Language-neutral suggestions in the request snapshot's UTF-8 coordinates.
mod whitespace;
use crate::core::Change;
pub use whitespace::{TabPolicy, WhitespacePolicy, materialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IndentTrigger {
    Enter,
    Typed(char),
    Reindent,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IndentRequest {
    pub line: usize,
    pub position: usize,
    pub trigger: IndentTrigger,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NewlineIndent {
    Verbatim,
    Inherit { preserve_suffix: bool },
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IndentAdvice {
    Set {
        prefix: String,
        auxiliary: Option<Change>,
    },
    Preserve {
        newline: NewlineIndent,
    },
    Unavailable,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct EnterAdvice {
    pub expand_pair: bool,
    pub verbatim: bool,
}
