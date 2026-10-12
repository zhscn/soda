//! Logical navigation over rope chunks. A logical column adds the cell width
//! of each extended grapheme; font shaping and cross-grapheme ligatures are
//! handled by frontend layout rather than text coordinates.
use super::{Association, ByteOffset, EditError, LogicalColumn, Snapshot};
use std::num::NonZeroUsize;
use unicode_segmentation::{GraphemeCursor, GraphemeIncomplete, UnicodeSegmentation};
use unicode_width::UnicodeWidthStr;

fn ascii_width(byte: u8) -> usize {
    usize::from(byte >= 0x20 && byte != 0x7f)
}
fn cluster_width(cluster: &str, column: usize, tab_width: NonZeroUsize) -> usize {
    if cluster == "\t" {
        tab_width.get() - column % tab_width.get()
    } else if cluster.is_ascii() {
        cluster.bytes().map(ascii_width).sum()
    } else {
        cluster.width()
    }
}
pub fn column_width(text: &str, start: usize, tab_width: NonZeroUsize) -> usize {
    if text.is_ascii() {
        return text
            .split('\t')
            .enumerate()
            .fold(start, |column, (index, run)| {
                column
                    + if index == 0 {
                        0
                    } else {
                        tab_width.get() - column % tab_width.get()
                    }
                    + run.bytes().map(ascii_width).sum::<usize>()
            });
    }
    text.graphemes(true).fold(start, |column, cluster| {
        column + cluster_width(cluster, column, tab_width)
    })
}

enum Query {
    Next,
    Previous,
    Boundary,
}
enum Answer {
    Offset(Option<usize>),
    Boundary(bool),
}
/// Supply only the chunks and pre-context requested by the Unicode segmenter.
fn query(snapshot: &Snapshot, position: usize, query: Query) -> Result<Answer, EditError> {
    if !snapshot.is_char_boundary(position) {
        return Err(EditError::InvalidRange);
    }
    let mut cursor = GraphemeCursor::new(position, snapshot.len_bytes(), true);
    let (mut chunk, mut start) = snapshot.chunk_at_byte(position);
    loop {
        let result = match query {
            Query::Next => cursor.next_boundary(chunk, start).map(Answer::Offset),
            Query::Previous => cursor.prev_boundary(chunk, start).map(Answer::Offset),
            Query::Boundary => cursor.is_boundary(chunk, start).map(Answer::Boundary),
        };
        match result {
            Ok(answer) => return Ok(answer),
            Err(GraphemeIncomplete::PreContext(end)) => {
                let (context, context_start) = snapshot.chunk_at_byte(end - 1);
                cursor.provide_context(&context[..end - context_start], context_start);
            }
            Err(GraphemeIncomplete::NextChunk) => {
                (chunk, start) = snapshot.chunk_at_byte(start + chunk.len());
            }
            Err(GraphemeIncomplete::PrevChunk) => {
                (chunk, start) = snapshot.chunk_at_byte(start - 1);
            }
            Err(GraphemeIncomplete::InvalidOffset) => return Err(EditError::InvalidRange),
        }
    }
}
pub fn step_grapheme(
    snapshot: &Snapshot,
    position: ByteOffset,
    forward: bool,
) -> Result<ByteOffset, EditError> {
    let answer = query(
        snapshot,
        position.0,
        if forward {
            Query::Next
        } else {
            Query::Previous
        },
    )?;
    let Answer::Offset(offset) = answer else {
        unreachable!()
    };
    Ok(ByteOffset(offset.unwrap_or(position.0)))
}
pub fn clip_grapheme_offset(
    snapshot: &Snapshot,
    position: ByteOffset,
    association: Association,
) -> Result<ByteOffset, EditError> {
    let position = snapshot.clip_byte_offset(position, association);
    match query(snapshot, position.0, Query::Boundary)? {
        Answer::Boundary(true) => Ok(position),
        Answer::Boundary(false) => {
            step_grapheme(snapshot, position, association == Association::After)
        }
        _ => unreachable!(),
    }
}
pub fn deletion_range(
    snapshot: &Snapshot,
    position: ByteOffset,
    forward: bool,
) -> Result<std::ops::Range<usize>, EditError> {
    if !snapshot.is_char_boundary(position.0) {
        return Err(EditError::InvalidRange);
    }
    match query(snapshot, position.0, Query::Boundary)? {
        Answer::Boundary(false) => {
            Ok(step_grapheme(snapshot, position, false)?.0
                ..step_grapheme(snapshot, position, true)?.0)
        }
        Answer::Boundary(true) => {
            let other = step_grapheme(snapshot, position, forward)?.0;
            Ok(position.0.min(other)..position.0.max(other))
        }
        _ => unreachable!(),
    }
}

