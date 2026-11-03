//! The groups of a Rust text: brackets, generic argument lists and closure
//! parameters, each opener with its partner and every token with the group
//! it is in. Brackets that do not pair stay open, so that indentation still
//! sees an unfinished block, but answer as no group to commands.
use super::lexer::{Kind, Token, lex};
use crate::language::{Group, Item, ItemKind, Side};
use std::{ops::Range, sync::Arc};

/// Tokens a generic list or closure parameters may span.
const SPAN_LIMIT: usize = 256;

pub struct Structure {
    source: Arc<str>,
    pub tokens: Vec<Token>,
    /// The partner of each opener and closer that pairs.
    partner: Vec<Option<usize>>,
    /// The opener of the group each token is in, unpaired ones included.
    parent: Vec<Option<usize>>,
}

/// Words that never name a type or a value.
pub fn keyword(word: &str) -> bool {
    matches!(
        word,
        "as" | "async"
            | "await"
            | "break"
            | "const"
            | "continue"
            | "crate"
            | "dyn"
            | "else"
            | "enum"
            | "extern"
            | "fn"
            | "for"
            | "if"
            | "impl"
            | "in"
            | "let"
            | "loop"
            | "match"
            | "mod"
            | "move"
            | "mut"
            | "pub"
            | "ref"
            | "return"
            | "static"
            | "struct"
            | "trait"
            | "type"
            | "union"
            | "unsafe"
            | "use"
            | "where"
            | "while"
    )
}

impl Structure {
    pub fn new(source: Arc<str>) -> Self {
        let tokens = lex(&source);
        let mut structure = Self {
            partner: vec![None; tokens.len()],
            parent: vec![None; tokens.len()],
            source,
            tokens,
        };
        structure.pair_angles_and_bars();
        structure.nest();
        structure
    }
    pub fn source(&self) -> &Arc<str> {
        &self.source
    }
    pub fn text(&self, index: usize) -> &str {
        &self.source[self.tokens[index].range.clone()]
    }
    pub fn is(&self, index: usize, text: &str) -> bool {
        matches!(
            self.tokens[index].kind,
            Kind::Punct | Kind::Ident | Kind::Open | Kind::Close
        ) && self.text(index) == text
    }
    pub fn partner(&self, index: usize) -> Option<usize> {
        self.partner[index]
    }
    pub fn parent(&self, index: usize) -> Option<usize> {
        self.parent[index]
    }
    /// Whether a token opens a group, paired or not.
    pub fn opens(&self, index: usize) -> bool {
        self.tokens[index].kind == Kind::Open
            || self.partner[index].is_some_and(|partner| partner > index)
    }
    /// Whether a token closes a group that pairs.
    pub fn closes(&self, index: usize) -> bool {
        self.partner[index].is_some_and(|partner| partner < index)
    }
    /// The significant token before `index`, comments passed over.
    pub fn before(&self, index: usize) -> Option<usize> {
        (0..index).rev().find(|&i| !self.tokens[i].is_comment())
    }
    /// The first token that ends after `at`.
    pub fn first_after(&self, at: usize) -> usize {
        self.tokens.partition_point(|t| t.range.end <= at)
    }

