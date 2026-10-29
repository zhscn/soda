//! Brackets and quotes typed in pairs, as Emacs's electric-pair-mode: an
//! opening bracket brings its closing one when nothing but space or a
//! closer follows; typing a closer that is already next steps over it;
//! Backspace between an empty pair removes both; a selection is wrapped.
//! Quotes pair only in languages that say so, and nothing pairs inside a
//! comment or a literal.
use super::language::LanguageSession;
use crate::core::{Change, EditError, EditorState, Selection, Transaction};

const PAIRS: &[(char, char)] = &[('(', ')'), ('[', ']'), ('{', '}'), ('"', '"'), ('\'', '\'')];

fn closer(open: char) -> Option<char> {
    PAIRS.iter().find(|(o, _)| *o == open).map(|(_, c)| *c)
}
fn is_closer(ch: char) -> bool {
    PAIRS.iter().any(|(_, c)| *c == ch)
}
fn quote(ch: char) -> bool {
    matches!(ch, '"' | '\'')
}

/// What typing a character does instead of inserting it alone.
pub(super) enum Typed {
    /// Step over the identical closer that follows.
    Over,
    /// Insert the character and this closer, the caret between.
    Pair(char),
    /// Surround the selection with the character and this closer.
    Wrap(char),
}
pub(super) fn typed(
    state: &EditorState,
    ch: char,
    language: &mut LanguageSession,
) -> Result<Option<Typed>, EditError> {
    let snapshot = state.snapshot();
    let range = state.selection().range();
    if quote(ch) && !language.pairs_quotes() {
        return Ok(None);
    }
    if !range.is_empty() {
        return Ok(closer(ch).map(Typed::Wrap));
    }
    let position = range.start;
    let line = snapshot.line_of(position).unwrap();
    let end = snapshot.line_content_range(line).unwrap().end;
    let start = snapshot.line_start(line).unwrap();
    let next = snapshot
        .byte_slice(position..end)
        .and_then(|rest| rest.chars().next());
    let previous = snapshot
        .byte_slice(start..position)
        .and_then(|before| before.chars().last());
    if is_closer(ch) && next == Some(ch) {
        // A quote steps over its partner only from inside the literal.
        if !quote(ch) || language.in_literal(snapshot, position)? {
            return Ok(Some(Typed::Over));
        }
    }
    let Some(close) = closer(ch) else {
        return Ok(None);
    };
    let free =
        next.is_none_or(|next| next.is_whitespace() || is_closer(next) || ";,".contains(next));
    // `don't` and `x'` keep a lone quote.
    let after_word =
        quote(ch) && previous.is_some_and(|p| p.is_alphanumeric() || p == '_' || quote(p));
    if !free || after_word || language.in_literal(snapshot, position)? {
        return Ok(None);
    }
    Ok(Some(Typed::Pair(close)))
}
/// Builds the transaction for stepping over a closer or wrapping a selection.
pub(super) fn transaction(state: &EditorState, ch: char, typed: &Typed) -> Option<Transaction> {
    let snapshot = state.snapshot();
    let range = state.selection().range();
    match typed {
        Typed::Over => {
            let mut tx = Transaction::new(snapshot.version(), vec![]);
            tx.selection = Some(Selection::caret(range.start + ch.len_utf8()));
            Some(tx)
        }
        Typed::Wrap(close) => {
            let changes = vec![
                Change::new(range.start..range.start, ch.to_string()),
                Change::new(range.end..range.end, close.to_string()),
            ];
            let mut tx = Transaction::new(snapshot.version(), changes);
            let inner = range.start + ch.len_utf8()..range.end + ch.len_utf8();
            let selection = state.selection();
            tx.selection = Some(if selection.head >= selection.anchor {
                Selection {
                    anchor: inner.start,
                    head: inner.end,
                }
            } else {
                Selection {
                    anchor: inner.end,
                    head: inner.start,
                }
            });
            Some(tx)
        }
        Typed::Pair(_) => None,
    }
}
/// The range Backspace removes when the caret sits inside an empty pair.
pub(super) fn empty_pair(
    state: &EditorState,
    language: &LanguageSession,
) -> Option<std::ops::Range<usize>> {
    let snapshot = state.snapshot();
    let range = state.selection().range();
    if !range.is_empty() || range.start == 0 {
        return None;
    }
    let position = range.start;
    let line = snapshot.line_of(position)?;
    let start = snapshot.line_start(line)?;
    let end = snapshot.line_content_range(line)?.end;
    let open = snapshot.byte_slice(start..position)?.chars().last()?;
    let close = snapshot.byte_slice(position..end)?.chars().next()?;
    if quote(open) && !language.pairs_quotes() {
        return None;
    }
    (closer(open) == Some(close)).then(|| position - open.len_utf8()..position + close.len_utf8())
}
