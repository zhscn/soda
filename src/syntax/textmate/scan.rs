//! Line scanning with a rule stack, following vscode-textmate: at each
//! position the earliest match among the frame's patterns and its end pattern
//! wins, ties going to the earlier pattern with the end pattern first unless
//! `applyEndPatternLast` is set.
use super::{Captures, GrammarId, Registry, Rule, RuleId};
use crate::syntax::Category;
use onig::{Region, SearchOptions};
use std::{collections::HashMap, sync::Arc};

/// Lines longer than this are not highlighted, as in IntelliJ.
pub(super) const LINE_LIMIT: usize = 20_000;
/// Steps per line before giving up on a grammar that stops advancing.
const STEP_LIMIT: usize = 10_000;

#[derive(Clone, Debug, Eq, PartialEq)]
struct Frame {
    rule: RuleId,
    /// The end or while pattern with back references resolved.
    end: Option<Arc<str>>,
    /// Category of the rule's `name`, inherited when it has none.
    scope: Option<Category>,
    /// Category inside the rule, from `contentName` or `scope`.
    content: Option<Category>,
}
/// The rule stack at a line start. Equal states scan following lines
/// identically, which is what incremental updates rely on.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(in crate::syntax) struct State {
    frames: Vec<Frame>,
}
impl State {
    pub fn new(registry: &Registry, grammar: GrammarId) -> Self {
        Self {
            frames: vec![Frame {
                rule: registry.root(grammar),
                end: None,
                scope: None,
                content: None,
            }],
        }
    }
}

/// Per-byte categories of the line being scanned, painted outer to inner.
struct Paint(Vec<Option<Category>>);
impl Paint {
    fn fill(&mut self, start: usize, end: usize, category: Option<Category>) {
        if category.is_some() {
            self.0[start..end].fill(category);
        } else {
            self.0[start..end].fill(None);
        }
    }
    fn overlay(&mut self, start: usize, end: usize, category: Option<Category>) {
        if category.is_some() {
            self.0[start..end].fill(category);
        }
    }
}

enum Winner {
    End,
    Rule(RuleId),
}
/// Remembered search results within one line: a match found from an
/// earlier position is still the first one from any later position up to
/// its start, unless the pattern uses `\G`.
type Memo = HashMap<usize, (usize, Option<usize>)>;

fn groups(region: &Region) -> Vec<Option<(usize, usize)>> {
    (0..region.len()).map(|i| region.pos(i)).collect()
}
/// Escapes text for use inside a regular expression.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if "\\|-*+?.^$()[]{}/,#".contains(ch) || ch.is_whitespace() {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}
/// Replaces `\1`..`\9` in an end pattern with the begin match's captures.
fn resolve_end(end: &str, text: &str, groups: &[Option<(usize, usize)>]) -> String {
    let mut out = String::with_capacity(end.len());
    let mut chars = end.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        match chars.peek() {
            Some(digit) if digit.is_ascii_digit() => {
                let index = digit.to_digit(10).unwrap() as usize;
                chars.next();
                if let Some(Some((start, end))) = groups.get(index) {
                    out.push_str(&escape(&text[*start..*end]));
                }
            }
            Some(_) => {
                out.push('\\');
                out.push(chars.next().unwrap());
            }
            None => out.push('\\'),
        }
    }
    out
}
fn next_char(text: &str, position: usize) -> usize {
    text[position..]
        .chars()
        .next()
        .map_or(text.len(), |c| position + c.len_utf8())
}

