//! The LSP snippet syntax: places, choices, variables and transforms, read
//! into a tree and then written out as text with where each place is.
use regex::Regex;
use std::{collections::HashMap, ops::Range};

/// A regular expression and the format of what replaces its matches, as in
/// `${1/(.*)/${1:/upcase}/}`.
#[derive(Clone, Debug)]
pub struct Transform {
    regex: Regex,
    format: Vec<Format>,
    global: bool,
}
#[derive(Clone, Copy, Debug)]
enum Case {
    Upcase,
    Downcase,
    Capitalize,
    Camel,
    Pascal,
}
#[derive(Clone, Debug)]
enum Format {
    Text(String),
    Group(usize, Option<Case>),
    /// `then` when the group matched (itself when none), else `otherwise`.
    Choose {
        group: usize,
        then: Option<String>,
        otherwise: String,
    },
}
impl Transform {
    fn new(pattern: &str, format: &str, options: &str) -> Option<Self> {
        let flags: String = options.chars().filter(|o| "ims".contains(*o)).collect();
        let pattern = if flags.is_empty() {
            pattern.to_owned()
        } else {
            format!("(?{flags}){pattern}")
        };
        Some(Self {
            regex: Regex::new(&pattern).ok()?,
            format: parse_format(format),
            global: options.contains('g'),
        })
    }
    pub fn apply(&self, text: &str) -> String {
        let mut out = String::new();
        let mut last = 0;
        for captures in self.regex.captures_iter(text) {
            let whole = captures.get(0).unwrap();
            out.push_str(&text[last..whole.start()]);
            let group = |n: usize| captures.get(n).map(|m| m.as_str());
            for part in &self.format {
                match part {
                    Format::Text(text) => out.push_str(text),
                    Format::Group(n, case) => {
                        let text = group(*n).unwrap_or_default();
                        out.push_str(&case.map_or_else(|| text.to_owned(), |c| c.apply(text)));
                    }
                    Format::Choose {
                        group: n,
                        then,
                        otherwise,
                    } => match group(*n).filter(|text| !text.is_empty()) {
                        Some(text) => out.push_str(then.as_deref().unwrap_or(text)),
                        None => out.push_str(otherwise),
                    },
                }
            }
            last = whole.end();
            if !self.global {
                break;
            }
        }
        out.push_str(&text[last..]);
        out
    }
}
impl Case {
    fn named(name: &str) -> Option<Self> {
        Some(match name {
            "upcase" => Self::Upcase,
            "downcase" => Self::Downcase,
            "capitalize" => Self::Capitalize,
            "camelcase" => Self::Camel,
            "pascalcase" => Self::Pascal,
            _ => return None,
        })
    }
    fn apply(self, text: &str) -> String {
        let capital = |word: &str| {
            let mut chars = word.chars();
            chars.next().map_or_else(String::new, |first| {
                first
                    .to_uppercase()
                    .chain(chars.flat_map(char::to_lowercase))
                    .collect()
            })
        };
        let words = || {
            text.split(|ch: char| !ch.is_alphanumeric())
                .filter(|w| !w.is_empty())
        };
        match self {
            Self::Upcase => text.to_uppercase(),
            Self::Downcase => text.to_lowercase(),
            Self::Capitalize => {
                let mut chars = text.chars();
                chars.next().map_or_else(String::new, |first| {
                    first.to_uppercase().chain(chars).collect()
                })
            }
            Self::Pascal => words().map(capital).collect(),
            Self::Camel => words()
                .enumerate()
                .map(|(at, word)| {
                    if at == 0 {
                        word.to_lowercase()
                    } else {
                        capital(word)
                    }
                })
                .collect(),
        }
    }
}
/// The format of a transform: `$1`, `${1}`, `${1:/upcase}`, `${1:+then}`,
/// `${1:?then:else}`, `${1:-else}` and `${1:else}`; the rest is text.
fn parse_format(source: &str) -> Vec<Format> {
    let mut parts = vec![];
    let mut text = String::new();
    let mut rest = source;
    while let Some(ch) = rest.chars().next() {
        rest = &rest[ch.len_utf8()..];
        match ch {
            '\\' => match rest.chars().next() {
                Some(next) => {
                    rest = &rest[next.len_utf8()..];
                    text.push(match next {
                        'n' => '\n',
                        't' => '\t',
                        next => next,
                    });
                }
                None => text.push('\\'),
            },
            '$' => {
                let mut after = rest;
                match format_group(&mut after) {
                    Some(format) => {
                        rest = after;
                        if !text.is_empty() {
                            parts.push(Format::Text(std::mem::take(&mut text)));
                        }
                        parts.push(format);
                    }
                    None => text.push('$'),
                }
            }
            ch => text.push(ch),
        }
    }
    if !text.is_empty() {
        parts.push(Format::Text(text));
    }
    parts
}
/// Text up to one of `stops`, unescaped, and the stop; none when it runs
/// out first.
fn format_until(rest: &mut &str, stops: &[char]) -> Option<String> {
    let mut out = String::new();
    let mut chars = rest.char_indices();
    while let Some((at, ch)) = chars.next() {
        match ch {
            '\\' => out.extend(chars.next().map(|(_, ch)| ch)),
            ch if stops.contains(&ch) => {
                *rest = &rest[at + ch.len_utf8()..];
                return Some(out);
            }
            ch => out.push(ch),
        }
    }
    None
}
fn format_number(rest: &mut &str) -> Option<usize> {
    let end = rest
        .find(|ch: char| !ch.is_ascii_digit())
        .unwrap_or(rest.len());
    let n = rest[..end].parse().ok()?;
    *rest = &rest[end..];
    Some(n)
}
/// A group after `$`.
fn format_group(rest: &mut &str) -> Option<Format> {
    if let Some(n) = format_number(rest) {
        return Some(Format::Group(n, None));
    }
    *rest = rest.strip_prefix('{')?;
    let n = format_number(rest)?;
    if let Some(after) = rest.strip_prefix('}') {
        *rest = after;
        return Some(Format::Group(n, None));
    }
    *rest = rest.strip_prefix(':')?;
    let kind = rest.chars().next()?;
    if !"/+?-".contains(kind) {
        let otherwise = format_until(rest, &['}'])?;
        return Some(Format::Choose {
            group: n,
            then: None,
            otherwise,
        });
    }
    *rest = &rest[1..];
    Some(match kind {
        '/' => Format::Group(n, Some(Case::named(&format_until(rest, &['}'])?)?)),
        '+' => Format::Choose {
            group: n,
            then: Some(format_until(rest, &['}'])?),
            otherwise: String::new(),
        },
        '?' => Format::Choose {
            group: n,
            then: Some(format_until(rest, &[':'])?),
            otherwise: format_until(rest, &['}'])?,
        },
        _ => Format::Choose {
            group: n,
            then: None,
            otherwise: format_until(rest, &['}'])?,
        },
    })
}

