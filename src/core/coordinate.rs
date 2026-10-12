//! Snapshot text coordinates. Display geometry is supplied by a frontend.
use super::{Association, EditError, Snapshot};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct ByteOffset(pub usize);
/// Zero-based row and UTF-8 byte column, including positions in line endings.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct TextPoint {
    pub row: usize,
    pub byte_column: usize,
}
/// Tab-expanded logical cells, measured additively by extended grapheme.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct LogicalColumn(pub usize);

impl Snapshot {
    pub fn text_point(&self, offset: ByteOffset) -> Result<TextPoint, EditError> {
        let row = self.line_of(offset.0).ok_or(EditError::InvalidRange)?;
        Ok(TextPoint {
            row,
            byte_column: offset.0 - self.line_start(row).unwrap(),
        })
    }
    pub fn byte_offset(&self, point: TextPoint) -> Result<ByteOffset, EditError> {
        let start = self.line_start(point.row).ok_or(EditError::InvalidRange)?;
        let offset = start
            .checked_add(point.byte_column)
            .ok_or(EditError::InvalidRange)?;
        if self.line_of(offset) != Some(point.row) {
            return Err(EditError::InvalidRange);
        }
        Ok(ByteOffset(offset))
    }
    /// Explicit scalar-boundary clipping. Transactions never call this to
    /// repair invalid edits; they reject invalid coordinates instead.
    pub fn clip_byte_offset(&self, offset: ByteOffset, association: Association) -> ByteOffset {
        let mut offset = offset.0.min(self.len_bytes());
        while !self.is_char_boundary(offset) {
            match association {
                Association::Before => offset -= 1,
                Association::After => offset += 1,
            }
        }
        ByteOffset(offset)
    }
    /// Navigation points clamp to line content, not the interior of CRLF.
    pub fn clip_text_point(&self, point: TextPoint, association: Association) -> TextPoint {
        if point.row >= self.line_count() {
            return self.text_point(ByteOffset(self.len_bytes())).unwrap();
        }
        let range = self.line_content_range(point.row).unwrap();
        let offset = range.start + point.byte_column.min(range.len());
        self.text_point(self.clip_byte_offset(ByteOffset(offset), association))
            .unwrap()
    }
}
