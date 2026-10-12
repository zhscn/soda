use super::Change;
use ropey::{Rope, RopeSlice};
use std::{
    borrow::Cow,
    ops::Range,
    sync::{Arc, OnceLock},
};

#[derive(Debug)]
struct TextStorage {
    rope: Rope,
    contiguous: OnceLock<Arc<str>>,
}

/// Immutable UTF-8 rope. Public positions are byte offsets, lines use LF/CRLF,
/// and snapshots share both the rope and any lazily materialized parser input.
#[derive(Clone, Debug)]
pub struct Snapshot {
    storage: Arc<TextStorage>,
    version: u64,
}
impl Snapshot {
    pub(crate) fn new(text: String, version: u64) -> Self {
        Self::from_rope(Rope::from_str(&text), version)
    }
    fn from_rope(rope: Rope, version: u64) -> Self {
        Self {
            storage: Arc::new(TextStorage {
                rope,
                contiguous: OnceLock::new(),
            }),
            version,
        }
    }

    /// Materializes the entire text on first access, then reuses that allocation.
    /// Editing, slicing and line queries do not require this compatibility view.
    pub fn text(&self) -> &str {
        self.contiguous().as_ref()
    }
    fn contiguous(&self) -> &Arc<str> {
        self.storage
            .contiguous
            .get_or_init(|| self.storage.rope.to_string().into())
    }
    pub fn len_bytes(&self) -> usize {
        self.storage.rope.len_bytes()
    }
    pub fn is_empty(&self) -> bool {
        self.len_bytes() == 0
    }
    pub fn is_char_boundary(&self, offset: usize) -> bool {
        if offset > self.len_bytes() {
            return false;
        }
        let (chunk, start, _, _) = self.storage.rope.chunk_at_byte(offset);
        chunk.is_char_boundary(offset - start)
    }
    /// Borrows the rope's UTF-8 chunks without creating a contiguous copy.
    pub fn chunks(&self) -> impl Iterator<Item = &str> {
        self.storage.rope.chunks()
    }
    /// Byte ranges must be ordered, in bounds and on UTF-8 character boundaries.
    pub fn byte_slice(&self, range: Range<usize>) -> Option<RopeSlice<'_>> {
        if range.start > range.end
            || !self.is_char_boundary(range.start)
            || !self.is_char_boundary(range.end)
        {
            return None;
        }
        Some(self.storage.rope.byte_slice(range))
    }
    /// Compares content without materializing either snapshot as one string.
    pub fn content_eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.storage, &other.storage) || self.storage.rope == other.storage.rope
    }
    pub fn version(&self) -> u64 {
        self.version
    }
    pub fn line_count(&self) -> usize {
        self.storage.rope.len_lines()
    }
    pub fn line_start(&self, line: usize) -> Option<usize> {
        if line >= self.line_count() {
            return None;
        }
        Some(self.storage.rope.line_to_byte(line))
    }
    pub fn line_range(&self, line: usize) -> Option<Range<usize>> {
        Some(self.line_start(line)?..self.line_start(line + 1).unwrap_or(self.len_bytes()))
    }
    pub fn line_content_range(&self, line: usize) -> Option<Range<usize>> {
        let mut range = self.line_range(line)?;
        if range.end > range.start && self.storage.rope.byte(range.end - 1) == b'\n' {
            range.end -= 1;
            if range.end > range.start && self.storage.rope.byte(range.end - 1) == b'\r' {
                range.end -= 1;
            }
        }
        Some(range)
    }
    pub fn line_of(&self, offset: usize) -> Option<usize> {
        if !self.is_char_boundary(offset) {
            return None;
        }
        Some(self.storage.rope.byte_to_line(offset))
    }
    /// Borrows a contiguous line or copies just that line if it spans chunks.
    /// The line terminator is excluded; empty and trailing lines are included.
    pub fn line(&self, line: usize) -> Option<Cow<'_, str>> {
        let slice = self.byte_slice(self.line_content_range(line)?)?;
        Some(match slice.as_str() {
            Some(text) => Cow::Borrowed(text),
            None => Cow::Owned(slice.to_string()),
        })
    }
    pub(crate) fn shared_text(&self) -> Arc<str> {
        self.contiguous().clone()
    }
    pub(crate) fn with_version(&self, version: u64) -> Self {
        Self {
            storage: self.storage.clone(),
            version,
        }
    }

    /// History retains the rope, not an optional full-text parser allocation.
    pub(crate) fn for_history(&self) -> Self {
        Self::from_rope(self.storage.rope.clone(), self.version)
    }

    /// Applies validated, ordered base-coordinate changes backwards so later
    /// replacements cannot move the byte positions of earlier replacements.
    pub(crate) fn edited(&self, changes: &[Change], version: u64) -> Self {
        let mut rope = self.storage.rope.clone();
        for change in changes.iter().rev() {
            let start = rope.byte_to_char(change.range.start);
            let end = rope.byte_to_char(change.range.end);
            rope.remove(start..end);
            rope.insert(start, &change.insert);
        }
        Self::from_rope(rope, version)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{Editor, EditorState, Selection, Transaction};

    #[test]
    fn chunked_queries_edits_and_history_do_not_flatten_text() {
        let input = format!("{}{}", "a界\tb\r\n".repeat(8192), "界".repeat(4096));
        let mut editor = Editor::new(input.clone());
        let old = editor.state().snapshot().clone();
        assert!(old.chunks().count() > 1);
        assert_eq!(old.line(8192).as_deref(), Some("界".repeat(4096).as_str()));
        assert_eq!(old.byte_slice(1..4).unwrap(), "界");
        assert!(old.byte_slice(2..4).is_none());
        assert!(old.byte_slice(Range { start: 4, end: 3 }).is_none());
        assert!(old.byte_slice(0..usize::MAX).is_none());
        assert!(!old.is_char_boundary(usize::MAX));
        assert!(old.storage.contiguous.get().is_none());
        editor
            .dispatch(Transaction::new(0, vec![Change::new(0..1, "🦀")]))
            .unwrap();
        assert!(editor.state().snapshot().storage.contiguous.get().is_none());
        assert_eq!(old.chunks().collect::<String>(), input);
        // A language query may flatten the live document; undo history does not
        // keep that redundant allocation alive when the live version changes.
        let live = editor.state().snapshot().shared_text();
        editor
            .dispatch(Transaction::new(1, vec![Change::new(0..4, "b")]))
            .unwrap();
        editor.undo().unwrap();
        assert!(editor.state().snapshot().storage.contiguous.get().is_none());
        assert_eq!(
            editor.state().snapshot().chunks().collect::<String>(),
            live.as_ref()
        );
        editor.undo().unwrap();
        assert!(editor.state().snapshot().storage.contiguous.get().is_none());
        assert_eq!(
            editor.state().snapshot().chunks().collect::<String>(),
            input
        );
        editor.redo().unwrap();
        assert!(editor.state().snapshot().storage.contiguous.get().is_none());
    }

    #[test]
    fn contiguous_view_is_shared_by_unchanged_snapshots_and_invalidated_by_edits() {
        let state = EditorState::new("a界\r\n".repeat(2048));
        let old = state.snapshot().clone();
        let mut select = Transaction::new(0, vec![]);
        select.selection = Some(Selection::caret(1));
        let (moved, _) = state.apply(select).unwrap();
        let source = old.shared_text();
        assert!(Arc::ptr_eq(&source, &moved.snapshot().shared_text()));
        let (edited, _) = moved
            .apply(Transaction::new(1, vec![Change::new(1..4, "文")]))
            .unwrap();
        assert!(edited.snapshot().storage.contiguous.get().is_none());
        assert!(!Arc::ptr_eq(&source, &edited.snapshot().shared_text()));
        assert!(old.text().starts_with("a界\r\n"));
        assert!(edited.snapshot().text().starts_with("a文\r\n"));
    }
}
