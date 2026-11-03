//! Rust structure and indentation. Highlighting stays with the TextMate
//! grammar; this module answers what a grammar cannot: which brackets,
//! generic lists and closure parameters pair, and where a line goes in the
//! block style rustfmt writes. The text is lexed whole and kept for as long
//! as it does not change.
mod indent;
mod lexer;
mod structure;

use crate::{
    core::{EditError, Snapshot},
    language::{
        Comment, EnterAdvice, Group, IndentAdvice, IndentRequest, IndentTrigger, Item, Side,
        WhitespacePolicy, continuation,
    },
};
use lexer::Kind;
use std::sync::Arc;
use structure::Structure;

#[derive(Clone, Default)]
pub struct RustSession {
    analysis: Option<Arc<Structure>>,
}
impl RustSession {
    fn analyze(&mut self, snapshot: &Snapshot) -> Arc<Structure> {
        let text = snapshot.shared_text();
        match &self.analysis {
            Some(known) if Arc::ptr_eq(known.source(), &text) || **known.source() == *text => {
                known.clone()
            }
            _ => self.analysis.insert(Arc::new(Structure::new(text))).clone(),
        }
    }
    pub fn triggers(&self, ch: char) -> bool {
        matches!(
            ch,
            '}' | ')' | ']' | '{' | '.' | '?' | 'e' | '&' | '|' | '>'
        )
    }
    /// Whether a position is inside a comment or a literal; the end of a
    /// line comment counts as inside.
    pub fn in_literal(&mut self, snapshot: &Snapshot, position: usize) -> Result<bool, EditError> {
        if !snapshot.is_char_boundary(position) {
            return Err(EditError::InvalidRange);
        }
        let structure = self.analyze(snapshot);
        let tokens = &structure.tokens;
        Ok(tokens
            .get(tokens.partition_point(|t| t.range.end < position))
            .filter(|t| t.range.start < position)
            .is_some_and(|token| match token.kind {
                Kind::LineComment => true,
                Kind::BlockComment | Kind::Str | Kind::Char => {
                    position < token.range.end || token.unterminated
                }
                _ => false,
            }))
    }
    pub fn enclosing(&mut self, snapshot: &Snapshot, at: usize) -> Option<Group> {
        self.analyze(snapshot).enclosing(at)
    }
    pub fn item(&mut self, snapshot: &Snapshot, at: usize, side: Side) -> Option<Item> {
        self.analyze(snapshot).item(at, side)
    }
    pub fn enter_advice(
        &mut self,
        snapshot: &Snapshot,
        position: usize,
    ) -> Result<EnterAdvice, EditError> {
        if !snapshot.is_char_boundary(position) {
            return Err(EditError::InvalidRange);
        }
        let s = self.analyze(snapshot);
        let tokens = &s.tokens;
        let next = tokens.partition_point(|t| t.range.end < position);
        let inside = tokens.get(next).filter(|t| t.range.start < position);
        let verbatim = inside.is_some_and(|t| {
            matches!(t.kind, Kind::Str | Kind::Char) && (position < t.range.end || t.unterminated)
        });
        let comment = inside.filter(|t| t.is_comment()).map(|t| Comment {
            range: t.range.clone(),
            block: t.kind == Kind::BlockComment,
            unterminated: t.unterminated,
        });
        let right = s.first_after(position);
        let expand_pair = right
            .checked_sub(1)
            .filter(|&left| {
                s.tokens[left].kind == Kind::Open
                    && s.partner(left) == Some(right)
                    && s.source()[s.tokens[left].range.end..s.tokens[right].range.start]
                        .bytes()
                        .all(|b| matches!(b, b' ' | b'\t'))
            })
            .is_some();
        Ok(EnterAdvice {
            expand_pair,
            verbatim,
            continuation: continuation(snapshot, comment, position),
        })
    }
    pub fn indent(
        &mut self,
        snapshot: &Snapshot,
        request: IndentRequest,
        style: &WhitespacePolicy,
    ) -> Result<IndentAdvice, EditError> {
        let start = snapshot
            .line_start(request.line)
            .ok_or(EditError::InvalidRange)?;
        if snapshot.line_of(request.position) != Some(request.line) {
            return Err(EditError::InvalidRange);
        }
        let s = self.analyze(snapshot);
        if let IndentTrigger::Typed(ch) = request.trigger {
            // A typed character moves its line only as the start of the
            // first token there, which may decide where the line goes.
            let first = s.first_after(start);
            let Some(token) = s
                .tokens
                .get(first)
                .filter(|t| t.range.start >= start && t.range.contains(&request.position))
            else {
                return Ok(IndentAdvice::Unavailable);
            };
            let text = s.text(first);
            let moves = match ch {
                '}' | ')' | ']' => token.kind == Kind::Close,
                '{' => text == "{",
                '.' | '?' => text == ch.to_string(),
                'e' => matches!(text, "else" | "where") && token.range.end == request.position + 1,
                '&' | '|' => matches!(text, "&&" | "||" | "|"),
                '>' => matches!(text, ">" | "=>" | "->"),
                _ => false,
            };
            if !moves {
                return Ok(IndentAdvice::Unavailable);
            }
        }
        Ok(indent::indent(&s, snapshot, request.line, style))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn analysis_is_kept_while_the_text_is() {
        let mut session = RustSession::default();
        let snapshot = Snapshot::new("fn f() {}".into(), 0);
        let first = session.analyze(&snapshot);
        assert!(Arc::ptr_eq(&first, &session.analyze(&snapshot)));
        let same = Snapshot::new("fn f() {}".into(), 1);
        assert!(Arc::ptr_eq(&first, &session.analyze(&same)));
        let other = Snapshot::new("fn g() {}".into(), 2);
        assert!(!Arc::ptr_eq(&first, &session.analyze(&other)));
    }
}
