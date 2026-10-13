//! Read-only formatting structure over a lossless token stream. Node and token
//! indices are local to one analysis; this is not a complete C++ AST.
use super::{ParserOptions, Token, TokenKind as K};
use std::{ops::Range, sync::Arc};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NodeKind {
    TranslationUnit,
    PreprocessorDirective,
    NamespaceDecl,
    NamespaceBody,
    ClassDecl,
    ClassBody,
    AccessSpecifierLabel,
    OpaqueDeclaration,
    FunctionDefinition,
    CtorInitializerList,
    CtorInitializer,
    ParenGroup,
    BracketGroup,
    BraceGroup,
    TemplateArgumentList,
    CompoundStatement,
    IfStatement,
    ElseClause,
    ForStatement,
    WhileStatement,
    DoStatement,
    SwitchStatement,
    CaseSection,
    CaseLabel,
    PPReopenedScope,
    MissingToken,
    Error,
}
impl NodeKind {
    pub(crate) fn is_group(self) -> bool {
        matches!(
            self,
            Self::ParenGroup | Self::BracketGroup | Self::BraceGroup | Self::TemplateArgumentList
        )
    }
    pub(crate) fn is_layout_boundary(self) -> bool {
        matches!(
            self,
            Self::TranslationUnit
                | Self::CompoundStatement
                | Self::NamespaceBody
                | Self::ClassBody
                | Self::CaseSection
        )
    }
}
use NodeKind as N;
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Node {
    pub kind: N,
    pub tokens: Range<usize>,
    pub parent: Option<usize>,
    pub children: Vec<usize>,
    pub incomplete: bool,
    pub reclassified: bool,
    pub whitespace_sensitive: bool,
    pub extern_linkage: bool,
    pub expected: Option<K>,
}
#[derive(Clone, Debug)]
pub struct SyntaxTree {
    pub(crate) source: Arc<str>,
    pub(crate) parser_options: ParserOptions,
    pub(crate) tokens: Vec<Token>,
    pub(crate) nodes: Vec<Node>,
    pub(super) token_owners: Vec<usize>,
    pub(super) macro_blocks: Vec<Option<super::macros::BlockMacro>>,
}
impl SyntaxTree {
    pub fn parser_options(&self) -> &ParserOptions {
        &self.parser_options
    }
    pub fn tokens(&self) -> &[Token] {
        &self.tokens
    }
    pub fn nodes(&self) -> &[Node] {
        &self.nodes
    }
    pub fn source(&self) -> &str {
        &self.source
    }
    pub fn range(&self, id: usize) -> Range<usize> {
        let n = &self.nodes[id];
        let start = self.tokens[n.tokens.start.min(self.tokens.len() - 1)]
            .range
            .start;
        let end = if n.tokens.is_empty() {
            start
        } else {
            self.tokens[n.tokens.end - 1].range.end
        };
        start..end
    }
    pub fn node_at(&self, offset: usize) -> usize {
        let mut id = 0;
        loop {
            let next = self.nodes[id]
                .children
                .iter()
                .rev()
                .copied()
                .find(|&child| {
                    let r = self.range(child);
                    self.nodes[child].kind != N::MissingToken
                        && r.start <= offset
                        && offset <= r.end
                });
            match next {
                Some(child) => id = child,
                None => return id,
            }
        }
    }
    pub(super) fn index_tokens(&mut self) {
        fn visit(nodes: &[Node], owners: &mut [usize], id: usize) {
            let node = &nodes[id];
            let mut cursor = node.tokens.start;
            for &child in &node.children {
                let range = &nodes[child].tokens;
                if range.is_empty() {
                    continue;
                }
                owners[cursor..range.start].fill(id);
                visit(nodes, owners, child);
                cursor = range.end;
            }
            owners[cursor..node.tokens.end].fill(id);
        }
        self.token_owners.resize(self.tokens.len(), 0);
        visit(&self.nodes, &mut self.token_owners, 0);
    }

