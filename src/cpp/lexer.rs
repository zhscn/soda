use std::ops::Range;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TokenKind {
    Whitespace,
    Newline,
    LineComment,
    BlockComment,
    Identifier,
    Number,
    StringLiteral,
    RawStringLiteral,
    CharacterLiteral,
    NamespaceKw,
    ClassKw,
    StructKw,
    EnumKw,
    UnionKw,
    SwitchKw,
    CaseKw,
    DefaultKw,
    PublicKw,
    ProtectedKw,
    PrivateKw,
    IfKw,
    ElseKw,
    ForKw,
    WhileKw,
    DoKw,
    ReturnKw,
    TemplateKw,
    OperatorKw,
    LBrace,
    RBrace,
    LParen,
    RParen,
    LBracket,
    RBracket,
    Less,
    Greater,
    Colon,
    ColonColon,
    Comma,
    Semicolon,
    Arrow,
    Equals,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Exclaim,
    Amp,
    Pipe,
    Caret,
    Tilde,
    Question,
    Period,
    Ellipsis,
    PlusPlus,
    MinusMinus,
    AmpAmp,
    PipePipe,
    EqualEqual,
    ExclaimEqual,
    LessEqual,
    GreaterEqual,
    Spaceship,
    LessLess,
    GreaterGreater,
    PeriodStar,
    ArrowStar,
    PlusEqual,
    MinusEqual,
    StarEqual,
    SlashEqual,
    PercentEqual,
    AmpEqual,
    PipeEqual,
    CaretEqual,
    LessLessEqual,
    GreaterGreaterEqual,
    Punctuator,
    PreprocessorHash,
    Invalid,
    EndOfFile,
}