    fn generic_opener(&self, index: usize) -> bool {
        let Some(previous) = self.before(index) else {
            return false;
        };
        let word = self.text(previous);
        match self.tokens[previous].kind {
            Kind::Punct => word == "::",
            Kind::Ident if matches!(word, "impl" | "for") => true,
            Kind::Ident if keyword(word) => false,
            Kind::Ident => {
                word.starts_with(|ch: char| ch.is_uppercase())
                    || self.before(previous).is_some_and(|declares| {
                        matches!(
                            self.text(declares),
                            "fn" | "struct" | "enum" | "trait" | "type" | "union"
                        )
                    })
            }
            _ => false,
        }
    }
    fn closure_opener(&self, index: usize) -> bool {
        match self.before(index) {
            None => true,
            Some(previous) => match self.tokens[previous].kind {
                Kind::Open => true,
                Kind::Punct => matches!(self.text(previous), "," | "=" | "=>" | ":" | ";"),
                Kind::Ident => matches!(self.text(previous), "move" | "return" | "break"),
                _ => false,
            },
        }
    }
    /// The partner of a `<` or `|` at `index`, found before anything that
    /// cannot be inside a type or parameter list.
    fn span_end(&self, index: usize, angle: bool) -> Option<usize> {
        let mut depth = 0usize;
        let mut angles = 0usize;
        let end = self.tokens.len().min(index + SPAN_LIMIT);
        for i in index + 1..end {
            let token = &self.tokens[i];
            match token.kind {
                // A block after `a < b` ends a condition; const generic
                // blocks are rare enough to give up.
                Kind::Open if angle && depth == 0 && self.text(i) == "{" => return None,
                Kind::Open => depth += 1,
                Kind::Close if depth == 0 => return None,
                Kind::Close => depth -= 1,
                Kind::Punct if depth == 0 => match self.text(i) {
                    ";" | "&&" | "||" | "=>" => return None,
                    "<" if angle => angles += 1,
                    ">" if angle && angles == 0 => return Some(i),
                    ">" if angle => angles -= 1,
                    "|" if !angle => return Some(i),
                    _ => {}
                },
                _ => {}
            }
        }
        None
    }
    /// A `|` after `{` or `,` may lead a pattern in a match arm rather than
    /// open a closure: the arrow of the arm follows.
    fn leads_pattern(&self, index: usize, close: usize) -> bool {
        let Some(previous) = self.before(index) else {
            return false;
        };
        if !matches!(self.text(previous), "{" | ",") {
            return false;
        }
        let mut depth = 0usize;
        for i in close + 1..self.tokens.len().min(close + SPAN_LIMIT) {
            match self.tokens[i].kind {
                Kind::Open => depth += 1,
                Kind::Close if depth == 0 => return false,
                Kind::Close => depth -= 1,
                Kind::Punct if depth == 0 => match self.text(i) {
                    "=>" => return true,
                    "," | ";" => return false,
                    _ => {}
                },
                _ => {}
            }
        }
        false
    }
    fn pair_angles_and_bars(&mut self) {
        for index in 0..self.tokens.len() {
            if self.tokens[index].kind != Kind::Punct || self.partner[index].is_some() {
                continue;
            }
            let close = match self.text(index) {
                "<" if self.generic_opener(index) => self.span_end(index, true),
                "|" if self.closure_opener(index) => self
                    .span_end(index, false)
                    .filter(|&close| !self.leads_pattern(index, close)),
                _ => None,
            };
            if let Some(close) = close.filter(|&close| self.partner[close].is_none()) {
                self.partner[index] = Some(close);
                self.partner[close] = Some(index);
            }
        }
    }
    /// Pairs brackets and gives every token its group. A closer that does
    /// not match the innermost opener closes the nearest one it matches,
    /// leaving those inside unpaired; one that matches none is text.
    fn nest(&mut self) {
        let mut open: Vec<usize> = vec![];
        for index in 0..self.tokens.len() {
            let kind = self.tokens[index].kind;
            let closes_angle = kind == Kind::Punct && self.closes(index);
            if kind == Kind::Close || closes_angle {
                let wanted = if closes_angle {
                    self.partner[index]
                } else {
                    let closer = self.text(index).chars().next();
                    open.iter().rev().copied().find(|&o| {
                        self.tokens[o].kind == Kind::Open
                            && closer == self.text(o).chars().next().map(mirror)
                    })
                };
                if let Some(opener) = wanted.filter(|o| open.contains(o)) {
                    while let Some(inner) = open.pop() {
                        if inner == opener {
                            break;
                        }
                        // An angle or bar pair cut by a stray bracket is
                        // no pair.
                        if let Some(partner) = self.partner[inner].take() {
                            self.partner[partner] = None;
                        }
                    }
                    self.parent[index] = open.last().copied();
                    self.partner[index] = Some(opener);
                    self.partner[opener] = Some(index);
                    continue;
                }
                if closes_angle {
                    // Its opener was cut off; the token is an operator.
                    self.partner[index] = None;
                }
            }
            self.parent[index] = open.last().copied();
            if kind == Kind::Open || (kind == Kind::Punct && self.partner[index].is_some()) {
                open.push(index);
            }
        }
        for opener in open {
            if let Some(partner) = self.partner[opener].take() {
                self.partner[partner] = None;
            }
        }
    }

