//! Indentation in the block style rustfmt writes: a level inside each
//! group, closers back at the line of their opener, and a level more for a
//! line that continues the statement, argument or arm above it. Visual
//! alignment is never asked for, so a group's line and the start of the
//! unit a line belongs to decide everything.
use super::{
    lexer::Kind,
    structure::{Structure, keyword},
};
use crate::{
    core::Snapshot,
    language::{IndentAdvice, NewlineIndent, WhitespacePolicy, materialize},
};

/// Tokens that, first on a line after a block, continue the expression the
/// block ends rather than start a statement.
fn continues(structure: &Structure, index: usize) -> bool {
    let text = structure.text(index);
    match structure.tokens[index].kind {
        Kind::Close => true,
        Kind::Ident => matches!(text, "else" | "as"),
        Kind::Punct => matches!(
            text,
            "." | "?"
                | "&&"
                | "||"
                | "+"
                | "/"
                | "%"
                | "^"
                | "=="
                | "!="
                | ">"
                | "="
                | "+="
                | "-="
                | "*="
                | "/="
                | "%="
                | "^="
                | "&="
                | "|="
                | ";"
                | ","
                | "=>"
                | "|"
                | "->"
        ),
        _ => false,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Class {
    /// `.`, `?` or a closer.
    Chain,
    Binary,
    /// `if` of a match guard, or `where`.
    Guard,
    Operand,
}

struct Indenter<'a> {
    structure: &'a Structure,
    snapshot: &'a Snapshot,
    style: &'a WhitespacePolicy,
}
impl Indenter<'_> {
    fn column(&self, offset: usize) -> usize {
        let line = self.snapshot.line_of(offset).unwrap();
        let width = self.style.tab_width.get();
        self.snapshot
            .leading_whitespace(line)
            .unwrap()
            .chars()
            .fold(0, |column, ch| {
                if ch == '\t' {
                    column + width - column % width
                } else {
                    column + 1
                }
            })
    }
    /// The indentation of the line a token is on.
    fn line_of(&self, index: usize) -> usize {
        self.column(self.structure.tokens[index].range.start)
    }
    /// The token before `index` in the same group, comments passed over and
    /// a whole group at `index` taken as its opener; `None` at the group's
    /// start.
    fn previous(&self, index: usize, group: Option<usize>) -> Option<usize> {
        match self.structure.partner(index) {
            Some(open) if open < index => self.preceding(open, group),
            _ => self.preceding(index, group),
        }
    }
    /// The token before a position given as the index of the token after
    /// it, which may be the end.
    fn preceding(&self, mut i: usize, group: Option<usize>) -> Option<usize> {
        let s = self.structure;
        loop {
            i = i.checked_sub(1)?;
            if Some(i) == group {
                return None;
            }
            if s.parent(i) == group && !s.tokens[i].is_comment() {
                return Some(i);
            }
        }
    }
    /// Whether a `]` closes an attribute.
    fn attribute(&self, index: usize) -> bool {
        let s = self.structure;
        s.is(index, "]")
            && s.partner(index)
                .and_then(|open| s.before(open))
                .is_some_and(|before| {
                    s.is(before, "#")
                        || s.is(before, "!") && s.before(before).is_some_and(|b| s.is(b, "#"))
                })
    }
    /// Whether a unit ends after token `a` when `b` follows it; `b` is
    /// `None` on a line that holds nothing yet.
    fn separates(&self, a: usize, b: Option<usize>, list: bool) -> bool {
        let s = self.structure;
        s.is(a, ";")
            || list && s.is(a, ",")
            || self.attribute(a)
            || s.is(a, "}")
                && s.partner(a).is_some()
                // A guard after a struct pattern continues its arm.
                && !b.is_some_and(|b| continues(s, b) || list && s.is(b, "if"))
    }
    /// Whether the elements of a group are separated by commas, rather
    /// than being statements and items.
    fn list(&self, open: usize) -> bool {
        let s = self.structure;
        if !s.is(open, "{") {
            return true;
        }
        let group = s.parent(open);
        let immediate = self.previous(open, group);
        let mut at = immediate;
        let mut assigned = false;
        while let Some(i) = at {
            let text = s.text(i);
            match s.tokens[i].kind {
                Kind::Ident => match text {
                    "match" | "struct" | "enum" | "union" | "use" => return true,
                    // `if let Foo {` before its `=` is a pattern.
                    "let" if !assigned => return true,
                    "if" | "while" | "for" | "loop" | "else" | "fn" | "impl" | "trait" | "mod"
                    | "unsafe" | "async" | "extern" => return false,
                    _ => {}
                },
                Kind::Punct if text == "=" => assigned = true,
                Kind::Punct if matches!(text, ";" | "," | "=>") => break,
                Kind::Close if text == "}" => break,
                _ => {}
            }
            at = self.previous(i, group);
        }
        // A path before the brace makes a struct expression or pattern; a
        // nested `use` list or a map in a macro's arguments is a list too.
        // A macro's own braces hold anything, statements most often.
        let invoked = |i: usize| s.before(i).is_some_and(|b| s.is(b, "!"));
        match immediate {
            Some(i) => {
                let text = s.text(i);
                match s.tokens[i].kind {
                    Kind::Ident => (text == "Self" || !keyword(text)) && !invoked(i),
                    Kind::Punct => s.closes(i) && text == ">" || matches!(text, "::" | ":"),
                    _ => false,
                }
            }
            None => group.is_some_and(|g| !s.is(g, "{") && invoked(g)),
        }
    }
    /// The first token of the unit that `last` ends. A unit is a
    /// statement, an item, a list element or an arm; `else` after a block
    /// starts one of its own, so that a condition after `} else if`
    /// continues from that line.
    fn unit_start(&self, last: usize, group: Option<usize>, list: bool) -> usize {
        let s = self.structure;
        let mut start = last;
        // Past a block, `else` is inside an `if` used as a value.
        let mut crossed = s.is(last, "}");
        while let Some(before) = self.previous(start, group) {
            if self.separates(before, Some(start), list)
                || !crossed && s.is(start, "else") && s.is(before, "}")
                || s.is(before, "=>")
            {
                break;
            }
            crossed |= s.is(before, "}");
            start = before;
        }
        // A group starting the unit starts at its opener.
        match s.partner(start) {
            Some(open) if open < start => open,
            _ => start,
        }
    }
    /// The first token on the line of a token.
    fn lead(&self, index: usize) -> usize {
        let s = self.structure;
        let line = self.snapshot.line_of(s.tokens[index].range.start).unwrap();
        s.first_after(self.snapshot.line_start(line).unwrap())
    }
    /// Where a continuation line goes: after the lines that already
    /// continue the unit, as rustfmt writes them. A chain link lines up
    /// with the link or closer above it, a binary operator with the
    /// operator above it, and either goes a level in from an operand or a
    /// guard; the unit's first line counts as an operand.
    fn continuation(&self, first: Option<usize>, last: usize, start: usize, list: bool) -> usize {
        let s = self.structure;
        let width = self.style.indent_width;
        let unit = self.line_of(start);
        let class = |i: usize| match s.tokens[i].kind {
            Kind::Close => Class::Chain,
            Kind::Punct if matches!(s.text(i), "." | "?") => Class::Chain,
            Kind::Punct if !matches!(s.text(i), ";" | ",") && continues(s, i) => Class::Binary,
            Kind::Ident if matches!(s.text(i), "if" | "where") => Class::Guard,
            _ => Class::Operand,
        };
        if first.is_some_and(|first| s.is(first, "where")) {
            return unit;
        }
        // A block's brace or an `else` on a line of its own goes back to
        // the line of the keyword it belongs to; an arm's, to the arm.
        if first.is_some_and(|first| s.is(first, "{") || s.is(first, "else")) {
            if list {
                return unit;
            }
            let mut at = Some(last);
            while let Some(i) = at {
                if matches!(
                    s.text(i),
                    "if" | "while"
                        | "for"
                        | "match"
                        | "loop"
                        | "fn"
                        | "impl"
                        | "struct"
                        | "enum"
                        | "union"
                        | "trait"
                        | "mod"
                        | "unsafe"
                        | "where"
                ) && s.tokens[i].kind == Kind::Ident
                {
                    return self.line_of(i);
                }
                if i == start {
                    break;
                }
                at = self.previous(i, s.parent(last));
            }
            return unit;
        }
        let wanted = first.map(class);
        let start_line = self.snapshot.line_of(s.tokens[start].range.start);
        let group = s.parent(last);
        let mut seen = None;
        let mut at = Some(last);
        while let Some(i) = at {
            let line = self.snapshot.line_of(s.tokens[i].range.start);
            if line == start_line {
                break;
            }
            if seen != line {
                seen = line;
                let lead = self.lead(i);
                if s.parent(lead) == group || s.tokens[lead].kind == Kind::Close {
                    let column = self.line_of(lead);
                    match (wanted, class(lead)) {
                        (_, Class::Guard) | (Some(Class::Guard), _) => return column + width,
                        (Some(Class::Chain), Class::Chain) => return column,
                        (Some(Class::Chain), _) => return column + width,
                        (Some(Class::Binary), Class::Binary) => return column,
                        // An operand on a line of its own after `=` is
                        // what the operators continue.
                        (Some(Class::Binary), Class::Operand)
                            if self.previous(lead, group).is_some_and(|p| {
                                s.is(p, "=")
                                    && self.snapshot.line_of(s.tokens[p].range.start) == start_line
                            }) =>
                        {
                            return column + width;
                        }
                        (Some(Class::Binary), _) => {}
                        // An operand after a line ending in `=` or `where`.
                        _ if s.is(last, "=") || s.is(last, "where") => return column + width,
                        _ => return column,
                    }
                }
            }
            at = self.previous(i, group);
        }
        unit + width
    }
    fn indent(&self, line: usize) -> IndentAdvice {
        let s = self.structure;
        let start = self.snapshot.line_start(line).unwrap();
        let index = s.first_after(start);
        if let Some(token) = s.tokens.get(index)
            && token.range.start < start
        {
            return match token.kind {
                Kind::BlockComment => IndentAdvice::Preserve {
                    newline: NewlineIndent::Inherit {
                        preserve_suffix: true,
                    },
                },
                _ => IndentAdvice::Preserve {
                    newline: NewlineIndent::Verbatim,
                },
            };
        }
        let first = (index < s.tokens.len()
            && self.snapshot.line_of(s.tokens[index].range.start) == Some(line))
        .then_some(index);
        let group = s.context(start);
        let width = self.style.indent_width;
        let target = match first {
            // A closer goes back to the line of its opener.
            Some(first) if group.is_some() && s.partner(first) == group => {
                self.line_of(group.unwrap())
            }
            _ => {
                let inner = group.map_or(0, |open| self.line_of(open) + width);
                let list = group.is_some_and(|open| self.list(open));
                let last = self.preceding(index, group);
                match last {
                    // Alternatives of a pattern line up with its start.
                    Some(last)
                        if list
                            && group.is_some_and(|open| s.is(open, "{"))
                            && first.is_some_and(|first| s.is(first, "|"))
                            && !self.separates(last, first, list) =>
                    {
                        self.line_of(self.unit_start(last, group, list))
                    }
                    Some(last) if !self.separates(last, first, list) => {
                        self.continuation(first, last, self.unit_start(last, group, list), list)
                    }
                    _ => inner,
                }
            }
        };
        IndentAdvice::Set {
            prefix: materialize(target, 0, target, self.style),
            auxiliary: None,
        }
    }
}