impl TokenKind {
    pub fn is_trivia(self) -> bool {
        matches!(
            self,
            Self::Whitespace | Self::Newline | Self::LineComment | Self::BlockComment
        )
    }
    pub(crate) fn sync(self) -> bool {
        use TokenKind::*;
        matches!(
            self,
            NamespaceKw
                | ClassKw
                | StructKw
                | EnumKw
                | UnionKw
                | SwitchKw
                | IfKw
                | ElseKw
                | ForKw
                | WhileKw
                | DoKw
                | CaseKw
                | DefaultKw
                | PublicKw
                | ProtectedKw
                | PrivateKw
                | PreprocessorHash
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Token {
    pub kind: TokenKind,
    pub range: Range<usize>,
    pub preprocessor: bool,
    pub unterminated: bool,
    pub escaped_newline: bool,
}

/// Lossless lexer: every input byte belongs to exactly one token. Unterminated
/// literals and comments retain their original ranges for editing protection.
pub fn lex(source: &str) -> Vec<Token> {
    Scanner::new(source, 0).collect()
}

// Lossless tokens are contiguous and ordered, so offset queries are binary
// searches; only the trivia run next to the offset is scanned.
fn significant(token: &Token) -> bool {
    !token.kind.is_trivia() && token.kind != TokenKind::EndOfFile
}
/// The token containing `offset`.
pub(crate) fn token_at(tokens: &[Token], offset: usize) -> Option<&Token> {
    tokens
        .get(tokens.partition_point(|t| t.range.end <= offset))
        .filter(|t| t.range.start <= offset)
}
/// The token split by `offset`, including an unterminated token ending there.
pub(crate) fn spanning(tokens: &[Token], offset: usize) -> Option<&Token> {
    tokens
        .get(tokens.partition_point(|t| t.range.end < offset))
        .filter(|t| {
            t.range.start < offset
                && (offset < t.range.end || (t.unterminated && offset == t.range.end))
        })
}
/// Index of the last significant token ending at or before `offset`.
pub(crate) fn significant_before(tokens: &[Token], offset: usize) -> Option<usize> {
    (0..tokens.partition_point(|t| t.range.end <= offset))
        .rev()
        .find(|&i| significant(&tokens[i]))
}
/// Index of the first significant token starting at or after `offset`.
pub(crate) fn significant_after(tokens: &[Token], offset: usize) -> Option<usize> {
    (tokens.partition_point(|t| t.range.start < offset)..tokens.len())
        .find(|&i| significant(&tokens[i]))
}

/// Scanning can resume immediately after a standalone newline token: strings,
/// comments and escaped newlines cannot contain such a checkpoint.
struct Scanner<'a> {
    source: &'a str,
    position: usize,
    line_start: bool,
    preprocessor: bool,
    finished: bool,
}
impl<'a> Scanner<'a> {
    fn new(source: &'a str, position: usize) -> Self {
        Self {
            source,
            position,
            line_start: true,
            preprocessor: false,
            finished: false,
        }
    }
}
impl Iterator for Scanner<'_> {
    type Item = Token;
    fn next(&mut self) -> Option<Token> {
        use TokenKind::*;
        if self.finished {
            return None;
        }
        let source = self.source;
        let b = source.as_bytes();
        let mut p = self.position;
        if p == b.len() {
            self.finished = true;
            return Some(Token {
                kind: EndOfFile,
                range: p..p,
                preprocessor: false,
                unterminated: false,
                escaped_newline: false,
            });
        }
        let mut line_start = self.line_start;
        let mut pp = self.preprocessor;
        let start = p;
        let mut unterminated = false;
        let mut escaped = false;
        let mut kind;
        if b[p] == b'\\' && (b.get(p + 1) == Some(&b'\n') || b.get(p + 1..p + 3) == Some(b"\r\n")) {
            p += if b[p + 1] == b'\r' { 3 } else { 2 };
            kind = Whitespace;
            escaped = true;
        } else if b[p] == b'\n' || b[p] == b'\r' {
            p += if b[p] == b'\r' && b.get(p + 1) == Some(&b'\n') {
                2
            } else {
                1
            };
            kind = Newline;
        } else if b[p].is_ascii_whitespace() {
            p += 1;
            while p < b.len() && matches!(b[p], b' ' | b'\t' | 0x0b | 0x0c) {
                p += 1;
            }
            kind = Whitespace;
        } else if b.get(p..p + 2) == Some(b"//") {
            p += 2;
            while p < b.len() {
                if b[p] == b'\\' && b.get(p + 1) == Some(&b'\n') {
                    p += 2;
                } else if b[p] == b'\\' && b.get(p + 1..p + 3) == Some(b"\r\n") {
                    p += 3;
                } else if matches!(b[p], b'\r' | b'\n') {
                    break;
                } else {
                    p += 1;
                }
            }
            kind = LineComment;
        } else if b.get(p..p + 2) == Some(b"/*") {
            p += 2;
            if let Some(end) = source[p..].find("*/") {
                p += end + 2;
            } else {
                p = b.len();
                unterminated = true;
            }
            kind = BlockComment;
        } else if let Some((prefix, raw, quote)) = literal_prefix(&source[p..]) {
            p += prefix;
            if raw {
                let delim_start = p;
                while p < b.len()
                    && b[p] != b'('
                    && p - delim_start <= 16
                    && !b[p].is_ascii_whitespace()
                    && !matches!(b[p], b')' | b'\\' | b'"')
                {
                    p += 1;
                }
                if b.get(p) == Some(&b'(') && p - delim_start <= 16 {
                    let closing = format!("){}\"", &source[delim_start..p]);
                    p += 1;
                    if let Some(end) = source[p..].find(&closing) {
                        p += end + closing.len();
                    } else {
                        p = b.len();
                        unterminated = true;
                    }
                    kind = RawStringLiteral;
                } else {
                    p = start + prefix;
                    unterminated = true;
                    while p < b.len() {
                        if b[p] == b'"' {
                            p += 1;
                            unterminated = false;
                            break;
                        }
                        if matches!(b[p], b'\r' | b'\n') {
                            break;
                        }
                        if b[p] == b'\\' && p + 1 < b.len() {
                            p += 2;
                        } else {
                            p += 1;
                        }
                    }
                    kind = StringLiteral;
                }
            } else {
                unterminated = true;
                while p < b.len() {
                    if b[p] == quote {
                        p += 1;
                        unterminated = false;
                        break;
                    }
                    if matches!(b[p], b'\r' | b'\n') {
                        break;
                    }
                    if b[p] == b'\\' && p + 1 < b.len() {
                        p += if b.get(p + 1..p + 3) == Some(b"\r\n") {
                            3
                        } else {
                            2
                        };
                    } else {
                        p += 1;
                    }
                }
                kind = if quote == b'\'' {
                    CharacterLiteral
                } else {
                    StringLiteral
                };
            }
            if !unterminated && matches!(kind, RawStringLiteral | CharacterLiteral | StringLiteral)
            {
                while p < b.len() && ident_continue(b[p]) {
                    p += 1;
                }
            }
        } else if b[p].is_ascii_digit()
            || (b[p] == b'.' && b.get(p + 1).is_some_and(u8::is_ascii_digit))
        {
            p += 1;
            while p < b.len() {
                if ident_continue(b[p])
                    || matches!(b[p], b'.' | b'\'')
                    || (matches!(b[p], b'+' | b'-')
                        && matches!(b[p - 1], b'e' | b'E' | b'p' | b'P'))
                {
                    p += 1;
                } else {
                    break;
                }
            }
            kind = Number;
        } else if ident_start(b[p]) {
            p += 1;
            while p < b.len() && ident_continue(b[p]) {
                p += 1;
            }
            kind = keyword(&source[start..p]);
        } else {
            let operators = [
                ("<=>", Spaceship),
                (">>=", GreaterGreaterEqual),
                ("<<=", LessLessEqual),
                ("->*", ArrowStar),
                ("...", Ellipsis),
                ("::", ColonColon),
                ("->", Arrow),
                ("++", PlusPlus),
                ("--", MinusMinus),
                ("&&", AmpAmp),
                ("||", PipePipe),
                ("==", EqualEqual),
                ("!=", ExclaimEqual),
                ("<=", LessEqual),
                (">=", GreaterEqual),
                ("<<", LessLess),
                (">>", GreaterGreater),
                (".*", PeriodStar),
                ("+=", PlusEqual),
                ("-=", MinusEqual),
                ("*=", StarEqual),
                ("/=", SlashEqual),
                ("%=", PercentEqual),
                ("&=", AmpEqual),
                ("|=", PipeEqual),
                ("^=", CaretEqual),
                ("##", Punctuator),
                ("<%", LBrace),
                ("%>", RBrace),
                ("<:", LBracket),
                (":>", RBracket),
                ("%:", PreprocessorHash),
            ];
            if let Some((spelling, k)) = operators
                .into_iter()
                .find(|(s, _)| source[p..].starts_with(s))
            {
                p += spelling.len();
                kind = k;
            } else {
                kind = match b[p] {
                    b'{' => LBrace,
                    b'}' => RBrace,
                    b'(' => LParen,
                    b')' => RParen,
                    b'[' => LBracket,
                    b']' => RBracket,
                    b'<' => Less,
                    b'>' => Greater,
                    b':' => Colon,
                    b',' => Comma,
                    b';' => Semicolon,
                    b'=' => Equals,
                    b'+' => Plus,
                    b'-' => Minus,
                    b'*' => Star,
                    b'/' => Slash,
                    b'%' => Percent,
                    b'!' => Exclaim,
                    b'&' => Amp,
                    b'|' => Pipe,
                    b'^' => Caret,
                    b'~' => Tilde,
                    b'?' => Question,
                    b'.' => Period,
                    b'#' if line_start => PreprocessorHash,
                    b'#' => Punctuator,
                    _ => Invalid,
                };
                p += source[p..].chars().next().unwrap().len_utf8();
            }
        }
        if kind == PreprocessorHash && !line_start {
            kind = Punctuator;
        }
        if kind == PreprocessorHash && line_start {
            pp = true;
        }
        let token = Token {
            kind,
            range: start..p,
            preprocessor: pp,
            unterminated,
            escaped_newline: escaped,
        };
        if kind == Newline {
            pp = false;
            line_start = true;
        } else if !kind.is_trivia() {
            line_start = false;
        }
        self.position = p;
        self.line_start = line_start;
        self.preprocessor = pp;
        Some(token)
    }
}

pub(crate) struct Relexed {
    pub tokens: Vec<Token>,
    pub scanned: Range<usize>,
    pub unchanged_prefix: usize,
    pub unchanged_suffix: usize,
}

/// The common unchanged suffix and equal neutral lexer states establish
/// convergence. No checkpoint inside a multiline token or line splice is used.
pub(crate) fn relex(old: &str, tokens: &[Token], source: &str) -> Relexed {
    let prefix = old
        .bytes()
        .zip(source.bytes())
        .take_while(|(a, b)| a == b)
        .count();
    let suffix = old.as_bytes()[prefix..]
        .iter()
        .rev()
        .zip(source.as_bytes()[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let keep = tokens
        .iter()
        .rposition(|t| t.kind == TokenKind::Newline && t.range.end < prefix)
        .map_or(0, |i| i + 1);
    let restart = if keep == 0 {
        0
    } else {
        tokens[keep - 1].range.end
    };
    let mut result = Vec::with_capacity(tokens.len());
    result.extend_from_slice(&tokens[..keep]);
    let mut stop = source.len();
    for token in Scanner::new(source, restart) {
        let converged =
            token.kind == TokenKind::Newline && token.range.end >= source.len() - suffix;
        let end = token.range.end;
        result.push(token);
        if converged {
            let old_end = old.len() - (source.len() - end);
            let index = tokens.partition_point(|t| t.range.end <= old_end);
            if index > 0
                && tokens[index - 1].kind == TokenKind::Newline
                && tokens[index - 1].range.end == old_end
            {
                for token in &tokens[index..] {
                    let mut token = token.clone();
                    token.range = (source.len() - (old.len() - token.range.start))
                        ..(source.len() - (old.len() - token.range.end));
                    result.push(token);
                }
                stop = end;
                break;
            }
        }
    }
    Relexed {
        tokens: result,
        scanned: restart..stop,
        unchanged_prefix: prefix,
        unchanged_suffix: suffix,
    }
}

fn ident_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_' || b >= 0x80
}
fn ident_continue(b: u8) -> bool {
    ident_start(b) || b.is_ascii_digit()
}
fn literal_prefix(s: &str) -> Option<(usize, bool, u8)> {
    for prefix in ["u8", "u", "U", "L", ""] {
        let Some(rest) = s.strip_prefix(prefix) else {
            continue;
        };
        // This loop must try every prefix, including the empty one.
        if rest.starts_with("R\"") {
            return Some((prefix.len() + 2, true, b'"'));
        }
        if rest.starts_with('"') {
            return Some((prefix.len() + 1, false, b'"'));
        }
        if rest.starts_with('\'') {
            return Some((prefix.len() + 1, false, b'\''));
        }
    }
    None
}
fn keyword(s: &str) -> TokenKind {
    use TokenKind::*;
    match s {
        "namespace" => NamespaceKw,
        "class" => ClassKw,
        "struct" => StructKw,
        "enum" => EnumKw,
        "union" => UnionKw,
        "switch" => SwitchKw,
        "case" => CaseKw,
        "default" => DefaultKw,
        "public" => PublicKw,
        "protected" => ProtectedKw,
        "private" => PrivateKw,
        "if" => IfKw,
        "else" => ElseKw,
        "for" => ForKw,
        "while" => WhileKw,
        "do" => DoKw,
        "return" => ReturnKw,
        "template" => TemplateKw,
        "operator" => OperatorKw,
        _ => Identifier,
    }
}
