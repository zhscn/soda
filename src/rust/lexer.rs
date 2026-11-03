//! Rust tokens, enough for structure: comments and literals whatever their
//! prefix or nesting, lifetimes told from character literals, and the
//! punctuation that structure and indentation look at. Whitespace makes no
//! token.
use std::ops::Range;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
    LineComment,
    BlockComment,
    /// A string of any prefix: plain, byte, C or raw.
    Str,
    /// A character or byte literal.
    Char,
    Lifetime,
    Ident,
    Number,
    Open,
    Close,
    Punct,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Token {
    pub kind: Kind,
    pub range: Range<usize>,
    /// A comment or literal the text ends inside.
    pub unterminated: bool,
}
impl Token {
    pub fn is_comment(&self) -> bool {
        matches!(self.kind, Kind::LineComment | Kind::BlockComment)
    }
}

/// Punctuation of more than one character. `<` and `>` stand alone, so
/// that `>>` can close two generic lists; so do the operators made of them.
const PUNCTUATION: &[&str] = &[
    "...", "..=", "::", "->", "=>", "..", "&&", "||", "==", "!=", "+=", "-=", "*=", "/=", "%=",
    "^=", "&=", "|=",
];

fn ident_start(ch: char) -> bool {
    ch == '_' || ch.is_alphabetic()
}
fn ident_continue(ch: char) -> bool {
    ch == '_' || ch.is_alphanumeric()
}

struct Lexer<'a> {
    source: &'a str,
    at: usize,
}
impl Lexer<'_> {
    fn peek(&self, ahead: usize) -> Option<char> {
        let bytes = self.source.as_bytes();
        // ASCII, the common case, without decoding.
        match bytes.get(self.at..self.at + ahead + 1) {
            Some(run) if run.is_ascii() => Some(run[ahead] as char),
            _ => self.source[self.at..].chars().nth(ahead),
        }
    }
    fn rest(&self) -> &str {
        &self.source[self.at..]
    }
    fn bump(&mut self) -> Option<char> {
        let ch = self.peek(0)?;
        self.at += ch.len_utf8();
        Some(ch)
    }
    fn eat_while(&mut self, keep: impl Fn(char) -> bool) {
        while self.peek(0).is_some_and(&keep) {
            self.bump();
        }
    }
    /// The rest of a quoted literal after its opening quote; whether it
    /// closed.
    fn quoted(&mut self, quote: char) -> bool {
        while let Some(ch) = self.bump() {
            match ch {
                '\\' => {
                    self.bump();
                }
                _ if ch == quote => return true,
                _ => {}
            }
        }
        false
    }
    /// The rest of a raw string after its `r`: hashes, a quote, the text and
    /// the same hashes. `None` when no quote follows the hashes.
    fn raw(&mut self) -> Option<bool> {
        let hashes = self.rest().bytes().take_while(|b| *b == b'#').count();
        if self.rest().as_bytes().get(hashes) != Some(&b'"') {
            return None;
        }
        self.at += hashes + 1;
        let closing = format!("\"{}", "#".repeat(hashes));
        match self.rest().find(&closing) {
            Some(end) => {
                self.at += end + closing.len();
                Some(true)
            }
            None => {
                self.at = self.source.len();
                Some(false)
            }
        }
    }
    /// The rest of a block comment after its `/*`, nested ones included.
    fn block_comment(&mut self) -> bool {
        let mut depth = 1;
        while let Some(ch) = self.bump() {
            match ch {
                '/' if self.peek(0) == Some('*') => {
                    self.bump();
                    depth += 1;
                }
                '*' if self.peek(0) == Some('/') => {
                    self.bump();
                    depth -= 1;
                    if depth == 0 {
                        return true;
                    }
                }
                _ => {}
            }
        }
        false
    }
    /// After a `'`: a character literal, a lifetime or a lone quote.
    fn quote(&mut self) -> (Kind, bool) {
        match (self.peek(0), self.peek(1)) {
            (Some('\\'), _) => (Kind::Char, self.quoted('\'')),
            (Some(ch), Some('\'')) if ch != '\n' => {
                self.bump();
                self.bump();
                (Kind::Char, true)
            }
            (Some(ch), _) if ident_start(ch) => {
                self.eat_while(ident_continue);
                (Kind::Lifetime, true)
            }
            _ => (Kind::Punct, true),
        }
    }
    fn next(&mut self) -> Option<Token> {
        self.eat_while(char::is_whitespace);
        let start = self.at;
        let first = self.bump()?;
        let mut unterminated = false;
        let kind = match first {
            '/' if self.peek(0) == Some('/') => {
                self.eat_while(|ch| ch != '\n');
                // A CRLF line ends before its CR.
                if self.source[..self.at].ends_with('\r') {
                    self.at -= 1;
                }
                Kind::LineComment
            }
            '/' if self.peek(0) == Some('*') => {
                self.bump();
                unterminated = !self.block_comment();
                Kind::BlockComment
            }
            '"' => {
                unterminated = !self.quoted('"');
                Kind::Str
            }
            '\'' => {
                let (kind, closed) = self.quote();
                unterminated = !closed;
                kind
            }
            '(' | '[' | '{' => Kind::Open,
            ')' | ']' | '}' => Kind::Close,
            ch if ch.is_ascii_digit() => {
                let mut previous = ch;
                while let Some(ch) = self.peek(0) {
                    let exponent = matches!(previous, 'e' | 'E')
                        && matches!(ch, '+' | '-')
                        && !self.source[start..self.at].starts_with("0x");
                    let fraction = ch == '.'
                        && previous != '.'
                        && self.peek(1).is_some_and(|next| next.is_ascii_digit());
                    if !(ident_continue(ch) || exponent || fraction) {
                        break;
                    }
                    previous = ch;
                    self.bump();
                }
                Kind::Number
            }
            ch if ident_start(ch) => {
                // Prefixed literals and raw identifiers start like words.
                let prefix = self.source[start..self.at].len();
                let word_then =
                    |lexer: &Self, ch| lexer.at - start == prefix && lexer.peek(0) == Some(ch);
                match first {
                    'b' | 'c' if word_then(self, '"') => {
                        self.bump();
                        unterminated = !self.quoted('"');
                        Kind::Str
                    }
                    'b' if word_then(self, '\'') => {
                        self.bump();
                        unterminated = !self.quoted('\'');
                        Kind::Char
                    }
                    'b' | 'c'
                        if word_then(self, 'r') && matches!(self.peek(1), Some('"' | '#')) =>
                    {
                        let at = self.at;
                        self.bump();
                        match self.raw() {
                            Some(closed) => {
                                unterminated = !closed;
                                Kind::Str
                            }
                            None => {
                                self.at = at;
                                self.eat_while(ident_continue);
                                Kind::Ident
                            }
                        }
                    }
                    'r' if matches!(self.peek(0), Some('"' | '#')) => match self.raw() {
                        Some(closed) => {
                            unterminated = !closed;
                            Kind::Str
                        }
                        None => {
                            // `r#ident`
                            if self.peek(0) == Some('#') && self.peek(1).is_some_and(ident_start) {
                                self.bump();
                            }
                            self.eat_while(ident_continue);
                            Kind::Ident
                        }
                    },
                    _ => {
                        self.eat_while(ident_continue);
                        Kind::Ident
                    }
                }
            }
            _ => {
                let rest = &self.source[start..];
                if let Some(punct) = PUNCTUATION.iter().find(|p| rest.starts_with(**p)) {
                    self.at = start + punct.len();
                }
                Kind::Punct
            }
        };
        Some(Token {
            kind,
            range: start..self.at,
            unterminated,
        })
    }
}

