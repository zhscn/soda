//! Syntax categories of text. C++ uses the editor's own lexer; other
//! languages use bundled TextMate grammars. Results are byte ranges with a
//! fixed set of categories, which themes color without knowing any grammar.
//! This layer computes from text alone and knows nothing above the core.
pub(crate) mod bundled;
pub(crate) mod cpp;
mod scope;
mod textmate;

pub use textmate::Tokens;

use std::ops::Range;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Category {
    Comment,
    String,
    Escape,
    Number,
    Constant,
    Keyword,
    Operator,
    Type,
    Function,
    Parameter,
    Namespace,
    Macro,
    Tag,
    Attribute,
    Heading,
    Emphasis,
    Strong,
    Link,
    Inserted,
    Deleted,
    Changed,
    Invalid,
    /// What a search found, in its results.
    Match,
}

/// Category runs of one line, as byte ranges relative to the line start.
pub type Runs = Vec<(Range<usize>, Category)>;

#[cfg(test)]
mod tests;
