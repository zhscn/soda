//! Document-local C++ analysis and editing suggestions. All queries are read-only
//! with respect to the document; a cloned session isolates speculative analysis.
use super::{
    CppRules, IndentRole, SyntaxTree, TokenKind as K, compute_indent, lex,
    lexer::{significant_after, significant_before, spanning, token_at},
    parse_snapshot_with_options,
};
use crate::{
    core::{EditError, Snapshot},
    language::{EnterAdvice, IndentAdvice, IndentRequest, IndentTrigger, NewlineIndent},
};
use std::sync::Arc;

#[derive(Clone)]
pub struct CppSession {
    rules: Arc<CppRules>,
    analysis: Option<Arc<SyntaxTree>>,
    work: Option<super::AnalysisWork>,
}
/// What continues a comment that Enter splits or ends: the marker of a
/// line comment that starts its line, or the `*` of a block comment whose
/// lines start with one. Comments after code end with the line.
fn continuation(
    snapshot: &Snapshot,
    tokens: &[super::lexer::Token],
    position: usize,
) -> &'static str {
    let Some(token) = tokens
        .get(tokens.partition_point(|t| t.range.end < position))
        .filter(|t| t.range.start < position)
        .filter(|t| matches!(t.kind, K::LineComment | K::BlockComment))
    else {
        return "";
    };
    // Slices only: the whole text may not be materialized.
    let slice = |range: std::ops::Range<usize>| snapshot.byte_slice(range).unwrap().to_string();
    let line = snapshot.line_of(position).unwrap();
    let line_start = snapshot.line_start(line).unwrap();
    let line_end = snapshot.line_content_range(line).unwrap().end;
    let before = slice(line_start..position);
    let after = slice(position..line_end);
    let lead = |start: usize| start >= line_start && slice(line_start..start).trim().is_empty();
    // Markers are ASCII; a longer prefix may end inside a character.
    let mut head = token.range.end.min(token.range.start + 4);
    while !snapshot.is_char_boundary(head) {
        head -= 1;
    }
    let comment = slice(token.range.start..head);
    match token.kind {
        K::LineComment if lead(token.range.start) => {
            let marker = ["/// ", "//! ", "// ", "///", "//!", "//"]
                .into_iter()
                .find(|marker| comment.starts_with(marker))
                .unwrap();
            if position < token.range.start + marker.len().min(comment.len()) {
                return "";
            }
            marker
        }
        K::BlockComment
            if position > token.range.start + 1
                && (position + 2 <= token.range.end || token.unterminated) =>
        {
            let closing = after.trim_start().starts_with("*/");
            let opening_line = snapshot.line_of(token.range.start) == Some(line);
            if opening_line {
                // The new line takes this line's indentation, one space short
                // of the stars below `/*`.
                match (lead(token.range.start), closing) {
                    (false, _) => "",
                    (true, true) => " ",
                    (true, false) => " * ",
                }
            } else if before.trim_start().starts_with('*') {
                if closing { "" } else { "* " }
            } else {
                ""
            }
        }
        _ => "",
    }
}
impl CppSession {
    pub fn new(rules: Arc<CppRules>) -> Self {
        Self {
            rules,
            analysis: None,
            work: None,
        }
    }
    pub fn rules(&self) -> &Arc<CppRules> {
        &self.rules
    }
    pub fn set_rules(&mut self, rules: Arc<CppRules>) {
        if self.rules.parser_options() != rules.parser_options() {
            self.invalidate();
        }
        self.rules = rules;
    }
    pub fn invalidate(&mut self) {
        self.analysis = None;
        self.work = None;
    }
    pub fn analysis_work(&self) -> Option<super::AnalysisWork> {
        self.work
    }
    pub fn triggers(&self, ch: char) -> bool {
        self.rules.enabled() && matches!(ch, ':' | '{' | '}' | '#' | 'e' | 'f')
    }
    fn matches(&self, snapshot: &Snapshot) -> bool {
        self.analysis.as_ref().is_some_and(|tree| {
            std::ptr::eq(tree.source(), snapshot.text()) || tree.source() == snapshot.text()
        })
    }
    fn analyze(&mut self, snapshot: &Snapshot) -> Arc<SyntaxTree> {
        if !self.matches(snapshot) {
            let full = || {
                let tree = parse_snapshot_with_options(snapshot, self.rules.parser_options());
                let work = super::AnalysisWork {
                    strategy: super::ParseStrategy::Full,
                    scanned_bytes: snapshot.text().len(),
                    reparsed_tokens: tree.tokens().len(),
                    reused_nodes: 0,
                    fallback: None,
                };
                (tree, work)
            };
            let (tree, work) = match &self.analysis {
                // Repair defects are found by differential tests in debug
                // builds; a release build pays one full parse instead of
                // losing the user's unsaved buffers.
                Some(previous) => std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    super::parser::reparse(previous, snapshot.shared_text())
                }))
                .unwrap_or_else(|panic| {
                    if cfg!(debug_assertions) {
                        std::panic::resume_unwind(panic)
                    }
                    full()
                }),
                None => full(),
            };
            self.analysis = Some(Arc::new(tree));
            self.work = Some(work);
        }
        self.analysis.as_ref().unwrap().clone()
    }
    /// Whether a position is inside a comment or a string or character
    /// literal; the end of a line comment counts as inside.
    pub fn in_literal(&mut self, snapshot: &Snapshot, position: usize) -> Result<bool, EditError> {
        if !snapshot.is_char_boundary(position) {
            return Err(EditError::InvalidRange);
        }
        let known = self.analysis.is_some().then(|| self.analyze(snapshot));
        let scanned;
        let tokens = match &known {
            Some(tree) => tree.tokens(),
            None => {
                scanned = lex(snapshot.text());
                &scanned
            }
        };
        Ok(tokens
            .get(tokens.partition_point(|t| t.range.end < position))
            .filter(|t| t.range.start < position)
            .is_some_and(|token| match token.kind {
                K::LineComment => true,
                K::BlockComment | K::StringLiteral | K::RawStringLiteral | K::CharacterLiteral => {
                    position < token.range.end || token.unterminated
                }
                _ => false,
            }))
    }
    pub fn enter_advice(
        &mut self,
        snapshot: &Snapshot,
        position: usize,
    ) -> Result<EnterAdvice, EditError> {
        if !snapshot.is_char_boundary(position) {
            return Err(EditError::InvalidRange);
        }
        let known = self.analysis.is_some().then(|| self.analyze(snapshot));
        let scanned;
        let tokens = match &known {
            Some(tree) => tree.tokens(),
            None => {
                scanned = lex(snapshot.text());
                &scanned
            }
        };
        let verbatim = spanning(tokens, position).is_some_and(|token| {
            matches!(
                token.kind,
                K::RawStringLiteral | K::StringLiteral | K::CharacterLiteral
            )
        });
        let left = significant_before(tokens, position).map(|index| (index, &tokens[index]));
        let right = significant_after(tokens, position).map(|index| &tokens[index]);
        let expand_pair = match (left, right) {
            (Some((index, left)), Some(right))
                if left.kind == K::LBrace
                    && right.kind == K::RBrace
                    && snapshot.text()[left.range.end..right.range.start]
                        .bytes()
                        .all(|b| matches!(b, b' ' | b'\t')) =>
            {
                let tree = known.clone().unwrap_or_else(|| self.analyze(snapshot));
                tree.range(tree.token_owner(index)).end == right.range.end
            }
            _ => false,
        };
        Ok(EnterAdvice {
            expand_pair,
            verbatim,
            continuation: continuation(snapshot, tokens, position),
        })
    }
    pub fn indent(
        &mut self,
        snapshot: &Snapshot,
        request: IndentRequest,
    ) -> Result<IndentAdvice, EditError> {
        let start = snapshot
            .line_start(request.line)
            .ok_or(EditError::InvalidRange)?;
        if snapshot.line_of(request.position) != Some(request.line) {
            return Err(EditError::InvalidRange);
        }
        // PP branch keywords end in e/f. Filter ordinary typing before parsing;
        // finishing endif/else/elif changes the current directive's own level.
        let pp_word = matches!(request.trigger, IndentTrigger::Typed('e' | 'f'));
        if pp_word {
            let prefix = snapshot.byte_slice(start..request.position).unwrap();
            if prefix.bytes().find(|b| !matches!(b, b' ' | b'\t')) != Some(b'#') {
                return Ok(IndentAdvice::Unavailable);
            }
        } else if let IndentTrigger::Typed(ch) = request.trigger
            && ch != ':'
            && !snapshot
                .byte_slice(start..request.position)
                .unwrap()
                .bytes()
                .all(|b| matches!(b, b' ' | b'\t'))
        {
            return Ok(IndentAdvice::Unavailable);
        }
        let tree = self.analyze(snapshot);
        if pp_word {
            if !token_at(tree.tokens(), request.position).is_some_and(|token| {
                let word = &tree.source()[token.range.clone()];
                token.preprocessor
                    && word
                        .bytes()
                        .next()
                        .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
                    && word.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            }) {
                return Ok(IndentAdvice::Unavailable);
            }
        } else if let IndentTrigger::Typed(ch) = request.trigger {
            let expected = match ch {
                ':' => K::Colon,
                '{' => K::LBrace,
                '}' => K::RBrace,
                '#' => K::PreprocessorHash,
                _ => return Ok(IndentAdvice::Unavailable),
            };
            if !token_at(tree.tokens(), request.position).is_some_and(|token| {
                token.range.start == request.position && token.kind == expected
            }) {
                return Ok(IndentAdvice::Unavailable);
            }
        }
        let decision = compute_indent(snapshot, &tree, request.line, &self.rules)?;
        if pp_word && decision.role != IndentRole::PreprocessorDirective {
            return Ok(IndentAdvice::Unavailable);
        }
        if decision.preserve {
            let newline = match decision.role {
                IndentRole::PreservedBlockComment | IndentRole::PreservedMacro => {
                    NewlineIndent::Inherit {
                        preserve_suffix: true,
                    }
                }
                IndentRole::Opaque if !self.rules.enabled() => NewlineIndent::Inherit {
                    preserve_suffix: false,
                },
                _ => NewlineIndent::Verbatim,
            };
            return Ok(IndentAdvice::Preserve { newline });
        }
        if request.trigger == IndentTrigger::Typed('{') && decision.role != IndentRole::OpeningToken
        {
            return Ok(IndentAdvice::Unavailable);
        }
        if request.trigger == IndentTrigger::Typed(':')
            && !matches!(
                decision.role,
                IndentRole::CaseLabel
                    | IndentRole::AccessSpecifierLabel
                    | IndentRole::ConstructorInitializerIntro
            )
        {
            return Ok(IndentAdvice::Unavailable);
        }
        Ok(IndentAdvice::Set {
            prefix: decision.whitespace,
            auxiliary: decision.directive_spacing,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cpp::CppStyle;

    #[test]
    fn analysis_reuse_depends_on_text_and_grammar_and_forks_are_isolated() {
        let snapshot = Snapshot::new("void f() {}".into(), 0);
        let mut session = CppSession::new(Arc::new(CppStyle::default().compile().unwrap()));
        let first = session.analyze(&snapshot);
        let style = CppStyle {
            indent_width: 2,
            ..CppStyle::default()
        };
        session.set_rules(Arc::new(style.compile().unwrap()));
        assert!(Arc::ptr_eq(&first, &session.analyze(&snapshot)));
        let mut fork = session.clone();
        fork.analyze(&Snapshot::new("int value;".into(), 1));
        assert!(Arc::ptr_eq(&first, &session.analyze(&snapshot)));
        session.invalidate();
        assert!(!Arc::ptr_eq(&first, &session.analyze(&snapshot)));
        let mut style = style;
        style.parser.loop_macros.push("REPEAT".into());
        session.set_rules(Arc::new(style.compile().unwrap()));
        assert!(session.analysis.is_none());
        // A distinct text snapshot always requires new structure analysis.
        let current = session.analyze(&snapshot);
        assert!(!Arc::ptr_eq(
            &current,
            &session.analyze(&Snapshot::new("int x;".into(), 2))
        ));
    }
}
