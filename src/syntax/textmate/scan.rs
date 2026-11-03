//! Line scanning with a rule stack, following vscode-textmate: at each
//! position the earliest match among the frame's patterns and its end pattern
//! wins, ties going to the earlier pattern with the end pattern first unless
//! `applyEndPatternLast` is set. Injections whose selectors match the
//! stack's scope names compete with the frame's patterns; they win an earlier
//! match, and a tie when their priority is `L:`.
use super::{Captures, GrammarId, Injection, Registry, Rule, RuleId, selector::Priority};
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
    /// Scope names of `name` and `contentName`, which injections select by;
    /// the root frame's name is the grammar's scope.
    names: Option<Arc<str>>,
    content_names: Option<Arc<str>>,
    /// Whether the begin match reached the end of its line, which anchors
    /// `\G` at the start of the next line.
    eol: bool,
}
/// The scope names of a stack, outermost first.
fn scope_names(frames: &[Frame]) -> Vec<&str> {
    frames
        .iter()
        .flat_map(|frame| [&frame.names, &frame.content_names])
        .flatten()
        .flat_map(|names| names.split_whitespace())
        .collect()
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
                names: Some(registry.scope(grammar).clone()),
                content_names: None,
                eol: false,
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

/// How a frame was entered within the line being scanned.
#[derive(Clone, Copy, Default)]
struct Entry {
    entered: Option<usize>,
    anchor: Option<usize>,
}
/// The stack a match is in and the category around it, for its captures.
struct Within<'a>(&'a [Frame], Option<Category>);
/// The injections selected for a stack of this depth with this top frame.
struct Selected {
    depth: usize,
    top: Frame,
    rules: Vec<(RuleId, Priority)>,
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
        let (position, anchor) = self.check_while(base, &text, state, &mut paint);
        self.scan(base, &text, position, anchor, state, &mut paint);
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
    /// Returns where scanning continues and the anchor there.
    fn check_while(
        &mut self,
        base: GrammarId,
        text: &str,
        state: &mut State,
        paint: &mut Paint,
    ) -> (usize, Option<usize>) {
        let mut position = 0;
        let mut anchor = state.frames.last().unwrap().eol.then_some(0);
        let mut index = 1;
        while index < state.frames.len() {
            let frame = state.frames[index].clone();
            let Rule::Begin { while_: true, .. } = self.rule(frame.rule) else {
                index += 1;
                continue;
            };
            let id = self.regex_id(frame.end.as_deref().unwrap_or(""));
            let id = self.at(id, position, anchor);
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
            let stack = &state.frames[..=index];
            self.paint_captures(
                base,
                text,
                &region,
                &captures,
                Within(stack, frame.scope),
                paint,
            );
            position = end;
            anchor = Some(end);
            index += 1;
        }
        (position, anchor)
    }
    fn search(
        &mut self,
        regex: usize,
        text: &str,
        position: usize,
        memo: &mut Memo,
    ) -> Option<usize> {
        if !self.regexes[regex].anchored
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
        mut anchor: Option<usize>,
        state: &mut State,
        paint: &mut Paint,
    ) {
        let mut memo = Memo::new();
        // Per frame: where it was entered and the anchor to restore when it
        // pops. Frames from earlier lines have neither.
        let mut entries: Vec<Entry> = vec![Entry::default(); state.frames.len()];
        let injections = self.injections(base);
        // The injections whose selectors match the stack. Each step pushes
        // or pops at most one frame, so the depth and the top frame tell
        // whether the stack changed since the last step.
        let mut active: Option<Selected> = None;
        // Scanning goes on at the end of the line, where empty matches can
        // still enter rules, as in vscode-textmate.
        for _ in 0..STEP_LIMIT {
            let frame = state.frames.last().unwrap().clone();
            if !injections.is_empty()
                && active
                    .as_ref()
                    .is_none_or(|a| a.depth != state.frames.len() || a.top != frame)
            {
                active = Some(Selected {
                    depth: state.frames.len(),
                    top: frame.clone(),
                    rules: select(&injections, &state.frames),
                });
            }
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
                (Some(source), true) => {
                    let id = self.regex_id(source);
                    Some(self.at(id, position, anchor))
                }
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
                let regex = self.at(regex, position, anchor);
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
            if let Some(active) = &active
                && let Some(injected) =
                    self.injected(&active.rules, base, text, (position, anchor), &mut memo)
                && best.as_ref().is_none_or(|(start, _, _)| {
                    injected.0 < *start || (injected.0 == *start && injected.3 == Priority::Left)
                })
            {
                best = Some((injected.0, Winner::Rule(injected.1), injected.2));
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
            let mut popped_here = false;
            match winner {
                Winner::End => {
                    paint.fill(start, end, frame.scope);
                    let captures = match self.rule(frame.rule) {
                        Rule::Begin { end_captures, .. } => end_captures.clone(),
                        _ => unreachable!(),
                    };
                    let stack = &state.frames;
                    self.paint_captures(
                        base,
                        text,
                        &region,
                        &captures,
                        Within(stack, frame.scope),
                        paint,
                    );
                    if state.frames.len() > 1 {
                        state.frames.pop();
                        let entry = entries.pop().unwrap();
                        anchor = entry.anchor;
                        popped_here = entry.entered == Some(position);
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
                            let stack = &state.frames;
                            self.paint_captures(
                                base,
                                text,
                                &region,
                                &captures,
                                Within(stack, category),
                                paint,
                            );
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
                            let (scope, names) = self.name_scope(name.as_ref(), text, &groups);
                            let scope = scope.or(frame.content);
                            let (content, content_names) =
                                self.name_scope(content_name.as_ref(), text, &groups);
                            let content = content.or(scope);
                            paint.fill(start, end, scope);
                            let entered = Frame {
                                rule,
                                end: Some(resolve_end(&pattern, text, &groups).into()),
                                scope,
                                content: scope,
                                names,
                                content_names: None,
                                eol: end == text.len(),
                            };
                            entries.push(Entry {
                                entered: Some(position),
                                anchor,
                            });
                            anchor = Some(end);
                            // Begin captures are inside the rule's name but
                            // not its content name.
                            state.frames.push(entered);
                            let stack = &state.frames;
                            self.paint_captures(
                                base,
                                text,
                                &region,
                                &captures,
                                Within(stack, scope),
                                paint,
                            );
                            let entered = state.frames.last_mut().unwrap();
                            entered.content = content;
                            entered.content_names = content_names;
                        }
                        Rule::Patterns(_) => unreachable!(),
                    }
                }
            }
            if end > position {
                position = end;
                continue;
            }
            // Without advancing, following vscode-textmate: entering a rule is
            // fine unless a frame entered here already has the same rule, and
            // leaving one is fine unless it was entered here. Anything else
            // would loop, so the rule is undone and a character skipped.
            if state.frames.len() > depth {
                let rule = state.frames.last().unwrap().rule;
                let looped = (0..depth)
                    .rev()
                    .take_while(|&index| entries[index].entered == Some(position))
                    .any(|index| state.frames[index].rule == rule);
                if !looped {
                    continue;
                }
                state.frames.pop();
                anchor = entries.pop().unwrap().anchor;
            } else if state.frames.len() < depth && !popped_here {
                continue;
            }
            if position == text.len() {
                return;
            }
            let next = next_char(text, position);
            paint.fill(position, next, frame.content);
            position = next;
        }
        let content = state.frames.last().unwrap().content;
        paint.fill(position, text.len(), content);
    }
    /// The earliest match among the selected injections, the first one on
    /// a tie: its start, rule, regex and priority.
    fn injected(
        &mut self,
        selected: &[(RuleId, Priority)],
        base: GrammarId,
        text: &str,
        (position, anchor): (usize, Option<usize>),
        memo: &mut Memo,
    ) -> Option<(usize, RuleId, usize, Priority)> {
        let mut best: Option<(usize, RuleId, usize, Priority)> = None;
        for &(injection, priority) in selected {
            for &rule in self.candidates(injection, base).iter() {
                let regex = match self.rule(rule) {
                    Rule::Match { regex, .. } => *regex,
                    Rule::Begin { begin, .. } => *begin,
                    Rule::Patterns(_) => continue,
                };
                let regex = self.at(regex, position, anchor);
                if let Some(start) = self.search(regex, text, position, memo)
                    && best.as_ref().is_none_or(|(s, ..)| start < *s)
                {
                    best = Some((start, rule, regex, priority));
                    if start == position {
                        return best;
                    }
                }
            }
        }
        best
    }
    fn paint_captures(
        &mut self,
        base: GrammarId,
        text: &str,
        region: &Region,
        captures: &Captures,
        Within(stack, outer): Within,
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
            let Some(patterns) = capture.patterns else {
                let category = match &capture.name {
                    Some(name) => self.name_category(name, text, &groups),
                    None => None,
                };
                paint.overlay(start, end, category);
                continue;
            };
            let (category, names) = self.name_scope(capture.name.as_ref(), text, &groups);
            paint.overlay(start, end, category);
            {
                // Scan the captured text alone, as its own small document,
                // on top of the stack so injections see where it is.
                let mut frames = stack.to_vec();
                frames.push(Frame {
                    rule: patterns,
                    end: None,
                    scope: category.or(outer),
                    content: category.or(outer),
                    names,
                    content_names: None,
                    eol: false,
                });
                let mut nested = State { frames };
                let mut inner = Paint(paint.0[..end].to_vec());
                // As in vscode-textmate, `\G` has no anchor in captures.
                self.scan(base, &text[..end], start, None, &mut nested, &mut inner);
                paint.0[start..end].copy_from_slice(&inner.0[start..end]);
            }
        }
    }
}

/// The injections whose selectors match the stack.
fn select(injections: &[Injection], frames: &[Frame]) -> Vec<(RuleId, Priority)> {
    let scopes = scope_names(frames);
    injections
        .iter()
        .filter(|injection| injection.matches(&scopes))
        .map(|injection| (injection.rule, injection.priority))
        .collect()
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
