use std::num::NonZeroUsize;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TabPolicy {
    Never,
    ForIndentation,
    ForContinuationAndIndentation,
    AlignWithSpaces,
    Always,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WhitespacePolicy {
    pub indent_width: usize,
    pub tab_width: NonZeroUsize,
    pub tabs: TabPolicy,
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
