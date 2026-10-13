//! Unicode word navigation, scanning one logical line at a time rather than
//! materializing the document. Punctuation and whitespace separate words.
use super::{Association, ByteOffset, EditError, Snapshot, clip_grapheme_offset};
use unicode_segmentation::UnicodeSegmentation;

pub(crate) fn word_edge(text: &str, offset: usize, backward: bool) -> Option<usize> {
    if backward {
        text.unicode_word_indices()
            .map(|(start, _)| start)
            .take_while(|start| *start < offset)
            .last()
    } else {
        text.unicode_word_indices()
            .map(|(start, word)| start + word.len())
            .find(|end| *end > offset)
    }
}
pub fn word_boundary(
    snapshot: &Snapshot,
    position: ByteOffset,
    backward: bool,
) -> Result<ByteOffset, EditError> {
    let mut line = snapshot
        .line_of(position.0)
        .ok_or(EditError::InvalidRange)?;
    let mut offset = position.0 - snapshot.line_start(line).unwrap();
    loop {
        let text = snapshot.line(line).unwrap();
        if let Some(edge) = word_edge(&text, offset, backward) {
            return clip_grapheme_offset(
                snapshot,
                ByteOffset(snapshot.line_start(line).unwrap() + edge),
                Association::After,
            );
        }
        if backward {
            if line == 0 {
                return Ok(ByteOffset(0));
            }
            line -= 1;
            offset = snapshot.line_range(line).unwrap().len();
        } else {
            line += 1;
            if line == snapshot.line_count() {
                return Ok(ByteOffset(snapshot.len_bytes()));
            }
            offset = 0;
        }
    }
}