impl Registry {
    /// Scans one line (without its terminator) from `state`, leaving the
    /// state for the next line. Returns category runs within the line.
    pub(in crate::syntax) fn scan_line(
        &mut self,
        base: GrammarId,
        line: &str,
        state: &mut State,
    ) -> Vec<(std::ops::Range<usize>, Category)> {
        if line.len() > LINE_LIMIT {
            return vec![];
        }
        let text = format!("{line}\n");
        let mut paint = Paint(vec![None; text.len()]);
        let position = self.check_while(base, &text, state, &mut paint);
        self.scan(base, &text, position, state, &mut paint);
        let mut runs: Vec<(std::ops::Range<usize>, Category)> = vec![];
        for (index, category) in paint.0[..line.len()].iter().enumerate() {
            let Some(category) = *category else {
                continue;
            };
            match runs.last_mut() {
                Some((range, last)) if *last == category && range.end == index => range.end += 1,
                _ => runs.push((index..index + 1, category)),
            }
        }
        runs
    }
    /// `while` rules continue only while their pattern matches at the start
    /// of each line; the first that fails pops itself and everything above.
    fn check_while(
        &mut self,
        base: GrammarId,
        text: &str,
        state: &mut State,
        paint: &mut Paint,
    ) -> usize {
        let mut position = 0;
        let mut index = 1;
        while index < state.frames.len() {
            let frame = state.frames[index].clone();
            let Rule::Begin { while_: true, .. } = self.rule(frame.rule) else {
                index += 1;
                continue;
            };
            let id = self.regex_id(frame.end.as_deref().unwrap_or(""));
            let mut region = Region::new();
            let matched = self.regex(id).and_then(|regex| {
                regex.search_with_options(
                    text,
                    position,
                    text.len(),
                    SearchOptions::SEARCH_OPTION_NONE,
                    Some(&mut region),
                )
            });
            if matched != Some(position) {
                state.frames.truncate(index);
                break;
            }
            let (start, end) = region.pos(0).unwrap();
            paint.fill(start, end, frame.scope);
            let captures = match self.rule(frame.rule) {
                Rule::Begin { end_captures, .. } => end_captures.clone(),
                _ => unreachable!(),
            };
            self.paint_captures(base, text, &region, &captures, frame.scope, paint);
            position = end;
            index += 1;
        }
        position
    }
    fn search(
        &mut self,
        regex: usize,
        text: &str,
        position: usize,
        memo: &mut Memo,
    ) -> Option<usize> {
        if !self.anchored(regex)
            && let Some((from, found)) = memo.get(&regex)
            && *from <= position
            && found.is_none_or(|start| start >= position)
        {
            return *found;
        }
        let found = self.regex(regex).and_then(|r| {
            r.search_with_options(
                text,
                position,
                text.len(),
                SearchOptions::SEARCH_OPTION_NONE,
                None,
            )
        });
        memo.insert(regex, (position, found));
        found
    }
    fn region(&mut self, regex: usize, text: &str, position: usize) -> Option<Region> {
        let mut region = Region::new();
        self.regex(regex)?.search_with_options(
            text,
            position,
            text.len(),
            SearchOptions::SEARCH_OPTION_NONE,
            Some(&mut region),
        )?;
        Some(region)
    }
    fn scan(
        &mut self,
        base: GrammarId,
        text: &str,
        mut position: usize,
        state: &mut State,
        paint: &mut Paint,
    ) {
        let mut memo = Memo::new();
        // Pushes at one position; repeating an empty begin is a loop.
        let mut stalls = 0;
        for _ in 0..STEP_LIMIT {
            if position >= text.len() {
                return;
            }
            let frame = state.frames.last().unwrap().clone();
            let candidates = self.candidates(frame.rule, base);
            let (closes, end_last) = match self.rule(frame.rule) {
                Rule::Begin {
                    while_: false,
                    end_last,
                    ..
                } => (true, *end_last),
                _ => (false, false),
            };
            let end = match (&frame.end, closes) {
                (Some(source), true) => Some(self.regex_id(source)),
                _ => None,
            };
            let mut best: Option<(usize, Winner, usize)> = None;
            let mut consider = |start: Option<usize>, winner: Winner, regex: usize| {
                if let Some(start) = start
                    && best.as_ref().is_none_or(|(s, _, _)| start < *s)
                {
                    best = Some((start, winner, regex));
                }
            };
            if let Some(end) = end.filter(|_| !end_last) {
                consider(
                    self.search(end, text, position, &mut memo),
                    Winner::End,
                    end,
                );
            }
            for &rule in candidates.iter() {
                let regex = match self.rule(rule) {
                    Rule::Match { regex, .. } => *regex,
                    Rule::Begin { begin, .. } => *begin,
                    Rule::Patterns(_) => continue,
                };
                consider(
                    self.search(regex, text, position, &mut memo),
                    Winner::Rule(rule),
                    regex,
                );
            }
            if let Some(end) = end.filter(|_| end_last) {
                consider(
                    self.search(end, text, position, &mut memo),
                    Winner::End,
                    end,
                );
            }
            let Some((start, winner, regex)) = best else {
                paint.fill(position, text.len(), frame.content);
                return;
            };
            let Some(region) = self.region(regex, text, position) else {
                paint.fill(position, text.len(), frame.content);
                return;
            };
            let (_, end) = region.pos(0).unwrap();
            paint.fill(position, start, frame.content);
            let depth = state.frames.len();
            match winner {
                Winner::End => {
                    paint.fill(start, end, frame.scope);
                    let captures = match self.rule(frame.rule) {
                        Rule::Begin { end_captures, .. } => end_captures.clone(),
                        _ => unreachable!(),
                    };
                    self.paint_captures(base, text, &region, &captures, frame.scope, paint);
                    if state.frames.len() > 1 {
                        state.frames.pop();
                    }
                }
                Winner::Rule(rule) => {
                    let groups = groups(&region);
                    match self.rule(rule) {
                        Rule::Match { name, captures, .. } => {
                            let name = name.clone();
                            let captures = captures.clone();
                            let category = match &name {
                                Some(name) => self.name_category(name, text, &groups),
                                None => None,
                            }
                            .or(frame.content);
                            paint.fill(start, end, category);
                            self.paint_captures(base, text, &region, &captures, category, paint);
                        }
                        Rule::Begin {
                            end: pattern,
                            name,
                            content_name,
                            begin_captures,
                            ..
                        } => {
                            let (pattern, name, content_name) =
                                (pattern.clone(), name.clone(), content_name.clone());
                            let captures = begin_captures.clone();
                            let scope = match &name {
                                Some(name) => self.name_category(name, text, &groups),
                                None => None,
                            }
                            .or(frame.content);
                            let content = match &content_name {
                                Some(name) => self.name_category(name, text, &groups),
                                None => None,
                            }
                            .or(scope);
                            paint.fill(start, end, scope);
                            self.paint_captures(base, text, &region, &captures, scope, paint);
                            state.frames.push(Frame {
                                rule,
                                end: Some(resolve_end(&pattern, text, &groups).into()),
                                scope,
                                content,
                            });
                        }
                        Rule::Patterns(_) => unreachable!(),
                    }
                }
            }
            if end > position {
                position = end;
                stalls = 0;
            } else if state.frames.len() > depth && stalls < 2 {
                // An empty begin may legitimately enter a rule, but not
                // over and over at the same place.
                stalls += 1;
            } else if state.frames.len() < depth {
                stalls += 1;
                if stalls > 4 {
                    let next = next_char(text, position);
                    paint.fill(position, next, frame.content);
                    position = next;
                    stalls = 0;
                }
            } else {
                if state.frames.len() > depth {
                    state.frames.pop();
                }
                let next = next_char(text, position);
                paint.fill(position, next, frame.content);
                position = next;
                stalls = 0;
            }
        }
        let content = state.frames.last().unwrap().content;
        paint.fill(position, text.len(), content);
    }
    fn paint_captures(
        &mut self,
        base: GrammarId,
        text: &str,
        region: &Region,
        captures: &Captures,
        outer: Option<Category>,
        paint: &mut Paint,
    ) {
        if captures.is_empty() {
            return;
        }
        let groups = groups(region);
        for (index, capture) in captures.iter().enumerate() {
            let (Some(capture), Some(Some((start, end)))) = (capture, groups.get(index)) else {
                continue;
            };
            let (start, end) = (*start, *end);
            if start >= end {
                continue;
            }
            let category = match &capture.name {
                Some(name) => self.name_category(name, text, &groups),
                None => None,
            };
            paint.overlay(start, end, category);
            if let Some(patterns) = capture.patterns {
                // Scan the captured text alone, as its own small document.
                let mut nested = State {
                    frames: vec![Frame {
                        rule: patterns,
                        end: None,
                        scope: category.or(outer),
                        content: category.or(outer),
                    }],
                };
                let mut inner = Paint(paint.0[..end].to_vec());
                self.scan(base, &text[..end], start, &mut nested, &mut inner);
                paint.0[start..end].copy_from_slice(&inner.0[start..end]);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn end_patterns_take_begin_captures_literally() {
        let text = "<<'E.F'";
        let groups = vec![Some((0, 7)), Some((3, 6))];
        assert_eq!(resolve_end("^\\1$", text, &groups), "^E\\.F$");
        assert_eq!(resolve_end("\\\\n\\2", text, &groups), "\\\\n");
    }
}
