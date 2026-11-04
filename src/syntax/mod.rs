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

/// What a range of text is. Dotted categories refine the one before the
/// last dot and inherit its style where a theme gives them none, as Emacs
/// faces do with `:inherit`: `function.call` looks like `function` until a
/// theme tells calls apart. `ALL` lists a parent before its children.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Category {
    Comment,
    /// Documentation comments
    CommentDoc,
    String,
    Escape,
    Number,
    Constant,
    /// Constants of the language, such as `true` and `nullptr`
    ConstantBuiltin,
    Keyword,
    Operator,
    /// Punctuation; plain unless a theme colors it
    Punctuation,
    /// Brackets, braces and parentheses
    PunctuationBracket,
    /// Commas, semicolons and colons
    PunctuationDelimiter,
    Type,
    /// Types of the language, such as `int`
    TypeBuiltin,
    Function,
    /// A function's name where it is declared or defined
    FunctionDefinition,
    /// A function's name where it is called or referred to
    FunctionCall,
    /// Functions of the language or its standard library
    FunctionBuiltin,
    /// Variables; plain unless a theme colors them
    Variable,
    /// A variable's name where it is declared
    VariableDefinition,
    /// Members and fields; plain unless a theme colors them
    Property,
    /// A member's name where it is declared
    PropertyDefinition,
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
    pub const ALL: [Self; 36] = [
        Self::Comment,
        Self::CommentDoc,
        Self::String,
        Self::Escape,
        Self::Number,
        Self::Constant,
        Self::ConstantBuiltin,
        Self::Keyword,
        Self::Operator,
        Self::Punctuation,
        Self::PunctuationBracket,
        Self::PunctuationDelimiter,
        Self::Type,
        Self::TypeBuiltin,
        Self::Function,
        Self::FunctionDefinition,
        Self::FunctionCall,
        Self::FunctionBuiltin,
        Self::Variable,
        Self::VariableDefinition,
        Self::Property,
        Self::PropertyDefinition,
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
            Self::CommentDoc => "comment.doc",
            Self::String => "string",
            Self::Escape => "escape",
            Self::Number => "number",
            Self::Constant => "constant",
            Self::ConstantBuiltin => "constant.builtin",
            Self::Keyword => "keyword",
            Self::Operator => "operator",
            Self::Punctuation => "punctuation",
            Self::PunctuationBracket => "punctuation.bracket",
            Self::PunctuationDelimiter => "punctuation.delimiter",
            Self::Type => "type",
            Self::TypeBuiltin => "type.builtin",
            Self::Function => "function",
            Self::FunctionDefinition => "function.definition",
            Self::FunctionCall => "function.call",
            Self::FunctionBuiltin => "function.builtin",
            Self::Variable => "variable",
            Self::VariableDefinition => "variable.definition",
            Self::Property => "property",
            Self::PropertyDefinition => "property.definition",
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
    /// The category this one refines, whose style it inherits.
    pub fn parent(self) -> Option<Self> {
        Some(match self {
            Self::CommentDoc => Self::Comment,
            Self::ConstantBuiltin => Self::Constant,
            Self::PunctuationBracket => Self::Punctuation,
            Self::PunctuationDelimiter => Self::Punctuation,
            Self::TypeBuiltin => Self::Type,
            Self::FunctionDefinition => Self::Function,
            Self::FunctionCall => Self::Function,
            Self::FunctionBuiltin => Self::Function,
            Self::VariableDefinition => Self::Variable,
            Self::PropertyDefinition => Self::Property,
            _ => return None,
        })
    }
    /// The category at the top of this one's line of parents.
    pub fn root(self) -> Self {
        let mut category = self;
        while let Some(parent) = category.parent() {
            category = parent;
        }
        category
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
