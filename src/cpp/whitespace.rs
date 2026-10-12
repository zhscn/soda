use super::{TabPolicy, WhitespacePolicy};
use std::num::NonZeroUsize;
use unicode_width::UnicodeWidthStr;

/// Logical display columns, separate from UTF-8 byte offsets.
pub fn column_width(text: &str, start: usize, tab_width: NonZeroUsize) -> usize {
    let width = tab_width.get();
    text.split('\t').enumerate().fold(start, |c, (index, run)| {
        c + if index == 0 { 0 } else { width - c % width } + run.width()
    })
}

/// Structural, fixed continuation and alignment columns remain distinct.
/// Tabs are emitted only when their entire next stop fits the permitted region.
pub fn materialize(
    structural: usize,
    continuation: usize,
    target: usize,
    style: &WhitespacePolicy,
) -> String {
    let boundary = match style.tabs {
        TabPolicy::Never => 0,
        TabPolicy::ForIndentation => structural,
        TabPolicy::ForContinuationAndIndentation => target,
        TabPolicy::AlignWithSpaces => continuation.max(structural),
        TabPolicy::Always => target,
    }
    .min(target);
    let width = style.tab_width.get();
    let mut out = String::new();
    let mut col = 0;
    while col < target {
        let next = col + width - col % width;
        if next <= boundary && (style.tabs != TabPolicy::Always || target > 1) {
            out.push('\t');
            col = next;
        } else {
            out.push(' ');
            col += 1;
        }
    }
    out
}