pub fn indent(
    structure: &Structure,
    snapshot: &Snapshot,
    line: usize,
    style: &WhitespacePolicy,
) -> IndentAdvice {
    Indenter {
        structure,
        snapshot,
        style,
    }
    .indent(line)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn style() -> WhitespacePolicy {
        WhitespacePolicy {
            indent_width: 4,
            tab_width: std::num::NonZeroUsize::new(4).unwrap(),
            tabs: crate::language::TabPolicy::Never,
        }
    }

    /// Every line of a correctly indented text indents as it is.
    #[track_caller]
    fn holds(text: &str) {
        let snapshot = Snapshot::new(text.to_owned(), 0);
        let structure = Structure::new(Arc::from(text));
        let style = style();
        for line in 0..snapshot.line_count() {
            let Some(content) = snapshot.line_content_range(line) else {
                continue;
            };
            if content.is_empty() {
                continue;
            }
            let IndentAdvice::Set { prefix, .. } = indent(&structure, &snapshot, line, &style)
            else {
                continue;
            };
            let have = snapshot.leading_whitespace(line).unwrap().to_string();
            assert_eq!(
                prefix,
                have,
                "line {line}: {:?}\n{text}",
                snapshot.line(line).unwrap()
            );
        }
    }
    #[test]
    fn blocks_and_lists_indent_a_level() {
        holds(
            "fn main() {\n    let x = foo(\n        a,\n        b,\n    );\n    if x {\n        y();\n    } else {\n        z();\n    }\n}\n",
        );
        holds(
            "struct S {\n    a: u8,\n    b: Vec<u8>,\n}\n\nenum E {\n    A,\n    B { x: u8 },\n}\n",
        );
        holds(
            "fn f() {\n    match x {\n        A => 1,\n        B =>\n            2,\n        C => {\n            3\n        }\n        D => 4,\n    }\n}\n",
        );
    }
    #[test]
    fn continuations_indent_a_level_from_their_unit() {
        holds(
            "fn f() {\n    let v = xs\n        .iter()\n        .map(|x| {\n            x + 1\n        })\n        .collect::<Vec<_>>();\n    next();\n}\n",
        );
        holds(
            "fn f() {\n    let ok = a\n        && b\n        || c;\n    let y =\n        long();\n}\n",
        );
        holds(
            "impl<T> Foo for T\nwhere\n    T: Bar,\n    T: Baz,\n{\n    fn g(\n        a: u8,\n    ) -> u8 {\n        a\n    }\n}\n",
        );
        holds("let p = Point {\n    x: 1,\n    y: 2,\n}\n.norm();\n");
        // As rustfmt writes them: links after a closer that leads its line
        // line up with it.
        holds(
            "fn f() {\n    let h = thread::spawn(move || {\n        work();\n    })\n    .join()\n    .unwrap();\n    if long(a)\n        && other(b)\n    {\n        x();\n    }\n}\n",
        );
        holds("if a {\n    b();\n}\nelse {\n    c();\n}\n");
        holds("fn f<F>(\n    g: F,\n) where\n    F: Fn(),\n{\n}\n");
    }
    #[test]
    fn units_end_at_attributes_and_blocks() {
        holds(
            "#[derive(Debug)]\nstruct A;\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() {}\n    fn u() {}\n}\n",
        );
        holds(
            "fn f() {\n    if a {\n        b();\n    }\n    *c = 1;\n    for x in xs {\n        x;\n    }\n}\n",
        );
        holds("fn f() {\n    // note\n    a();\n    /// doc\n    b();\n}\n");
        holds("fn f() {\n    if let Some(v) = opt {\n        v;\n    }\n}\n");
    }
    #[test]
    fn literals_keep_their_lines() {
        let text = "fn f() {\n    let s = \"a\nb\";\n    /* x\n   y */\n}\n";
        let snapshot = Snapshot::new(text.to_owned(), 0);
        let structure = Structure::new(Arc::from(text));
        let style = style();
        assert!(matches!(
            indent(&structure, &snapshot, 2, &style),
            IndentAdvice::Preserve {
                newline: NewlineIndent::Verbatim
            }
        ));
        assert!(matches!(
            indent(&structure, &snapshot, 4, &style),
            IndentAdvice::Preserve {
                newline: NewlineIndent::Inherit { .. }
            }
        ));
    }
}

