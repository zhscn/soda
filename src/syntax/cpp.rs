//! C++ highlighting from the editor's own lossless lexer, relexed
//! incrementally. Identifiers the lexer does not distinguish are classified
//! by a keyword table; preprocessor lines are macros, with `#include`
//! header names as strings.
use super::Category;
use crate::cpp::{Token, TokenKind as K, lex, relex};
use std::{ops::Range, sync::Arc};

const KEYWORDS: &[&str] = &[
    "alignas",
    "alignof",
    "and",
    "and_eq",
    "asm",
    "auto",
    "bitand",
    "bitor",
    "break",
    "catch",
    "co_await",
    "co_return",
    "co_yield",
    "compl",
    "concept",
    "const",
    "const_cast",
    "consteval",
    "constexpr",
    "constinit",
    "continue",
    "decltype",
    "delete",
    "dynamic_cast",
    "explicit",
    "export",
    "extern",
    "final",
    "friend",
    "goto",
    "import",
    "inline",
    "module",
    "mutable",
    "new",
    "noexcept",
    "not",
    "not_eq",
    "or",
    "or_eq",
    "override",
    "register",
    "reinterpret_cast",
    "requires",
    "sizeof",
    "static",
    "static_assert",
    "static_cast",
    "thread_local",
    "throw",
    "try",
    "typedef",
    "typeid",
    "typename",
    "using",
    "virtual",
    "volatile",
    "xor",
    "xor_eq",
];
const TYPES: &[&str] = &[
    "bool", "char", "char8_t", "char16_t", "char32_t", "double", "float", "int", "long", "short",
    "signed", "unsigned", "void", "wchar_t",
];
const CONSTANTS: &[&str] = &["true", "false", "nullptr", "this"];

fn token_category(kind: K, text: &str) -> Option<Category> {
    Some(match kind {
        K::LineComment | K::BlockComment => Category::Comment,
        K::StringLiteral | K::RawStringLiteral | K::CharacterLiteral => Category::String,
        K::Number => Category::Number,
        K::NamespaceKw
        | K::ClassKw
        | K::StructKw
        | K::EnumKw
        | K::UnionKw
        | K::SwitchKw
        | K::CaseKw
        | K::DefaultKw
        | K::PublicKw
        | K::ProtectedKw
        | K::PrivateKw
        | K::IfKw
        | K::ElseKw
        | K::ForKw
        | K::WhileKw
        | K::DoKw
        | K::ReturnKw
        | K::TemplateKw
        | K::OperatorKw => Category::Keyword,
        K::Identifier if KEYWORDS.contains(&text) => Category::Keyword,
        K::Identifier if TYPES.contains(&text) => Category::Type,
        K::Identifier if CONSTANTS.contains(&text) => Category::Constant,
        K::Invalid => Category::Invalid,
        K::Whitespace | K::Newline | K::Identifier | K::EndOfFile => return None,
        K::LBrace
        | K::RBrace
        | K::LParen
        | K::RParen
        | K::LBracket
        | K::RBracket
        | K::Comma
        | K::Semicolon
        | K::Colon
        | K::ColonColon
        | K::Period => return None,
        K::PreprocessorHash => Category::Macro,
        _ => Category::Operator,
    })
}

pub(crate) struct Lexed {
    source: Arc<str>,
    tokens: Vec<Token>,
}
impl Lexed {
    pub fn new(source: Arc<str>) -> Self {
        let tokens = lex(&source);
        Self { source, tokens }
    }
    pub fn update(&mut self, source: &Arc<str>) {
        if Arc::ptr_eq(&self.source, source) || *self.source == **source {
            return;
        }
        self.tokens = relex(&self.source, &self.tokens, source).tokens;
        self.source = source.clone();
    }
    /// Category runs within the byte range of one line.
    pub fn line(&self, line: Range<usize>) -> Vec<(Range<usize>, Category)> {
        let first = self.tokens.partition_point(|t| t.range.end <= line.start);
        let mut out: Vec<(Range<usize>, Category)> = vec![];
        // Inside `#include`, everything after the directive name is a path.
        let mut directive = None::<&str>;
        for token in &self.tokens[first..] {
            if token.range.start >= line.end {
                break;
            }
            let text = &self.source[token.range.clone()];
            let mut category = token_category(token.kind, text);
            if token.preprocessor && !token.kind.is_trivia() {
                category = match (directive, token.kind) {
                    (_, K::StringLiteral | K::CharacterLiteral | K::RawStringLiteral) => {
                        Some(Category::String)
                    }
                    (_, K::Number) => Some(Category::Number),
                    (None, K::Identifier) => {
                        directive = Some(text);
                        Some(Category::Macro)
                    }
                    (None, _) => Some(Category::Macro),
                    (Some("include" | "include_next" | "import"), _) => Some(Category::String),
                    // The rest of other directives reads as ordinary code.
                    (Some(_), _) => category,
                };
            }
            let Some(category) = category else {
                continue;
            };
            let start = token.range.start.max(line.start) - line.start;
            let end = token.range.end.min(line.end) - line.start;
            if start < end {
                match out.last_mut() {
                    Some((range, last)) if *last == category && range.end == start => {
                        range.end = end
                    }
                    _ => out.push((start..end, category)),
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn categories(source: &str, line: Range<usize>) -> Vec<(&str, Category)> {
        let lexed = Lexed::new(source.into());
        lexed
            .line(line.clone())
            .into_iter()
            .map(|(range, category)| {
                (
                    &source[line.start + range.start..line.start + range.end],
                    category,
                )
            })
            .collect()
    }
    #[test]
    fn tokens_and_preprocessor_lines_map_to_categories() {
        let source = "#include <vector>\nconst int x = 42; // hi\n";
        assert_eq!(
            categories(source, 0..17),
            [
                ("#include", Category::Macro),
                ("<vector>", Category::String)
            ]
        );
        assert_eq!(
            categories(source, 18..41),
            [
                ("const", Category::Keyword),
                ("int", Category::Type),
                ("=", Category::Operator),
                ("42", Category::Number),
                ("// hi", Category::Comment),
            ]
        );
    }
    #[test]
    fn block_comments_span_lines_and_relexing_follows_edits() {
        let mut lexed = Lexed::new("/* a\nb */ int\n".into());
        assert_eq!(
            lexed.line(5..13),
            [(0..4, Category::Comment), (5..8, Category::Type)]
        );
        lexed.update(&Arc::from("/  a\nb */ int\n"));
        assert_eq!(lexed.line(5..13)[0].1, Category::Operator);
    }
}
