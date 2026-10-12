use super::{Language, language::LanguageSession};
use crate::{
    core::{Association, Change, EditError, EditorState, Selection, Snapshot, Transaction},
    language::{IndentAdvice, IndentRequest, IndentTrigger, NewlineIndent},
};

/// Compose one user replacement with corrections in its speculative snapshot.
/// The resulting transaction always addresses the original state, and its
/// selection is mapped through both edits rather than inferred from byte deltas.
struct InputEdit<'a> {
    base: &'a EditorState,
    input: Change,
    speculative: EditorState,
}
impl<'a> InputEdit<'a> {
    fn new(base: &'a EditorState, input: Change, caret: usize) -> Result<Self, EditError> {
        let mut tx = Transaction::new(base.snapshot().version(), vec![input.clone()]);
        tx.selection = Some(Selection::caret(caret));
        let (speculative, _) = base.apply(tx)?;
        Ok(Self {
            base,
            input,
            speculative,
        })
    }

    fn finish(self, corrections: Vec<Change>) -> Result<Transaction, EditError> {
        if corrections.is_empty() {
            let mut tx = Transaction::new(self.base.snapshot().version(), vec![self.input]);
            tx.selection = Some(self.speculative.selection());
            return Ok(tx);
        }
        let corrections =
            crate::core::ValidatedChanges::new(self.speculative.snapshot(), corrections)?;
        let caret = corrections
            .mapping
            .map(self.speculative.selection().head, Association::After);
        let changes = crate::core::compose_validated(
            self.base.snapshot(),
            &[self.input],
            self.speculative.snapshot().len_bytes(),
            &corrections.changes,
        );
        let mut tx = Transaction::new(self.base.snapshot().version(), changes);
        tx.selection = Some(Selection::caret(caret));
        Ok(tx)
    }
}

/// Validate language suggestions against their authorized line and whitespace.
fn prefix_changes(
    snapshot: &Snapshot,
    line: usize,
    prefix: String,
    auxiliary: Option<Change>,
    preserve_suffix: bool,
) -> Result<Vec<Change>, EditError> {
    let content = snapshot
        .line_content_range(line)
        .ok_or(EditError::InvalidRange)?;
    let start = snapshot.line_start(line).unwrap();
    let old = snapshot.leading_whitespace(line).unwrap();
    let length = if preserve_suffix { 0 } else { old.len_bytes() };
    let prefix_range = start..start + length;
    if !prefix.bytes().all(|b| matches!(b, b' ' | b'\t')) {
        return Err(EditError::InvalidRange);
    }
    let mut changes = Vec::new();
    if (preserve_suffix && !prefix.is_empty()) || (!preserve_suffix && old != prefix) {
        changes.push(Change::new(prefix_range.clone(), prefix));
    }
    if let Some(auxiliary) = auxiliary {
        if auxiliary.range.start < prefix_range.end
            || auxiliary.range.end > content.end
            || !auxiliary.insert.bytes().all(|b| matches!(b, b' ' | b'\t'))
            || !snapshot
                .byte_slice(auxiliary.range.clone())
                .is_some_and(|slice| slice.bytes().all(|b| matches!(b, b' ' | b'\t')))
        {
            return Err(EditError::InvalidRange);
        }
        if snapshot.byte_slice(auxiliary.range.clone()).unwrap() != auxiliary.insert {
            changes.push(auxiliary);
        }
    }
    Ok(changes)
}
fn advice_changes(
    snapshot: &Snapshot,
    line: usize,
    advice: IndentAdvice,
    enter: bool,
) -> Result<Vec<Change>, EditError> {
    match advice {
        IndentAdvice::Set { prefix, auxiliary } => {
            prefix_changes(snapshot, line, prefix, auxiliary, false)
        }
        IndentAdvice::Preserve {
            newline: NewlineIndent::Verbatim,
        } => Ok(vec![]),
        IndentAdvice::Preserve {
            newline: NewlineIndent::Inherit { preserve_suffix },
        } if enter => {
            let previous = snapshot
                .leading_whitespace(line.checked_sub(1).ok_or(EditError::InvalidRange)?)
                .ok_or(EditError::InvalidRange)?;
            prefix_changes(snapshot, line, previous.to_string(), None, preserve_suffix)
        }
        IndentAdvice::Unavailable if enter => {
            let previous = snapshot
                .leading_whitespace(line.checked_sub(1).ok_or(EditError::InvalidRange)?)
                .ok_or(EditError::InvalidRange)?;
            prefix_changes(snapshot, line, previous.to_string(), None, false)
        }
        _ => Ok(vec![]),
    }
}