#[cfg(test)]
mod corpus {
    use super::*;
    use std::sync::Arc;

    #[test]
    #[ignore]
    fn corpus() {
        let style = WhitespacePolicy {
            indent_width: 4,
            tab_width: std::num::NonZeroUsize::new(4).unwrap(),
            tabs: crate::language::TabPolicy::Never,
        };
        let roots = std::env::var("CORPUS").unwrap();
        let (mut lines, mut wrong) = (0, 0);
        let mut shown = 0;
        for root in roots.split(':') {
            let out = std::process::Command::new("find")
                .args([
                    root,
                    "-name",
                    "*.rs",
                    "-not",
                    "-path",
                    "*/tests/*",
                    "-not",
                    "-path",
                    "*/target/*",
                ])
                .output()
                .unwrap();
            for path in String::from_utf8(out.stdout).unwrap().lines() {
                let Ok(text) = std::fs::read_to_string(path) else {
                    continue;
                };
                let snapshot = Snapshot::new(text.clone(), 0);
                let structure = Structure::new(Arc::from(text.as_str()));
                for line in 0..snapshot.line_count() {
                    let Some(content) = snapshot.line_content_range(line) else {
                        continue;
                    };
                    if content.is_empty()
                        || snapshot.leading_whitespace(line).unwrap().len_bytes() == content.len()
                    {
                        continue;
                    }
                    let IndentAdvice::Set { prefix, .. } =
                        indent(&structure, &snapshot, line, &style)
                    else {
                        continue;
                    };
                    lines += 1;
                    let have = snapshot.leading_whitespace(line).unwrap().to_string();
                    if prefix != have {
                        wrong += 1;
                        if shown < 60 {
                            shown += 1;
                            let from = line.saturating_sub(3);
                            eprintln!(
                                "== {path}:{} want {} got {}",
                                line + 1,
                                have.len(),
                                prefix.len()
                            );
                            for l in from..=line {
                                eprintln!("  {}", snapshot.line(l).unwrap().trim_end());
                            }
                        }
                    }
                }
            }
        }
        eprintln!("{wrong} of {lines} lines differ");
    }