#[derive(Debug)]
enum Node {
    Text(String),
    Tabstop {
        number: u32,
        id: usize,
        children: Vec<Node>,
        choices: Vec<String>,
        transform: Option<Transform>,
    },
    Variable {
        name: String,
        default: Option<Vec<Node>>,
        transform: Option<Transform>,
    },
}

struct Parser<'a> {
    rest: &'a str,
    ids: usize,
}
impl Parser<'_> {
    fn peek(&self) -> Option<char> {
        self.rest.chars().next()
    }
    fn bump(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.rest = &self.rest[ch.len_utf8()..];
        Some(ch)
    }
    fn eat(&mut self, ch: char) -> bool {
        let found = self.peek() == Some(ch);
        if found {
            self.bump();
        }
        found
    }
    fn number(&mut self) -> Option<u32> {
        let end = self
            .rest
            .find(|ch: char| !ch.is_ascii_digit())
            .unwrap_or(self.rest.len());
        let number = self.rest[..end].parse().ok()?;
        self.rest = &self.rest[end..];
        Some(number)
    }
    fn name(&mut self) -> Option<String> {
        if !self.peek()?.is_ascii_alphabetic() && self.peek()? != '_' {
            return None;
        }
        let end = self
            .rest
            .find(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
            .unwrap_or(self.rest.len());
        let name = self.rest[..end].to_owned();
        self.rest = &self.rest[end..];
        Some(name)
    }
    /// Nodes up to the end, or a `}` that closes a nested part; whether it
    /// was closed.
    fn nodes(&mut self, nested: bool) -> (Vec<Node>, bool) {
        let mut nodes = vec![];
        let mut text = String::new();
        while let Some(ch) = self.bump() {
            match ch {
                '\\' => match self.peek() {
                    Some(next @ ('$' | '}' | '\\')) => {
                        self.bump();
                        text.push(next);
                    }
                    _ => text.push('\\'),
                },
                '}' if nested => {
                    if !text.is_empty() {
                        nodes.push(Node::Text(text));
                    }
                    return (nodes, true);
                }
                '$' => {
                    let saved = self.rest;
                    match self.dollar() {
                        Some(node) => {
                            if !text.is_empty() {
                                nodes.push(Node::Text(std::mem::take(&mut text)));
                            }
                            nodes.push(node);
                        }
                        None => {
                            self.rest = saved;
                            text.push('$');
                        }
                    }
                }
                ch => text.push(ch),
            }
        }
        if !text.is_empty() {
            nodes.push(Node::Text(text));
        }
        (nodes, false)
    }
    fn tabstop(&mut self, number: u32) -> Node {
        self.ids += 1;
        Node::Tabstop {
            number,
            id: self.ids,
            children: vec![],
            choices: vec![],
            transform: None,
        }
    }
    fn dollar(&mut self) -> Option<Node> {
        if let Some(number) = self.number() {
            return Some(self.tabstop(number));
        }
        if let Some(name) = self.name() {
            return Some(Node::Variable {
                name,
                default: None,
                transform: None,
            });
        }
        if !self.eat('{') {
            return None;
        }
        if let Some(number) = self.number() {
            let mut node = self.tabstop(number);
            let Node::Tabstop {
                children,
                choices,
                transform,
                ..
            } = &mut node
            else {
                unreachable!()
            };
            match self.bump()? {
                '}' => {}
                ':' => {
                    let (nodes, closed) = self.nodes(true);
                    closed.then_some(())?;
                    *children = nodes;
                }
                '|' => {
                    *choices = self.choices()?;
                    *children = vec![Node::Text(choices.first().cloned().unwrap_or_default())];
                }
                '/' => *transform = self.transform()?,
                _ => return None,
            }
            return Some(node);
        }
        let name = self.name()?;
        let (default, transform) = match self.bump()? {
            '}' => (None, None),
            ':' => {
                let (nodes, closed) = self.nodes(true);
                closed.then_some(())?;
                (Some(nodes), None)
            }
            '/' => (None, self.transform()?),
            _ => return None,
        };
        Some(Node::Variable {
            name,
            default,
            transform,
        })
    }
    /// `a,b|}` after `${1|`.
    fn choices(&mut self) -> Option<Vec<String>> {
        let mut choices = vec![String::new()];
        loop {
            match self.bump()? {
                '\\' => {
                    let next = self.bump()?;
                    if !",|\\$}".contains(next) {
                        choices.last_mut()?.push('\\');
                    }
                    choices.last_mut()?.push(next);
                }
                ',' => choices.push(String::new()),
                '|' => {
                    self.eat('}').then_some(())?;
                    return Some(choices);
                }
                ch => choices.last_mut()?.push(ch),
            }
        }
    }
    /// `regex/format/options}` after `${1/`; the inner none when the
    /// expression is not one. The format's own `${…}` may hold `/`.
    fn transform(&mut self) -> Option<Option<Transform>> {
        let mut part = || -> Option<String> {
            let mut out = String::new();
            let mut depth = 0;
            loop {
                match self.bump()? {
                    '\\' => {
                        let next = self.bump()?;
                        if next != '/' {
                            out.push('\\');
                        }
                        out.push(next);
                    }
                    '/' if depth == 0 => return Some(out),
                    '$' if self.peek() == Some('{') => {
                        self.bump();
                        depth += 1;
                        out.push_str("${");
                    }
                    '}' if depth > 0 => {
                        depth -= 1;
                        out.push('}');
                    }
                    ch => out.push(ch),
                }
            }
        };
        let pattern = part()?;
        let format = part()?;
        let end = self.rest.find('}')?;
        let options = self.rest[..end].to_owned();
        self.rest = &self.rest[end + 1..];
        Some(Transform::new(&pattern, &format, &options))
    }
}

