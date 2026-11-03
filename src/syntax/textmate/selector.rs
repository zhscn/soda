//! Scope selectors of injections, as vscode-textmate's `matcher.ts` parses
//! them: `L:a.b c - d, R:(e | f)`. A comma separates selectors, each with
//! its own priority; spaces chain descendants, `-` negates, `|` and `,`
//! inside parentheses are alternatives.

#[derive(Debug)]
pub(super) enum Matcher {
    /// Scopes that occur in this order, not necessarily adjacent.
    Path(Vec<Box<str>>),
    Not(Box<Matcher>),
    All(Vec<Matcher>),
    Any(Vec<Matcher>),
}

/// Whether an injection is tried before the rule's own patterns when both
/// match at the same position (`L:`), or after them (none or `R:`).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(super) enum Priority {
    Left,
    Normal,
    Right,
}

impl Matcher {
    /// `scopes` runs from the outermost scope to the innermost.
    pub fn matches(&self, scopes: &[&str]) -> bool {
        match self {
            Matcher::Path(path) => {
                let mut rest = scopes.iter();
                path.iter()
                    .all(|want| rest.any(|scope| scope_matches(scope, want)))
            }
            Matcher::Not(inner) => !inner.matches(scopes),
            Matcher::All(all) => all.iter().all(|m| m.matches(scopes)),
            Matcher::Any(any) => any.iter().any(|m| m.matches(scopes)),
        }
    }
}
/// `a.b` matches `a.b` and `a.b.c`, not `a.bc`.
fn scope_matches(scope: &str, want: &str) -> bool {
    scope
        .strip_prefix(want)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
}

fn identifier(token: &str) -> bool {
    token
        .chars()
        .next()
        .is_some_and(|c| c.is_alphanumeric() || c == '_' || c == '.' || c == ':')
}
fn tokens(selector: &str) -> Vec<&str> {
    let word = |c: char| c.is_alphanumeric() || c == '_' || c == '.' || c == ':';
    let mut out = vec![];
    let mut index = 0;
    let bytes = selector.as_bytes();
    while index < selector.len() {
        let rest = &selector[index..];
        let first = rest.chars().next().unwrap();
        let length = if bytes.len() > index + 1
            && matches!(bytes[index], b'L' | b'R')
            && bytes[index + 1] == b':'
        {
            2
        } else if word(first) {
            rest.find(|c: char| !(word(c) || c == '-'))
                .unwrap_or(rest.len())
        } else if ",|-()".contains(first) {
            1
        } else {
            index += first.len_utf8();
            continue;
        };
        out.push(&rest[..length]);
        index += length;
    }
    out
}

struct Parser<'a> {
    tokens: Vec<&'a str>,
    next: usize,
}
impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&'a str> {
        self.tokens.get(self.next).copied()
    }
    fn operand(&mut self) -> Option<Matcher> {
        let token = self.peek()?;
        if token == "-" {
            self.next += 1;
            return Some(Matcher::Not(Box::new(self.operand()?)));
        }
        if token == "(" {
            self.next += 1;
            let inner = self.alternatives();
            if self.peek() == Some(")") {
                self.next += 1;
            }
            return Some(inner);
        }
        if !identifier(token) {
            return None;
        }
        let mut path = vec![];
        while let Some(token) = self.peek().filter(|t| identifier(t)) {
            path.push(token.into());
            self.next += 1;
        }
        Some(Matcher::Path(path))
    }
    fn conjunction(&mut self) -> Option<Matcher> {
        let mut all = vec![];
        while let Some(matcher) = self.operand() {
            all.push(matcher);
        }
        (!all.is_empty()).then_some(Matcher::All(all))
    }
    fn alternatives(&mut self) -> Matcher {
        let mut any = vec![];
        while let Some(matcher) = self.conjunction() {
            any.push(matcher);
            if !matches!(self.peek(), Some("|" | ",")) {
                break;
            }
            while matches!(self.peek(), Some("|" | ",")) {
                self.next += 1;
            }
        }
        Matcher::Any(any)
    }
}

/// The selectors in `selector`, each with its priority. A selector that
/// cannot be parsed matches nothing.
pub(super) fn parse(selector: &str) -> Vec<(Matcher, Priority)> {
    let mut parser = Parser {
        tokens: tokens(selector),
        next: 0,
    };
    let mut out = vec![];
    while parser.peek().is_some() {
        let priority = match parser.peek() {
            Some("L:") => Priority::Left,
            Some("R:") => Priority::Right,
            _ => Priority::Normal,
        };
        if priority != Priority::Normal {
            parser.next += 1;
        }
        let matcher = parser.conjunction().unwrap_or(Matcher::Any(vec![]));
        out.push((matcher, priority));
        if parser.peek() != Some(",") {
            break;
        }
        parser.next += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    fn matches(selector: &str, scopes: &str) -> Vec<bool> {
        let scopes: Vec<&str> = scopes.split_whitespace().collect();
        parse(selector)
            .iter()
            .map(|(m, _)| m.matches(&scopes))
            .collect()
    }
    #[test]
    fn paths_match_in_order_by_dotted_prefix() {
        let scopes = "source.ts meta.block.ts comment.block.documentation.ts";
        assert_eq!(matches("comment.block.documentation", scopes), [true]);
        assert_eq!(matches("source.ts comment", scopes), [true]);
        assert_eq!(matches("comment source.ts", scopes), [false]);
        assert_eq!(matches("comment.blo", scopes), [false]);
        assert_eq!(matches("source.ts - comment", scopes), [false]);
        assert_eq!(matches("source.ts - string", scopes), [true]);
        assert_eq!(matches("(string | comment) - meta.x", scopes), [true]);
        assert_eq!(matches("string, meta.block", scopes), [false, true]);
    }
    #[test]
    fn each_selector_has_its_priority() {
        let priorities: Vec<Priority> = parse("L:comment, string, R:meta - x")
            .into_iter()
            .map(|(_, p)| p)
            .collect();
        assert_eq!(
            priorities,
            [Priority::Left, Priority::Normal, Priority::Right]
        );
    }
}
