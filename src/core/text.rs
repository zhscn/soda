use std::{ops::Range, sync::Arc};

/// Immutable UTF-8 text with byte-based line indexing. CRLF remains intact.
#[derive(Clone, Debug)]
pub struct Snapshot {
    text: Arc<str>,
    lines: Arc<[usize]>,
    version: u64,
}

impl Snapshot {
    pub(crate) fn new(text: String, version: u64) -> Self {
        let mut lines = vec![0];
        lines.extend(text.match_indices('\n').map(|(p, _)| p + 1));
        Self {
            text: text.into(),
            lines: lines.into(),
            version,
        }
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn version(&self) -> u64 {
        self.version
    }
    pub fn line_count(&self) -> usize {
        self.lines.len()
    }
    pub fn line_start(&self, line: usize) -> Option<usize> {
        self.lines.get(line).copied()
    }
    pub fn line_range(&self, line: usize) -> Option<Range<usize>> {
        Some(self.line_start(line)?..self.lines.get(line + 1).copied().unwrap_or(self.text.len()))
    }
    pub fn line_content_range(&self, line: usize) -> Option<Range<usize>> {
        let mut r = self.line_range(line)?;
        if self.text.as_bytes().get(r.end.wrapping_sub(1)) == Some(&b'\n') && r.end > r.start {
            r.end -= 1;
            if r.end > r.start && self.text.as_bytes()[r.end - 1] == b'\r' {
                r.end -= 1;
            }
        }
        Some(r)
    }
    pub fn line_of(&self, offset: usize) -> Option<usize> {
        if offset > self.text.len() || !self.text.is_char_boundary(offset) {
            return None;
        }
        Some(self.lines.partition_point(|&p| p <= offset) - 1)
    }
    pub fn line(&self, line: usize) -> Option<&str> {
        Some(&self.text[self.line_content_range(line)?])
    }
    pub(crate) fn shared_text(&self) -> Arc<str> {
        self.text.clone()
    }
    pub(crate) fn with_version(&self, version: u64) -> Self {
        Self {
            text: self.text.clone(),
            lines: self.lines.clone(),
            version,
        }
    }
}