/// A place to fill in, in the order Tab visits them.
#[derive(Clone, Debug)]
pub struct Stop {
    pub range: Range<usize>,
    /// Where it comes among the snippet's places, to tell which side of an
    /// empty neighbor typing lands on.
    pub(super) order: usize,
    pub choices: Vec<String>,
    pub mirrors: Vec<Mirror>,
}
#[derive(Clone, Debug)]
pub struct Mirror {
    pub range: Range<usize>,
    pub(super) order: usize,
    pub transform: Option<Transform>,
}
#[derive(Clone, Debug)]
pub struct Parsed {
    pub text: String,
    /// In the order they are visited; the last is where the caret ends.
    pub stops: Vec<Stop>,
}

struct Render<'a> {
    variables: &'a dyn Fn(&str) -> Option<String>,
    tree: &'a [Node],
    /// Each number's place to fill in, by id.
    primaries: &'a HashMap<u32, usize>,
    /// Numbers whose text this is part of, which cannot hold themselves.
    within: Vec<u32>,
    text: String,
    stops: Vec<(u32, Stop)>,
    mirrors: Vec<(u32, Mirror)>,
    order: usize,
    /// The number the next unknown variable takes.
    unknown: u32,
}
impl<'a> Render<'a> {
    fn new(
        variables: &'a dyn Fn(&str) -> Option<String>,
        tree: &'a [Node],
        primaries: &'a HashMap<u32, usize>,
        unknown: u32,
    ) -> Self {
        Self {
            variables,
            tree,
            primaries,
            within: vec![],
            text: String::new(),
            stops: vec![],
            mirrors: vec![],
            order: 0,
            unknown,
        }
    }
    /// What a number's place holds as it expands.
    fn held(&self, number: u32) -> String {
        let place = self
            .primaries
            .get(&number)
            .and_then(|id| find(self.tree, *id));
        let Some(Node::Tabstop { children, .. }) = place else {
            return String::new();
        };
        if self.within.contains(&number) {
            return String::new();
        }
        let mut inner = Render::new(self.variables, self.tree, self.primaries, 0);
        inner.within = self.within.clone();
        inner.within.push(number);
        inner.render(children);
        inner.text
    }
    fn render(&mut self, nodes: &[Node]) {
        for node in nodes {
            match node {
                Node::Text(t) => self.text.push_str(t),
                Node::Tabstop {
                    number,
                    id,
                    children,
                    choices,
                    transform,
                } => {
                    let start = self.text.len();
                    self.order += 1;
                    let order = self.order;
                    if self.primaries.get(number) == Some(id) {
                        self.within.push(*number);
                        self.render(children);
                        self.within.pop();
                        let stop = Stop {
                            range: start..self.text.len(),
                            order,
                            choices: choices.clone(),
                            mirrors: vec![],
                        };
                        self.stops.push((*number, stop));
                    } else {
                        let held = self.held(*number);
                        let text = transform.as_ref().map_or(held.clone(), |t| t.apply(&held));
                        self.text.push_str(&text);
                        let mirror = Mirror {
                            range: start..self.text.len(),
                            order,
                            transform: transform.clone(),
                        };
                        self.mirrors.push((*number, mirror));
                    }
                }
                Node::Variable {
                    name,
                    default,
                    transform,
                } => match ((self.variables)(name), default) {
                    (Some(value), _) if !value.is_empty() => {
                        let text = transform
                            .as_ref()
                            .map_or(value.clone(), |t| t.apply(&value));
                        self.text.push_str(&text);
                    }
                    (_, Some(default)) => self.render(default),
                    (Some(_), None) => {}
                    (None, None) => {
                        let start = self.text.len();
                        self.text.push_str(name);
                        self.order += 1;
                        let stop = Stop {
                            range: start..self.text.len(),
                            order: self.order,
                            choices: vec![],
                            mirrors: vec![],
                        };
                        self.stops.push((self.unknown, stop));
                        self.unknown += 1;
                    }
                },
            }
        }
    }
}
fn find(nodes: &[Node], wanted: usize) -> Option<&Node> {
    nodes.iter().find_map(|node| match node {
        Node::Tabstop { id, .. } if *id == wanted => Some(node),
        Node::Tabstop { children, .. } => find(children, wanted),
        Node::Variable {
            default: Some(default),
            ..
        } => find(default, wanted),
        _ => None,
    })
}
/// Every tabstop in the order they are written: number, id, and whether
/// it holds text or choices, or transforms.
fn tabstops(nodes: &[Node], out: &mut Vec<(u32, usize, bool, bool)>) {
    for node in nodes {
        match node {
            Node::Tabstop {
                number,
                id,
                children,
                choices,
                transform,
            } => {
                let filled = !children.is_empty() || !choices.is_empty();
                out.push((*number, *id, filled, transform.is_some()));
                tabstops(children, out);
            }
            Node::Variable {
                default: Some(default),
                ..
            } => tabstops(default, out),
            _ => {}
        }
    }
}