pub(super) fn prepare_enter(
    state: &EditorState,
    language: &mut LanguageSession,
) -> Result<Transaction, EditError> {
    let range = state.selection().range();
    let removed = if range.is_empty() {
        state.clone()
    } else {
        state
            .apply(Transaction::new(
                state.snapshot().version(),
                vec![Change::new(range.clone(), "")],
            ))?
            .0
    };
    let advice = language.enter_advice(removed.snapshot(), range.start)?;
    let newline = if state
        .snapshot()
        .chunks()
        .any(|chunk| chunk.contains("\r\n"))
    {
        "\r\n"
    } else {
        "\n"
    };
    let inserted = if advice.expand_pair {
        newline.repeat(2)
    } else {
        newline.into()
    };
    let mut input = InputEdit::new(
        state,
        Change::new(range.clone(), inserted),
        range.start + newline.len(),
    )?;
    if advice.verbatim {
        return input.finish(vec![]);
    }
    let snapshot = input.speculative.snapshot();
    let position = input.speculative.selection().head;
    let line = snapshot.line_of(position).unwrap();
    let query = IndentRequest {
        line,
        position,
        trigger: IndentTrigger::Enter,
    };
    let indent = language.indent(snapshot, query)?;
    let consumes_prefix = matches!(
        indent,
        IndentAdvice::Set { .. }
            | IndentAdvice::Unavailable
            | IndentAdvice::Preserve {
                newline: NewlineIndent::Inherit {
                    preserve_suffix: false
                }
            }
    );
    let caret = position
        + if consumes_prefix {
            snapshot.leading_whitespace(line).unwrap().len_bytes()
        } else {
            0
        };
    let mut corrections = advice_changes(snapshot, line, indent, true)?;
    if advice.expand_pair {
        let query = IndentRequest {
            line: line + 1,
            position: snapshot.line_start(line + 1).unwrap(),
            trigger: IndentTrigger::Reindent,
        };
        corrections.extend(advice_changes(
            snapshot,
            line + 1,
            language.indent(snapshot, query)?,
            false,
        )?);
    }
    input.speculative = EditorState::from_snapshot(
        input.speculative.snapshot().clone(),
        Selection::caret(caret),
    )?;
    input.finish(corrections)
}

pub(super) fn prepare_char(
    state: &EditorState,
    ch: char,
    language: &mut LanguageSession,
) -> Result<Transaction, EditError> {
    let range = state.selection().range();
    let position = range.start;
    let input = InputEdit::new(
        state,
        Change::new(range, ch.to_string()),
        position + ch.len_utf8(),
    )?;
    if !language.triggers(ch) {
        return input.finish(vec![]);
    }
    let snapshot = input.speculative.snapshot();
    let line = snapshot.line_of(position).unwrap();
    let query = IndentRequest {
        line,
        position,
        trigger: IndentTrigger::Typed(ch),
    };
    let corrections = advice_changes(snapshot, line, language.indent(snapshot, query)?, false)?;
    input.finish(corrections)
}
pub(super) fn prepare_reindent(
    state: &EditorState,
    line: usize,
    language: &mut LanguageSession,
) -> Result<Transaction, EditError> {
    let position = state
        .snapshot()
        .line_start(line)
        .ok_or(EditError::InvalidRange)?;
    let query = IndentRequest {
        line,
        position,
        trigger: IndentTrigger::Reindent,
    };
    let changes = advice_changes(
        state.snapshot(),
        line,
        language.indent(state.snapshot(), query)?,
        false,
    )?;
    Ok(Transaction::new(state.snapshot().version(), changes))
}
pub(super) fn prepare_insert(state: &EditorState, text: String) -> Transaction {
    let range = state.selection().range();
    let caret = range.start + text.len();
    let changes = if range.is_empty() && text.is_empty() {
        vec![]
    } else {
        vec![Change::new(range, text)]
    };
    let mut tx = Transaction::new(state.snapshot().version(), changes);
    tx.selection = Some(Selection::caret(caret));
    tx
}

/// Stateless transaction planning for callers that manage their own state.
pub fn enter(state: &EditorState, language: impl Into<Language>) -> Result<Transaction, EditError> {
    prepare_enter(state, &mut LanguageSession::new(language.into()))
}
pub fn type_char(
    state: &EditorState,
    ch: char,
    language: impl Into<Language>,
) -> Result<Transaction, EditError> {
    prepare_char(state, ch, &mut LanguageSession::new(language.into()))
}
pub fn reindent(
    state: &EditorState,
    line: usize,
    language: impl Into<Language>,
) -> Result<Transaction, EditError> {
    prepare_reindent(state, line, &mut LanguageSession::new(language.into()))
}
