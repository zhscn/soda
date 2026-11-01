//! Bracket groups and items of the syntax tree. The tree tells `<` from a
//! comparison and leaves unfinished groups marked, which text alone cannot.
use super::{NodeKind as N, SyntaxTree, Token, TokenKind as K};
use crate::language::{Group, Item, ItemKind, Side};
use std::ops::Range;

impl SyntaxTree {
    fn significant(&self, range: Range<usize>) -> Option<(usize, usize)> {
        let tokens = &self.tokens[range.clone()];
        let visible = |t: &Token| !t.kind.is_trivia() && t.kind != K::EndOfFile;
        let first = tokens.iter().position(visible)?;
        let last = tokens.iter().rposition(visible)?;
        Some((range.start + first, range.start + last))
    }
    /// The delimiters of a finished bracket node. Two lists that `>>` closes
    /// share that token: the inner takes its first half.
    fn group(&self, id: usize) -> Option<Group> {
        let node = &self.nodes[id];
        if node.incomplete {
            return None;
        }
        let (first, last) = self.significant(node.tokens.clone())?;
        let (open, close) = (&self.tokens[first], &self.tokens[last]);
        let matched = match node.kind {
            N::ParenGroup => open.kind == K::LParen && close.kind == K::RParen,
            N::BracketGroup => open.kind == K::LBracket && close.kind == K::RBracket,
            N::BraceGroup | N::CompoundStatement | N::NamespaceBody | N::ClassBody => {
                open.kind == K::LBrace && close.kind == K::RBrace
            }
            N::TemplateArgumentList => {
                open.kind == K::Less && matches!(close.kind, K::Greater | K::GreaterGreater)
            }
            _ => false,
        };
        if !matched || first == last || self.splits_conditional(first..last) {
            return None;
        }
        let mut closing = close.range.clone();
        if close.kind == K::GreaterGreater {
            let inner = node.parent.is_some_and(|parent| {
                self.nodes[parent].kind == N::TemplateArgumentList
                    && self
                        .significant(self.nodes[parent].tokens.clone())
                        .is_some_and(|(_, end)| end == last)
            });
            if inner {
                closing.end -= 1;
            } else {
                closing.start += 1;
            }
        }
        Some(Group {
            open: open.range.clone(),
            close: closing,
        })
    }
    /// Whether tokens hold only part of an `#if`, so that the brackets at
    /// their ends may not pair up under every configuration.
    fn splits_conditional(&self, tokens: Range<usize>) -> bool {
        let mut depth = 0usize;
        for index in tokens {
            if self.tokens[index].kind != K::PreprocessorHash {
                continue;
            }
            match super::preprocessor::keyword(&self.source, &self.tokens, index) {
                Some("if" | "ifdef" | "ifndef") => depth += 1,
                Some("else" | "elif" | "elifdef" | "elifndef") if depth == 0 => return true,
                Some("endif") if depth == 0 => return true,
                Some("endif") => depth -= 1,
                _ => {}
            }
        }
        depth != 0
    }
    fn enclosing_node(&self, at: usize) -> Option<(usize, Group)> {
        let mut id = Some(self.node_at(at));
        while let Some(node) = id {
            if let Some(group) = self.group(node)
                && group.open.end <= at
                && at <= group.close.start
            {
                return Some((node, group));
            }
            id = self.nodes[node].parent;
        }
        None
    }
    pub(crate) fn enclosing(&self, at: usize) -> Option<Group> {
        self.enclosing_node(at).map(|(_, group)| group)
    }
    /// The group a token delimits on the given side, among the nodes that
    /// start or end at it.
    fn delimited(&self, token: usize, matches: impl Fn(&Group) -> bool) -> Option<Group> {
        let span = self.tokens[token].range.clone();
        let mut id = Some(self.token_owner(token));
        while let Some(node) = id {
            if let Some(group) = self.group(node)
                && matches(&group)
            {
                return Some(group);
            }
            let range = self.range(node);
            if range.start < span.start && range.end > span.end {
                return None;
            }
            id = self.nodes[node].parent;
        }
        None
    }
    pub(crate) fn item(&self, at: usize, side: Side) -> Option<Item> {
        let limits = self
            .enclosing_node(at)
            .map_or(0..self.source.len(), |(_, group)| {
                group.open.end..group.close.start
            });
        let first = self.tokens.partition_point(|t| t.range.end <= at);
        let order: Box<dyn Iterator<Item = usize>> = match side {
            Side::After => Box::new(first..self.tokens.len()),
            Side::Before => Box::new((0..first.min(self.tokens.len() - 1) + 1).rev()),
        };
        for index in order {
            let token = &self.tokens[index];
            // The part of the token on the asked side, within the group.
            let span = match side {
                Side::After => token.range.start.max(at)..token.range.end.min(limits.end),
                Side::Before => token.range.start.max(limits.start)..token.range.end.min(at),
            };
            let outside = match side {
                Side::After => span.start >= limits.end,
                Side::Before => span.end <= limits.start,
            };
            if outside {
                return None;
            }
            if token.kind == K::EndOfFile {
                match side {
                    Side::After => return None,
                    Side::Before => continue,
                }
            }
            if span.is_empty() || matches!(token.kind, K::Whitespace | K::Newline) {
                continue;
            }
            if token.preprocessor {
                let mut id = self.token_owner(index);
                while self.nodes[id].kind != N::PreprocessorDirective {
                    id = self.nodes[id].parent?;
                }
                let whole = self.range(id);
                return Some(Item {
                    range: match side {
                        Side::After => whole.start.max(at)..whole.end,
                        Side::Before => whole.start..whole.end.min(at),
                    },
                    kind: ItemKind::Directive,
                });
            }
            return Some(match token.kind {
                K::LineComment | K::BlockComment => Item {
                    range: span,
                    kind: ItemKind::Comment,
                },
                K::StringLiteral | K::RawStringLiteral | K::CharacterLiteral => Item {
                    range: span,
                    kind: ItemKind::Literal,
                },
                K::LParen | K::LBracket | K::LBrace if side == Side::After => {
                    let group = self.delimited(index, |g| g.open.start == token.range.start)?;
                    Item {
                        range: group.range(),
                        kind: ItemKind::Group,
                    }
                }
                K::RParen | K::RBracket | K::RBrace if side == Side::Before => {
                    let group = self.delimited(index, |g| g.close.end == token.range.end)?;
                    Item {
                        range: group.range(),
                        kind: ItemKind::Group,
                    }
                }
                K::LParen | K::LBracket | K::LBrace | K::RParen | K::RBracket | K::RBrace => {
                    return None;
                }
                K::Less if side == Side::After => {
                    match self.delimited(index, |g| g.open.start == token.range.start) {
                        Some(group) => Item {
                            range: group.range(),
                            kind: ItemKind::Group,
                        },
                        None => continue,
                    }
                }
                K::Greater | K::GreaterGreater if side == Side::Before => {
                    match self.delimited(index, |g| g.close.end == span.end) {
                        Some(group) => Item {
                            range: group.range(),
                            kind: ItemKind::Group,
                        },
                        None => continue,
                    }
                }
                _ if self.source[token.range.clone()]
                    .starts_with(|ch: char| ch.is_alphanumeric() || ch == '_') =>
                {
                    Item {
                        range: span,
                        kind: ItemKind::Atom,
                    }
                }
                _ => continue,
            });
        }
        None
    }
}