pub fn lex(source: &str) -> Vec<Token> {
    let mut lexer = Lexer { source, at: 0 };
    std::iter::from_fn(|| lexer.next()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(source: &str) -> Vec<(Kind, &str)> {
        lex(source)
            .into_iter()
            .map(|t| (t.kind, &source[t.range]))
            .collect()
    }
    #[test]
    fn lifetimes_are_not_character_literals() {
        use Kind::*;
        assert_eq!(
            kinds("fn f<'a>(x: &'a str) -> char { 'x' }"),
            [
                (Ident, "fn"),
                (Ident, "f"),
                (Punct, "<"),
                (Lifetime, "'a"),
                (Punct, ">"),
                (Open, "("),
                (Ident, "x"),
                (Punct, ":"),
                (Punct, "&"),
                (Lifetime, "'a"),
                (Ident, "str"),
                (Close, ")"),
                (Punct, "->"),
                (Ident, "char"),
                (Open, "{"),
                (Char, "'x'"),
                (Close, "}"),
            ]
        );
        assert_eq!(kinds("'\\n' '\\u{1F600}' b'{'")[2], (Char, "b'{'"));
        assert_eq!(kinds("'outer: loop")[0], (Lifetime, "'outer"));
        assert_eq!(kinds("'{'")[0], (Char, "'{'"));
    }
    #[test]
    fn literals_and_comments_hide_brackets() {
        use Kind::*;
        assert_eq!(kinds(r###"r#"a "{" b"#"###), [(Str, r###"r#"a "{" b"#"###)]);
        assert_eq!(
            kinds("br\"{\" c\"}\" b\"(\""),
            [(Str, "br\"{\""), (Str, "c\"}\""), (Str, "b\"(\""),]
        );
        assert_eq!(
            kinds("/* a /* { */ } */ x"),
            [(BlockComment, "/* a /* { */ } */"), (Ident, "x"),]
        );
        assert_eq!(kinds("r#type br"), [(Ident, "r#type"), (Ident, "br")]);
        let open = lex("\"abc\n{");
        assert!(open[0].unterminated);
        assert_eq!(kinds("// {\r\nx")[0], (LineComment, "// {"));
    }
    #[test]
    fn numbers_end_where_ranges_begin() {
        use Kind::*;
        assert_eq!(kinds("1..2"), [(Number, "1"), (Punct, ".."), (Number, "2")]);
        assert_eq!(kinds("1.5e-3f64")[0], (Number, "1.5e-3f64"));
        assert_eq!(kinds("x.0.1")[2], (Number, "0.1"));
    }
}