/// Reads a snippet whose variables are all unknown.
pub fn parse(body: &str) -> Parsed {
    parse_with(body, &|_| None)
}
/// Reads a snippet, asking `variables` for the value of each variable:
/// none when the name is unknown.
pub fn parse_with(body: &str, variables: &dyn Fn(&str) -> Option<String>) -> Parsed {
    let mut parser = Parser { rest: body, ids: 0 };
    let (tree, _) = parser.nodes(false);
    let mut all = vec![];
    tabstops(&tree, &mut all);
    // The place of a number is its first with a default, else its first
    // without a transform, else its first.
    let mut primaries = HashMap::new();
    for pass in 0..3 {
        for (number, id, filled, transformed) in &all {
            let fits = match pass {
                0 => *filled && !transformed,
                1 => !transformed,
                _ => true,
            };
            if fits {
                primaries.entry(*number).or_insert(*id);
            }
        }
    }
    let unknown = all.iter().map(|(number, ..)| number + 1).max().unwrap_or(1);
    let mut render = Render::new(variables, &tree, &primaries, unknown);
    render.render(&tree);
    let Render {
        text,
        mut stops,
        mirrors,
        order,
        ..
    } = render;
    for (number, mirror) in mirrors {
        if let Some((_, stop)) = stops.iter_mut().find(|(n, _)| *n == number) {
            stop.mirrors.push(mirror);
        }
    }
    let ends = stops.iter().any(|(number, _)| *number == 0);
    stops.sort_by_key(|(number, _)| (*number == 0, *number));
    let mut stops: Vec<_> = stops.into_iter().map(|(_, stop)| stop).collect();
    if !ends {
        stops.push(Stop {
            range: text.len()..text.len(),
            order: order + 1,
            choices: vec![],
            mirrors: vec![],
        });
    }
    Parsed { text, stops }
}
impl Parsed {
    /// Follows the line it lands on: lines after the first take `indent`, and
    /// a tab at the start of one is a level, `unit`.
    pub fn indented(&self, indent: &str, unit: &str) -> Self {
        let mut text = String::new();
        let mut map = vec![0; self.text.len() + 1];
        let mut leading = false;
        for (at, ch) in self.text.char_indices() {
            map[at] = text.len();
            match ch {
                '\t' if leading => text.push_str(unit),
                ch => {
                    leading = ch == '\n';
                    text.push(ch);
                    if leading {
                        text.push_str(indent);
                    }
                }
            }
        }
        map[self.text.len()] = text.len();
        let range = |range: &Range<usize>| map[range.start]..map[range.end];
        Self {
            text,
            stops: self
                .stops
                .iter()
                .map(|stop| Stop {
                    range: range(&stop.range),
                    mirrors: stop
                        .mirrors
                        .iter()
                        .map(|mirror| Mirror {
                            range: range(&mirror.range),
                            ..mirror.clone()
                        })
                        .collect(),
                    ..stop.clone()
                })
                .collect(),
        }
    }
    pub fn lines(&self) -> usize {
        self.text.matches('\n').count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn parsed(body: &str) -> (String, Vec<Range<usize>>) {
        let Parsed { text, stops } = parse(body);
        (text, stops.into_iter().map(|stop| stop.range).collect())
    }
    #[test]
    fn stops_come_in_order_with_the_end_last() {
        assert_eq!(
            parsed("a$2b$1c$0d"),
            ("abcd".into(), vec![2..2, 1..1, 3..3])
        );
        assert_eq!(parsed("f(${1:x})"), ("f(x)".into(), vec![2..3, 4..4]));
        assert_eq!(parsed("plain").1.len(), 1);
    }
    #[test]
    fn placeholders_nest_and_repeats_mirror_the_one_with_a_default() {
        assert_eq!(parsed("${1:a${2:b}c}").0, "abc");
        let snippet = parse("$1 ${1:a} $1");
        assert_eq!(snippet.text, "a a a");
        assert_eq!(snippet.stops[0].range, 2..3);
        let mirrors: Vec<_> = snippet.stops[0]
            .mirrors
            .iter()
            .map(|m| m.range.clone())
            .collect();
        assert_eq!(mirrors, [0..1, 4..5]);
    }
    #[test]
    fn the_rest_of_the_syntax_reads_as_text() {
        assert_eq!(parsed("\\$1 \\} \\\\").0, "$1 } \\");
        assert_eq!(parsed("cost $").0, "cost $");
        assert_eq!(parsed("${broken").0, "${broken");
        assert_eq!(parsed("${1:open").0, "${1:open");
    }
    #[test]
    fn choices_hold_their_first_and_keep_the_rest() {
        let snippet = parse("${1|yes,no\\,really|}!");
        assert_eq!(snippet.text, "yes!");
        assert_eq!(snippet.stops[0].choices, ["yes", "no,really"]);
    }
    #[test]
    fn variables_take_their_value_or_default_and_unknown_ones_are_places() {
        let variables = |name: &str| match name {
            "TM_FILENAME" => Some("main.cpp".to_owned()),
            "TM_SELECTED_TEXT" => Some(String::new()),
            _ => None,
        };
        let snippet = parse_with(
            "$TM_FILENAME ${TM_SELECTED_TEXT:${1:x}} $OTHER $2",
            &variables,
        );
        assert_eq!(snippet.text, "main.cpp x OTHER ");
        let ranges: Vec<_> = snippet.stops.iter().map(|s| s.range.clone()).collect();
        // 1, 2, then OTHER as 3, then the end.
        assert_eq!(ranges, [9..10, 17..17, 11..16, 17..17]);
        let snippet = parse_with("${TM_FILENAME/(.*)\\..+$/$1/}", &variables);
        assert_eq!(snippet.text, "main");
    }
    #[test]
    fn transforms_format_what_they_match() {
        let snippet = parse("${1:foo_bar} ${1/(.*)/${1:/upcase}/} ${1/_(.)/${1:/upcase}/g}");
        assert_eq!(snippet.text, "foo_bar FOO_BAR fooBar");
        let t = Transform::new("(a)?b", "${1:?yes:no}-${1:+A}${1:-none}", "").unwrap();
        assert_eq!(t.apply("ab"), "yes-Aa");
        assert_eq!(t.apply("b"), "no-none");
        let t = Transform::new(
            "(.*)",
            "${1:/pascalcase} ${1:/camelcase} ${1:/capitalize}",
            "",
        )
        .unwrap();
        assert_eq!(t.apply("foo bar"), "FooBar fooBar Foo bar");
        assert_eq!(
            Transform::new("a", "\\$\\/", "gi").unwrap().apply("AaB"),
            "$/$/B"
        );
    }
    #[test]
    fn indenting_keeps_stops_on_their_text() {
        let body = parse("{\n\t${1:x}\n}");
        let indented = body.indented("  ", "    ");
        assert_eq!(indented.text, "{\n      x\n  }");
        assert_eq!(&indented.text[indented.stops[0].range.clone()], "x");
    }
}