    /// Enter: each line as a blank one, the caret there, before typing its
    /// first token. Only lines whose first token cannot move them count.
    #[test]
    #[ignore]
    fn corpus_enter() {
        let style = WhitespacePolicy {
            indent_width: 4,
            tab_width: std::num::NonZeroUsize::new(4).unwrap(),
            tabs: crate::language::TabPolicy::Never,
        };
        let roots = std::env::var("CORPUS").unwrap();
        let (mut lines, mut wrong, mut shown) = (0, 0, 0);
        for root in roots.split(':') {
            let out = std::process::Command::new("find")
                .args([
                    root,
                    "-name",
                    "*.rs",
                    "-size",
                    "-40k",
                    "-not",
                    "-path",
                    "*/tests/*",
                ])
                .output()
                .unwrap();
            for path in String::from_utf8(out.stdout).unwrap().lines() {
                let Ok(text) = std::fs::read_to_string(path) else {
                    continue;
                };
                let all: Vec<&str> = text.split_inclusive('\n').collect();
                for line in (1..all.len()).step_by(5) {
                    let content = all[line].trim_start();
                    let have = &all[line][..all[line].len() - content.len()];
                    let word = content.starts_with(|c: char| {
                        c.is_alphanumeric() || c == '_' || c == '"' || c == '#'
                    });
                    if !word
                        || content.starts_with("else")
                        || content.starts_with("where")
                        || content.starts_with("if ")
                        || content.starts_with("as ")
                    {
                        continue;
                    }
                    let blanked: String = all[..line].concat() + "\n" + &all[line + 1..].concat();
                    let snapshot = Snapshot::new(blanked.clone(), 0);
                    let structure = Structure::new(Arc::from(blanked.as_str()));
                    let IndentAdvice::Set { prefix, .. } =
                        indent(&structure, &snapshot, line, &style)
                    else {
                        continue;
                    };
                    lines += 1;
                    if prefix != have {
                        wrong += 1;
                        if shown < 30 {
                            shown += 1;
                            eprintln!(
                                "== {path}:{} want {} got {}",
                                line + 1,
                                have.len(),
                                prefix.len()
                            );
                            for shown in &all[line.saturating_sub(2)..=line] {
                                eprintln!("  {}", shown.trim_end());
                            }
                        }
                    }
                }
            }
        }
        eprintln!("{wrong} of {lines} blank lines differ");
    }
}
