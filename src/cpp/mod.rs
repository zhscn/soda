mod expression;
mod indent;
mod indent_rules;
mod lexer;
mod parser;
mod rules;
mod service;
mod style;
mod syntax;

pub use crate::{core::column_width, language::materialize};
pub use indent::{IndentDecision, IndentRole, compute_indent};
pub use lexer::{Token, TokenKind, lex};
pub use parser::{parse, parse_snapshot, parse_snapshot_with_options, parse_with_options};
pub use service::CppSession;
pub use style::{
    AccessIndent, ConstructorInitializers, CppStyle, NamespaceIndentation, PPDirectiveIndent,
    StyleError, TabPolicy,
};

pub use rules::{
    ConstructorPolicy, CppRules, DirectivePolicy, ExpressionPolicy, ExternIndentation,
    InitializerLayout, InitializerPolicy, OperandAlignment, ParserOptions, StructurePolicy,
    WhitespacePolicy,
};

pub use syntax::{Node, NodeKind, SyntaxTree};

pub(crate) use style::{validate_offset, validate_width};
