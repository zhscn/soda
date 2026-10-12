//! Logical text navigation. Visual rows, bidi and pixels belong to a frontend.
use super::{EditError, Snapshot};
use std::num::NonZeroUsize;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

pub fn column_width(text: &str, start: usize, tab_width: NonZeroUsize) -> usize {
    text.split('\t')
        .enumerate()
        .fold(start, |column, (index, run)| {
            column
                + if index == 0 {
                    0
                } else {
                    tab_width.get() - column % tab_width.get()
                }
                + run.width()
        })
}
pub fn column_at(
    snapshot: &Snapshot,
    position: usize,
    tab_width: NonZeroUsize,
) -> Result<usize, EditError> {
    let line = snapshot.line_of(position).ok_or(EditError::InvalidRange)?;
    let range = snapshot.line_content_range(line).unwrap();
    Ok(column_width(
        &snapshot
            .byte_slice(range.start..position.min(range.end))
            .unwrap()
            .to_string(),
        0,
        tab_width,
    ))
}
pub fn position_at_column(
    snapshot: &Snapshot,
    line: usize,
    target: usize,
    tab_width: NonZeroUsize,
) -> Result<usize, EditError> {
    let text = snapshot.line(line).ok_or(EditError::InvalidRange)?;
    let start = snapshot.line_start(line).unwrap();
    let mut column = 0;
    for (offset, cluster) in text.grapheme_indices(true) {
        let next = column_width(cluster, column, tab_width);
        if next > target {
            return Ok(start + offset);
        }
        column = next;
    }
    Ok(start + text.len())
}
pub fn step_grapheme(
    snapshot: &Snapshot,
    position: usize,
    forward: bool,
) -> Result<usize, EditError> {
    let line = snapshot.line_of(position).ok_or(EditError::InvalidRange)?;
    let range = snapshot.line_content_range(line).unwrap();
    if forward && position >= range.end {
        return Ok(snapshot
            .line_start(line + 1)
            .unwrap_or(snapshot.len_bytes()));
    }
    if !forward && position <= range.start {
        return Ok(if line == 0 {
            0
        } else {
            snapshot.line_content_range(line - 1).unwrap().end
        });
    }
    if !forward && position > range.end {
        return Ok(range.end);
    }
    let text = snapshot.line(line).unwrap();
    let relative = position - range.start;
    let offset = if forward {
        text.grapheme_indices(true)
            .map(|(offset, cluster)| offset + cluster.len())
            .find(|&end| end > relative)
            .unwrap_or(text.len())
    } else {
        text.grapheme_indices(true)
            .map(|(offset, _)| offset)
            .take_while(|&offset| offset < relative)
            .last()
            .unwrap_or(0)
    };
    Ok(range.start + offset)
}

/// A deletion starting inside a grapheme or CRLF consumes the whole cluster.
pub fn deletion_range(
    snapshot: &Snapshot,
    position: usize,
    forward: bool,
) -> Result<std::ops::Range<usize>, EditError> {
    let line = snapshot.line_of(position).ok_or(EditError::InvalidRange)?;
    let content = snapshot.line_content_range(line).unwrap();
    let whole = snapshot.line_range(line).unwrap();
    if position > content.end && position < whole.end {
        return Ok(content.end..whole.end);
    }
    let text = snapshot.line(line).unwrap();
    let relative = position - content.start;
    if let Some((start, cluster)) = text
        .grapheme_indices(true)
        .find(|(start, cluster)| *start < relative && relative < start + cluster.len())
    {
        return Ok(content.start + start..content.start + start + cluster.len());
    }
    let other = step_grapheme(snapshot, position, forward)?;
    Ok(position.min(other)..position.max(other))
}
