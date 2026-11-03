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

impl Category {
    pub const ALL: [Self; 23] = [
        Self::Comment,
        Self::String,
        Self::Escape,
        Self::Number,
        Self::Constant,
        Self::Keyword,
        Self::Operator,
        Self::Type,
        Self::Function,
        Self::Parameter,
        Self::Namespace,
        Self::Macro,
        Self::Tag,
        Self::Attribute,
        Self::Heading,
        Self::Emphasis,
        Self::Strong,
        Self::Link,
        Self::Inserted,
        Self::Deleted,
        Self::Changed,
        Self::Invalid,
        Self::Match,
    ];
    /// The category's name, as faces spell it after `syntax.`.
    pub fn name(self) -> &'static str {
        match self {
            Self::Comment => "comment",
            Self::String => "string",
            Self::Escape => "escape",
            Self::Number => "number",
            Self::Constant => "constant",
            Self::Keyword => "keyword",
            Self::Operator => "operator",
            Self::Type => "type",
            Self::Function => "function",
            Self::Parameter => "parameter",
            Self::Namespace => "namespace",
            Self::Macro => "macro",
            Self::Tag => "tag",
            Self::Attribute => "attribute",
            Self::Heading => "heading",
            Self::Emphasis => "emphasis",
            Self::Strong => "strong",
            Self::Link => "link",
            Self::Inserted => "inserted",
            Self::Deleted => "deleted",
            Self::Changed => "changed",
            Self::Invalid => "invalid",
            Self::Match => "match",
        }
    }
    /// The category of a name, as `name` gives them; how semantic tokens
    /// name what they show.
    pub fn named(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|category| category.name() == name)
    }
}

/// Category runs of one line, as byte ranges relative to the line start.
pub type Runs = Vec<(Range<usize>, Category)>;

#[cfg(test)]
mod tests;