/// Iterates logical cells without materializing the line. Contiguous ASCII
/// spans can be handled directly; non-ASCII cluster boundaries use the rope cursor.
fn scan_columns(
    snapshot: &Snapshot,
    start: usize,
    end: usize,
    tab_width: NonZeroUsize,
    target: Option<usize>,
) -> (usize, usize) {
    let mut offset = start;
    let mut column = 0;
    let (mut chunk, mut chunk_start) = snapshot.chunk_at_byte(offset);
    while offset < end {
        if offset >= chunk_start + chunk.len() {
            (chunk, chunk_start) = snapshot.chunk_at_byte(offset);
        }
        let available = &chunk[offset - chunk_start..(end - chunk_start).min(chunk.len())];
        let bytes = available.as_bytes();
        // Keep the final ASCII scalar for boundary resolution: it may attach
        // to a combining character in this or the following chunk.
        let run = bytes
            .iter()
            .take_while(|&&byte| (b' '..=b'~').contains(&byte))
            .count()
            .saturating_sub(1);
        if run > 0 {
            let amount = target.map_or(run, |target| target.saturating_sub(column).min(run));
            offset += amount;
            column += amount;
            if amount < run {
                return (offset, column);
            }
            continue;
        }
        let (next_offset, width) = if bytes.len() >= 2 && bytes[0].is_ascii() && bytes[1].is_ascii()
        {
            (
                offset + 1,
                if bytes[0] == b'\t' {
                    tab_width.get() - column % tab_width.get()
                } else {
                    ascii_width(bytes[0])
                },
            )
        } else {
            let next_offset = step_grapheme(snapshot, ByteOffset(offset), true)
                .unwrap()
                .0
                .min(end);
            let slice = snapshot.byte_slice(offset..next_offset).unwrap();
            let width = match slice.as_str() {
                Some(cluster) => cluster_width(cluster, column, tab_width),
                None => cluster_width(&slice.to_string(), column, tab_width),
            };
            (next_offset, width)
        };
        let next = column + width;
        if target.is_some_and(|target| next > target) {
            return (offset, column);
        }
        offset = next_offset;
        column = next;
    }
    (offset, column)
}
pub fn logical_column_at(
    snapshot: &Snapshot,
    position: ByteOffset,
    tab_width: NonZeroUsize,
) -> Result<LogicalColumn, EditError> {
    let row = snapshot
        .line_of(position.0)
        .ok_or(EditError::InvalidRange)?;
    let range = snapshot.line_content_range(row).unwrap();
    let position = clip_grapheme_offset(
        snapshot,
        ByteOffset(position.0.min(range.end)),
        Association::Before,
    )?
    .0;
    Ok(LogicalColumn(
        scan_columns(snapshot, range.start, position, tab_width, None).1,
    ))
}
pub fn offset_at_logical_column(
    snapshot: &Snapshot,
    row: usize,
    target: LogicalColumn,
    tab_width: NonZeroUsize,
) -> Result<ByteOffset, EditError> {
    let range = snapshot
        .line_content_range(row)
        .ok_or(EditError::InvalidRange)?;
    Ok(ByteOffset(
        scan_columns(snapshot, range.start, range.end, tab_width, Some(target.0)).0,
    ))
}
