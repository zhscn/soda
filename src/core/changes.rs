use super::{Change, EditError, EditorState, Snapshot, Transaction};
use std::ops::Range;

#[derive(Clone)]
enum Piece {
    Original(Range<usize>),
    Inserted(String),
}
impl Piece {
    fn len(&self) -> usize {
        match self {
            Self::Original(range) => range.len(),
            Self::Inserted(text) => text.len(),
        }
    }
    fn slice(&self, range: Range<usize>) -> Self {
        match self {
            Self::Original(source) => {
                Self::Original(source.start + range.start..source.start + range.end)
            }
            Self::Inserted(text) => Self::Inserted(text[range].to_owned()),
        }
    }
}
fn append_slice(output: &mut Vec<Piece>, pieces: &[Piece], range: Range<usize>) {
    let mut offset = 0;
    for piece in pieces {
        let start = range.start.max(offset);
        let end = range.end.min(offset + piece.len());
        if start < end {
            output.push(piece.slice(start - offset..end - offset));
        }
        offset += piece.len();
        if offset >= range.end {
            break;
        }
    }
}
fn apply(pieces: &[Piece], changes: &[Change], length: usize) -> Vec<Piece> {
    let mut output = Vec::new();
    let mut position = 0;
    for change in changes {
        append_slice(&mut output, pieces, position..change.range.start);
        if !change.insert.is_empty() {
            output.push(Piece::Inserted(change.insert.clone()));
        }
        position = change.range.end;
    }
    append_slice(&mut output, pieces, position..length);
    output
}

/// Compose sequential edits while preserving every surviving original range.
/// The second set addresses the result of the first. All offsets are UTF-8 bytes.
pub fn compose_changes(
    base: &Snapshot,
    first: &[Change],
    second: &[Change],
) -> Result<Vec<Change>, EditError> {
    let state = EditorState::from_snapshot(base.with_version(0), super::Selection::caret(0))?;
    let mut first = first.to_vec();
    first.sort_by_key(|change| change.range.start);
    let (middle, _) = state.apply(Transaction::new(0, first.clone()))?;
    let mut second = second.to_vec();
    second.sort_by_key(|change| change.range.start);
    middle.apply(Transaction::new(
        middle.snapshot().version(),
        second.clone(),
    ))?;
    let pieces = apply(
        &[Piece::Original(0..base.len_bytes())],
        &first,
        base.len_bytes(),
    );
    let pieces = apply(&pieces, &second, middle.snapshot().len_bytes());
    let mut changes = Vec::new();
    let mut position = 0;
    let mut inserted = String::new();
    for piece in pieces {
        match piece {
            Piece::Inserted(text) => inserted.push_str(&text),
            Piece::Original(range) => {
                if position != range.start || !inserted.is_empty() {
                    changes.push(Change::new(
                        position..range.start,
                        std::mem::take(&mut inserted),
                    ));
                }
                position = range.end;
            }
        }
    }
    if position != base.len_bytes() || !inserted.is_empty() {
        changes.push(Change::new(position..base.len_bytes(), inserted));
    }
    Ok(changes)
}

/// Invert validated, sorted changes using only replaced slices of the base.
pub(crate) fn invert_changes(base: &Snapshot, changes: &[Change]) -> Vec<Change> {
    let mut removed = 0;
    let mut inserted = 0;
    let mut inverse: Vec<Change> = Vec::new();
    for change in changes {
        let start = change.range.start - removed + inserted;
        removed += change.range.len();
        inserted += change.insert.len();
        let next = Change::new(
            start..start + change.insert.len(),
            base.byte_slice(change.range.clone()).unwrap().to_string(),
        );
        if let Some(previous) = inverse
            .last_mut()
            .filter(|previous| previous.range.end == next.range.start)
        {
            // Adjacent deletions produce insertions at the same result offset.
            // Joining them keeps the inverse transaction unambiguous.
            previous.range.end = next.range.end;
            previous.insert.push_str(&next.insert);
        } else {
            inverse.push(next);
        }
    }
    inverse
}
