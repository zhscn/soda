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
            tx.selection = Some(caret_at(
                self.speculative.snapshot(),
                self.speculative.selection().head,
            )?);
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
        let (output, _) = self.base.apply(tx.clone())?;
        tx.selection = Some(caret_at(output.snapshot(), caret)?);
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

/// A document's newline is its first line terminator; text without one uses LF.
pub(super) fn detect_newline(snapshot: &Snapshot) -> &'static str {
    let (Some(line), Some(content)) = (snapshot.line_range(0), snapshot.line_content_range(0))
    else {
        return "\n";
    };
    if line.end - content.end == 2 {
        "\r\n"
    } else {
        "\n"
    }
}

pub(super) fn prepare_enter(
    state: &EditorState,
    newline: &str,
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
    // Structural indentation makes the indentation of a line left blank
    // meaningless; clear it rather than leave trailing whitespace behind.
    let structural = matches!(indent, IndentAdvice::Set { .. });
    let mut corrections = advice_changes(snapshot, line, indent, true)?;
    // A continued comment's marker follows the indentation the line gets as
    // code, and takes the place of the spaces the split left at its start.
    if !advice.continuation.is_empty() {
        let start = snapshot.line_start(line).unwrap();
        let indent = start + snapshot.leading_whitespace(line).unwrap().len_bytes();
        match corrections.iter_mut().find(|c| c.range.start == start) {
            Some(change) if change.range.end == indent => {
                change.insert.push_str(advice.continuation)
            }
            Some(_) => {}
            None => corrections.push(Change::new(
                start..indent,
                format!(
                    "{}{}",
                    snapshot.byte_slice(start..indent).unwrap(),
                    advice.continuation
                ),
            )),
        }
    }
    if structural
        && let Some(left) = line.checked_sub(1)
        && let Some(blank) = snapshot.line_content_range(left)
        && !blank.is_empty()
        && snapshot
            .byte_slice(blank.clone())
            .unwrap()
            .bytes()
            .all(|b| matches!(b, b' ' | b'\t'))
    {
        corrections.push(Change::new(blank, ""));
    }
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
    prepare_char_with(state, ch, None, language)
}
/// Types a character, followed by a closer that stays after the caret.
pub(super) fn prepare_char_with(
    state: &EditorState,
    ch: char,
    closer: Option<char>,
    language: &mut LanguageSession,
) -> Result<Transaction, EditError> {
    let range = state.selection().range();
    let position = range.start;
    let mut text = ch.to_string();
    text.extend(closer);
    let input = InputEdit::new(state, Change::new(range, text), position + ch.len_utf8())?;
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
/// Emacs's TAB, `indent-for-tab-command`: indents the caret's line as the
/// language would, wherever the caret is in it, or with a selection each
/// selected line, as `indent-region`. A caret in the leading whitespace
/// goes to the first non-blank; one in the text moves with it. Where the
/// language has no indentation to give, TAB inserts indentation, or with a
/// selection shifts the lines, as before.
pub(super) fn prepare_indent_for_tab(
    state: &EditorState,
    language: &mut LanguageSession,
) -> Result<Transaction, EditError> {
    let snapshot = state.snapshot();
    let range = state.selection().range();
    let first = snapshot
        .line_of(range.start)
        .ok_or(EditError::InvalidRange)?;
    let mut last = snapshot.line_of(range.end).ok_or(EditError::InvalidRange)?;
    if !range.is_empty() && last > first && snapshot.line_start(last) == Some(range.end) {
        last -= 1;
    }
    // Each line is placed in the text as the lines before it left it, so a
    // continuation follows its opening line's new place.
    let mut current = state.clone();
    let mut known = false;
    for line in first..=last {
        let start = current
            .snapshot()
            .line_start(line)
            .ok_or(EditError::InvalidRange)?;
        let query = IndentRequest {
            line,
            position: start,
            trigger: IndentTrigger::Reindent,
        };
        let advice = language.indent(current.snapshot(), query)?;
        known |= !matches!(advice, IndentAdvice::Unavailable);
        let changes = advice_changes(current.snapshot(), line, advice, false)?;
        if !changes.is_empty() {
            let tx = Transaction::new(current.snapshot().version(), changes);
            current = current.apply(tx)?.0;
        }
    }
    if !known {
        return Ok(if range.is_empty() {
            super::commands::insert_tab(state, false, language)?
        } else {
            super::commands::indent_selection(state, false, language)
        });
    }
    // One change a line, in the text as it was, so the edit is one step
    // and what is anchored elsewhere on the lines stays put.
    let after = current.snapshot();
    if after.line_count() != snapshot.line_count() {
        return Err(EditError::InvalidRange);
    }
    let mut changes = vec![];
    for line in first..=last {
        let old = snapshot.line_content_range(line).unwrap();
        let new = after.line_content_range(line).unwrap();
        let old_text = snapshot.byte_slice(old.clone()).unwrap().to_string();
        let new_text = after.byte_slice(new).unwrap().to_string();
        if old_text != new_text {
            changes.push(Change::new(old, new_text));
        }
    }
    let mut tx = Transaction::new(snapshot.version(), changes);
    if range.is_empty() {
        let leading = snapshot.leading_whitespace(first).unwrap().len_bytes();
        let line_start = snapshot.line_start(first).unwrap();
        let line_start_after = after.line_start(first).unwrap();
        let leading_after = after.leading_whitespace(first).unwrap().len_bytes();
        let head = if range.start <= line_start + leading {
            line_start_after + leading_after
        } else {
            range.start - (line_start + leading) + line_start_after + leading_after
        };
        tx.selection = Some(Selection::caret(head));
    }
    Ok(tx)
}
pub(super) fn caret_at(snapshot: &Snapshot, position: usize) -> Result<Selection, EditError> {
    Ok(Selection::caret(
        crate::core::clip_grapheme_offset(
            snapshot,
            crate::core::ByteOffset(position),
            Association::After,
        )?
        .0,
    ))
}

pub(super) fn normalize_caret(
    state: &EditorState,
    mut tx: Transaction,
) -> Result<Transaction, EditError> {
    let (output, _) = state.apply(tx.clone())?;
    tx.selection = Some(caret_at(output.snapshot(), output.selection().head)?);
    Ok(tx)
}

pub(super) fn prepare_insert(state: &EditorState, text: String) -> Result<Transaction, EditError> {
    let range = state.selection().range();
    if range.is_empty() && text.is_empty() {
        return Ok(Transaction::new(state.snapshot().version(), vec![]));
    }
    let caret = range.start + text.len();
    InputEdit::new(state, Change::new(range, text), caret)?.finish(vec![])
}

/// Stateless transaction planning for callers that manage their own state.
pub fn enter(state: &EditorState, language: impl Into<Language>) -> Result<Transaction, EditError> {
    prepare_enter(
        state,
        detect_newline(state.snapshot()),
        &mut LanguageSession::new(language.into()),
    )
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