    /// The innermost structure owning this token, within this analysis only.
    pub(crate) fn token_owner(&self, token: usize) -> usize {
        self.token_owners[token]
    }

    pub(crate) fn format_kind(&self, token: usize) -> K {
        if let Some(block) = self.macro_blocks[token] {
            return block.kind();
        }
        let node = &self.nodes[self.token_owner(token)];
        if token == node.tokens.start {
            match node.kind {
                N::IfStatement => return K::IfKw,
                N::ForStatement => return K::ForKw,
                _ => {}
            }
        }
        self.tokens[token].kind
    }

    pub(crate) fn has_direct_comma(&self, id: usize) -> bool {
        self.nodes[id]
            .tokens
            .clone()
            .any(|token| self.tokens[token].kind == K::Comma && self.token_owner(token) == id)
    }

    pub(crate) fn is_constructor_colon(&self, token: usize) -> bool {
        if self.tokens[token].kind != K::Colon {
            return false;
        }
        let node = &self.nodes[self.token_owner(token)];
        node.kind == N::CtorInitializerList
            || node
                .parent
                .is_some_and(|p| self.nodes[p].kind == N::CtorInitializerList)
    }

    pub(crate) fn ancestor(&self, mut id: usize, kind: N) -> Option<usize> {
        loop {
            if self.nodes[id].kind == kind {
                return Some(id);
            }
            id = self.nodes[id].parent?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cpp::{parse, parse_with_options};

    #[test]
    fn indexed_owners_are_innermost_nonempty_structures() {
        for source in [
            "class C { public: C() : x_(f(1, 2)), y_{3} {} };",
            "void f() { call([&](int x) { return g(x); }, h(1, 2)); }",
            "template<class T> void f(T x) { if (x) g(x); else h(); }",
            "#if X\nvoid f() {\n#else\nvoid g() {\n#endif\nf(1, 2);\n}",
        ] {
            for end in (0..=source.len()).filter(|&end| source.is_char_boundary(end)) {
                let tree = parse(&source[..end]);
                for (token, t) in tree.tokens.iter().enumerate() {
                    if t.kind.is_trivia() || t.kind == K::EndOfFile {
                        continue;
                    }
                    let expected = tree
                        .nodes
                        .iter()
                        .enumerate()
                        .rev()
                        .find(|(_, node)| node.tokens.contains(&token))
                        .unwrap()
                        .0;
                    assert_eq!(
                        tree.token_owner(token),
                        expected,
                        "{}: {:?}",
                        &source[..end],
                        t
                    );
                }
            }
        }
    }

    #[test]
    fn formatting_facts_keep_nested_groups_and_macro_controls_distinct() {
        let options = ParserOptions {
            loop_macros: vec!["EACH".into()],
            conditional_macros: vec!["WHEN".into()],
            ..ParserOptions::default()
        };
        let tree = parse_with_options(
            "EACH(x) f(g(1, 2)); WHEN(x) yes(); C::C() : x_(f(1, 2)) {}",
            &options,
        );
        let index = |spelling: &str| {
            tree.tokens
                .iter()
                .position(|t| &tree.source[t.range.clone()] == spelling)
                .unwrap()
        };
        assert_eq!(tree.format_kind(index("EACH")), K::ForKw);
        assert_eq!(tree.format_kind(index("WHEN")), K::IfKw);
        let parens: Vec<_> = tree
            .nodes
            .iter()
            .enumerate()
            .filter(|(_, n)| n.kind == N::ParenGroup)
            .collect();
        assert!(parens.iter().any(|(id, _)| tree.has_direct_comma(*id)));
        let outer = tree
            .nodes
            .iter()
            .enumerate()
            .find(|(id, n)| {
                n.kind == N::ParenGroup && tree.source[tree.range(*id)].starts_with("(g(")
            })
            .unwrap()
            .0;
        assert!(!tree.has_direct_comma(outer));
        assert!(
            tree.tokens
                .iter()
                .enumerate()
                .any(|(i, _)| tree.is_constructor_colon(i))
        );
    }
}