    fn group(&self, open: usize) -> Option<Group> {
        let close = self.partner[open].filter(|&close| close > open)?;
        Some(Group {
            open: self.tokens[open].range.clone(),
            close: self.tokens[close].range.clone(),
        })
    }
    /// The innermost group, paired or not, that a position is inside.
    pub fn context(&self, at: usize) -> Option<usize> {
        let index = self.first_after(at);
        if let Some(token) = self.tokens.get(index)
            && token.range.start < at
        {
            return self.parent[index];
        }
        let previous = index.checked_sub(1)?;
        if self.opens(previous) {
            Some(previous)
        } else {
            self.parent[previous]
        }
    }
    pub fn enclosing(&self, at: usize) -> Option<Group> {
        let mut group = self.context(at);
        while let Some(open) = group {
            if let Some(found) = self.group(open)
                && found.open.end <= at
                && at <= found.close.start
            {
                return Some(found);
            }
            group = self.parent[open];
        }
        None
    }
    pub fn item(&self, at: usize, side: Side) -> Option<Item> {
        let limits = self.enclosing(at).map_or(0..self.source.len(), |group| {
            group.open.end..group.close.start
        });
        let order: Box<dyn Iterator<Item = usize>> = match side {
            Side::After => Box::new(self.first_after(at)..self.tokens.len()),
            Side::Before => {
                Box::new((0..self.tokens.partition_point(|t| t.range.start < at)).rev())
            }
        };
        for index in order {
            let token = &self.tokens[index];
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
            if span.is_empty() {
                continue;
            }
            let group = |range: Range<usize>| Item {
                range,
                kind: ItemKind::Group,
            };
            return Some(match token.kind {
                Kind::LineComment | Kind::BlockComment => Item {
                    range: span,
                    kind: ItemKind::Comment,
                },
                Kind::Str | Kind::Char => Item {
                    range: span,
                    kind: ItemKind::Literal,
                },
                Kind::Ident | Kind::Number | Kind::Lifetime => Item {
                    range: span,
                    kind: ItemKind::Atom,
                },
                Kind::Open if side == Side::After => group(self.group(index)?.range()),
                Kind::Close if side == Side::Before => {
                    group(self.group(self.partner[index]?)?.range())
                }
                Kind::Open | Kind::Close => return None,
                Kind::Punct => match self.partner[index] {
                    Some(close) if side == Side::After && close > index => {
                        group(self.group(index)?.range())
                    }
                    Some(open) if side == Side::Before && open < index => {
                        group(self.group(open)?.range())
                    }
                    _ => continue,
                },
            });
        }
        None
    }
}

fn mirror(open: char) -> char {
    match open {
        '(' => ')',
        '[' => ']',
        _ => '}',
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn groups(source: &str) -> Vec<&str> {
        let structure = Structure::new(Arc::from(source));
        (0..structure.tokens.len())
            .filter_map(|i| structure.group(i))
            .map(|g| &source[g.range()])
            .collect()
    }
    #[test]
    fn generics_and_closures_are_groups_and_comparisons_are_not() {
        assert_eq!(
            groups("let v: Vec<HashMap<K, V>> = a < b;"),
            ["<HashMap<K, V>>", "<K, V>"]
        );
        assert_eq!(groups("x.collect::<Vec<_>>()"), ["<Vec<_>>", "<_>", "()"]);
        assert_eq!(groups("fn f<T: Into<u8>>(x: T) {}")[0], "<T: Into<u8>>");
        assert_eq!(groups("if a < b && c > d {}"), ["{}"]);
        assert_eq!(groups("f(|a, b| a | b)"), ["(|a, b| a | b)", "|a, b|"]);
        assert_eq!(groups("let f = move |x: u8| x;"), ["|x: u8|"]);
        assert_eq!(groups("match x { | A | B => 1 }"), ["{ | A | B => 1 }"]);
        assert_eq!(groups("Some(a) | None"), ["(a)"]);
        assert_eq!(
            groups("Box<dyn Fn(u8) -> u8>"),
            ["<dyn Fn(u8) -> u8>", "(u8)"]
        );
    }
    #[test]
    fn unpaired_brackets_are_no_group_but_hold_what_follows() {
        let source = "fn f() {\n    g(a\n}\n";
        let structure = Structure::new(Arc::from(source));
        assert_eq!(groups(source), ["()", "{\n    g(a\n}"]);
        let a = source.find('a').unwrap();
        let open = structure.context(a).unwrap();
        assert_eq!(structure.text(open), "(");
        assert_eq!(
            &source[structure.enclosing(a).unwrap().range()],
            "{\n    g(a\n}"
        );
    }
}
