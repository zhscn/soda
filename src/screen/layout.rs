//! Layout of a view's text area: which lines and parts of lines its rows
//! show, where each piece of text goes across a row, where the caret is,
//! and back from a place on screen to an offset. Rows are lines of one
//! height; across a row, text is measured by the frontend (`Measure`), so a
//! terminal lays it out in cells and a graphical frontend in pixels, by the
//! same rules.
use super::highlight::Highlighter;
use crate::{
    application::{Application, Face, Severity, ViewId},
    core::{ByteOffset, column_width, logical_column_at, step_grapheme},
    syntax::Category,
};
use std::num::NonZeroUsize;
use unicode_segmentation::UnicodeSegmentation;

/// Which font a piece of text is measured and drawn in.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Font {
    /// The document's text, and what stands for it: digits over it, the
    /// rest of a completion before it is taken.
    Text,
    /// What is not in the text: inlay hints, and notes and indicators
    /// after a line.
    Hint,
}
/// Widths of text as a frontend draws it, in the frontend's own units:
/// terminal cells, or fractions of a pixel. Text is laid out a grapheme
/// cluster at a time, each as wide as this says, so the clusters of a span
/// are drawn one after another at these widths.
pub trait Measure {
    /// The width of a grapheme cluster other than a tab.
    fn width(&self, cluster: &str, font: Font) -> usize;
    /// The width of a column of the text font. Tab stops, the ruler and
    /// the caret at the end of a line count in columns.
    fn column(&self) -> usize;
    /// The width of each printable ASCII character in the text font, when
    /// they are all as wide, so that a line of ASCII is measured a byte at
    /// a time; control characters are as wide as nothing.
    fn ascii(&self) -> Option<usize> {
        None
    }
}
/// Terminal cells, as wide as the core counts columns.
pub struct Cells;
impl Measure for Cells {
    fn width(&self, cluster: &str, _: Font) -> usize {
        column_width(cluster, 0, NonZeroUsize::MIN)
    }
    fn column(&self) -> usize {
        1
    }
    fn ascii(&self) -> Option<usize> {
        Some(1)
    }
}
/// The width of a run of text in `font`, a cluster at a time; tabs in it
/// count as other control characters, as nothing.
pub(crate) fn text_width(measure: &dyn Measure, text: &str, font: Font) -> usize {
    text.graphemes(true)
        .filter(|cluster| *cluster != "\t")
        .map(|cluster| measure.width(cluster, font))
        .sum()
}
/// Lays a line out from its start, a cluster at a time, with a tab stop
/// every `stop` units.
#[derive(Clone, Copy)]
struct Walk<'a> {
    measure: &'a dyn Measure,
    stop: usize,
}
impl<'a> Walk<'a> {
    fn new(measure: &'a dyn Measure, tab: NonZeroUsize) -> Self {
        Self {
            measure,
            stop: (tab.get() * measure.column()).max(1),
        }
    }
    /// The width of a cluster that starts `x` from the line's start.
    fn advance(&self, cluster: &str, x: usize) -> usize {
        if cluster == "\t" {
            self.stop - x % self.stop
        } else {
            self.measure.width(cluster, Font::Text)
        }
    }
    /// How far from the line's start `byte` of its text is.
    fn x_of(&self, text: &str, byte: usize) -> usize {
        let mut byte = byte.min(text.len());
        while !text.is_char_boundary(byte) {
            byte -= 1;
        }
        let prefix = &text[..byte];
        if let Some(width) = self.measure.ascii()
            && prefix.is_ascii()
        {
            return prefix.bytes().fold(0, |x, b| match b {
                b'\t' => x + self.stop - x % self.stop,
                b if b < 0x20 || b == 0x7f => x,
                _ => x + width,
            });
        }
        prefix
            .graphemes(true)
            .fold(0, |x, cluster| x + self.advance(cluster, x))
    }
    /// Where the cluster `x` from the line's start begins; past the end of
    /// the text, the end before the line break.
    fn byte_at(&self, text: &str, x: usize) -> usize {
        let content = text.trim_end_matches(['\n', '\r']);
        let mut at = 0;
        for (offset, cluster) in content.grapheme_indices(true) {
            let width = self.advance(cluster, at);
            if x < at + width {
                return offset;
            }
            at += width;
        }
        content.len()
    }
}

/// A piece of a row in one style. Its text fills the start of it, and the
/// rest is blank, as a tab is or a wide character cut at the edge.
#[derive(Debug)]
pub(crate) struct Span {
    /// Where it starts, from the left of its area, and how wide it is.
    pub x: usize,
    pub width: usize,
    pub text: String,
    pub selected: bool,
    /// Beacon's other selections and the grab, under the selection.
    pub mark: Mark,
    pub matched: bool,
    /// Secondary text, such as a candidate's description.
    pub detail: bool,
    pub category: Option<Category>,
    /// A visible tab or trailing space mark.
    pub whitespace: bool,
    pub face: Option<crate::application::Face>,
    /// An inlay hint, which is not in the text.
    pub inlay: bool,
    /// The font it was measured in; a terminal has only one.
    #[cfg_attr(not(feature = "gui"), allow(dead_code))]
    pub font: Font,
}
/// What else marks a span besides the selection, as meow draws it: the
/// grab in Emacs's secondary selection face, Beacon's other selections and
/// carets each in a mix of that with the selection or the cursor.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum Mark {
    #[default]
    None,
    Grab,
    BeaconSelection,
    BeaconCursor,
}
/// One screen row: the zero-based line it shows and its clipped text.
pub(crate) struct Row {
    pub line: usize,
    /// A later row of a wrapped line, which has no number.
    pub continued: bool,
    /// The first visual row of a real text line; EOF after a newline has no number.
    pub numbered: bool,
    /// The visible end of an unterminated final line, in measured units.
    /// None lets its current-line background extend to the window edge.
    pub highlight_end: Option<usize>,
    /// The line's flag, on its first row.
    pub flag: Option<crate::application::Flag>,
    /// The digit that extends a selection of lines to this line, on its
    /// first row: the frontend draws it at the left edge of the text, so it
    /// shows however far the text is scrolled sideways.
    pub digit: Option<char>,
    pub spans: Vec<Span>,
}
/// The text area of the active view, positioned relative to its top left.
pub(crate) struct Frame {
    pub rows: Vec<Row>,
    /// Across and down: in measured units from the left, and in rows.
    pub cursor: Option<(usize, usize)>,
    /// How wide the character under the caret is, at least a column: a
    /// block caret covers it.
    #[cfg_attr(not(feature = "gui"), allow(dead_code))]
    pub caret_width: usize,
    /// Zero-based line and logical column of the caret.
    pub caret: (usize, usize),
    /// The highlighting language's display name.
    pub language: String,
    /// Where the ruler is from the left, when it is in view.
    pub ruler: Option<usize>,
    /// The note to show for the caret: the worst at it, else on its line.
    pub note: Option<(crate::application::Severity, String)>,
    /// Errors and warnings in the document.
    pub problems: (usize, usize),
}

/// Clip by terminal cells. Partially visible tabs/wide graphemes are
/// blank; control characters never pass through to the terminal command
/// stream.
pub(crate) fn row(
    text: &str,
    byte_start: usize,
    selection: std::ops::Range<usize>,
    left: usize,
    width: usize,
    tab: NonZeroUsize,
) -> Vec<Span> {
    let marks = Marks {
        selection,
        grab: None,
        beacons: &[],
        digits: &[],
        matches: &[],
        detail: text.len(),
        categories: &[],
        tabs: false,
        trailing: false,
        faces: &[],
        inlays: &[],
    };
    styled_row(text, byte_start, marks, left, width, Walk::new(&Cells, tab))
}
/// What the modal layer shows over the text of the active window.
#[derive(Default)]
pub(crate) struct Overlay {
    /// The grab, Emacs's secondary selection.
    pub grab: Option<std::ops::Range<usize>>,
    /// The other selections of Beacon.
    pub beacons: Vec<std::ops::Range<usize>>,
    /// Digits that extend the selection, drawn over the character there.
    pub digits: Vec<(usize, char)>,
    /// Digits that extend a selection of lines, by line: drawn at the start
    /// of the line's first row as it shows.
    pub line_digits: Vec<(usize, char)>,
    /// The rest of the selected candidate, at the caret's offset.
    pub preview: Option<(usize, String)>,
    /// What flash's search shows in this window, of any window it covers.
    pub flash: Option<FlashMarks>,
}
/// flash's matches in a window, the one Enter goes to, and whether the
/// rest of the text recedes.
pub(crate) struct FlashMarks {
    pub matches: Vec<std::ops::Range<usize>>,
    pub current: Option<std::ops::Range<usize>>,
    pub backdrop: bool,
}
/// Byte ranges styled within a row: the selection is document-relative;
/// matches, the detail offset and highlight categories are relative to the
/// row text, categories ordered and disjoint.
struct Marks<'a> {
    selection: std::ops::Range<usize>,
    /// The grab, under everything else that marks the text.
    grab: Option<std::ops::Range<usize>>,
    /// More selections, of Beacon; carets among them show as one cell.
    beacons: &'a [std::ops::Range<usize>],
    digits: &'a [(usize, char)],
    matches: &'a [std::ops::Range<usize>],
    detail: usize,
    categories: &'a [(std::ops::Range<usize>, Category)],
    /// Mark tabs.
    tabs: bool,
    /// Mark spaces at the end of a line.
    trailing: bool,
    /// Highlighted ranges in the row, ordered by start.
    faces: &'a [(std::ops::Range<usize>, crate::application::Face)],
    /// Hints in order of where they stand. They take room from the row.
    inlays: &'a [Inlay],
}
/// flash's faces in a line from `start` of `length` bytes, relative to
/// it: the backdrop under all, then the matches, then the current one.
fn flash_faces(
    flash: &FlashMarks,
    start: usize,
    length: usize,
) -> Vec<(std::ops::Range<usize>, Face)> {
    let named = |name| crate::application::faces::index(name).map(Face::Named);
    let within = |range: &std::ops::Range<usize>| {
        let from = range.start.max(start) - start;
        let to = range.end.min(start + length).checked_sub(start)?;
        (from < to).then_some(from..to)
    };
    let mut faces = vec![];
    if flash.backdrop
        && let Some(face) = named("flash-backdrop")
    {
        faces.push((0..length, face));
    }
    if let Some(face) = named("flash-match") {
        faces.extend(flash.matches.iter().filter_map(within).map(|r| (r, face)));
    }
    if let Some(face) = named("flash-current") {
        faces.extend(flash.current.iter().filter_map(within).map(|r| (r, face)));
    }
    faces
}
/// The beacons that touch a row's bytes, a caret just past its text
/// among them. Beacons come ordered and apart, so their ends are ordered
/// too.
fn row_beacons(
    beacons: &[std::ops::Range<usize>],
    row: std::ops::Range<usize>,
) -> &[std::ops::Range<usize>] {
    let first = beacons.partition_point(|beacon| beacon.end < row.start);
    let last = beacons.partition_point(|beacon| beacon.start <= row.end);
    &beacons[first..last.max(first)]
}
/// A hint, before the character `x` from its line's start; `usize::MAX`
/// puts it after the line.
#[derive(Clone)]
struct Inlay {
    x: usize,
    text: String,
    face: Option<Face>,
    font: Font,
}
/// What shows of a text within `room`, a cluster at a time.
fn clipped(measure: &dyn Measure, text: &str, room: usize, font: Font) -> (String, usize) {
    let mut used = 0;
    let mut shown = String::new();
    for cluster in text.graphemes(true) {
        let width = measure.width(cluster, font);
        if used + width > room {
            break;
        }
        used += width;
        shown.push_str(cluster);
    }
    (shown, used)
}
/// A row's text with categories of `over` replacing those of `base`; both
/// are ordered and disjoint.
pub(crate) fn overlay(
    base: &[(std::ops::Range<usize>, Category)],
    over: &[(std::ops::Range<usize>, Category)],
) -> Vec<(std::ops::Range<usize>, Category)> {
    let between = |from: usize, to: usize, runs: &mut Vec<_>| {
        for (range, category) in base {
            let (start, end) = (range.start.max(from), range.end.min(to));
            if start < end {
                runs.push((start..end, *category));
            }
        }
    };
    let mut runs = vec![];
    let mut at = 0;
    for (range, category) in over {
        between(at, range.start, &mut runs);
        runs.push((range.clone(), *category));
        at = range.end;
    }
    between(at, usize::MAX, &mut runs);
    runs
}
/// The part of a line from `left` that fits in `width`, as spans placed
/// from the area's left edge.
fn styled_row(
    text: &str,
    byte_start: usize,
    marks: Marks,
    left: usize,
    width: usize,
    walk: Walk,
) -> Vec<Span> {
    styled_row_from(
        text,
        byte_start,
        marks,
        left,
        width,
        walk,
        RowSlice {
            bytes: 0..text.len(),
            x: 0,
            trailing_from: text
                .trim_end_matches(['\n', '\r'])
                .trim_end_matches([' ', '\t'])
                .len(),
        },
    )
}

struct RowSlice {
    bytes: std::ops::Range<usize>,
    x: usize,
    trailing_from: usize,
}

/// Start at a known grapheme boundary and measured coordinate. Wrapped
/// rows already have these, so drawing a continuation need not walk its
/// entire prefix again. Style ranges remain relative to the whole line.
fn styled_row_from(
    text: &str,
    byte_start: usize,
    marks: Marks,
    left: usize,
    width: usize,
    walk: Walk,
    slice: RowSlice,
) -> Vec<Span> {
    let Marks {
        selection,
        grab,
        beacons,
        digits,
        matches,
        detail,
        categories,
        tabs,
        trailing,
        faces,
        inlays,
    } = marks;
    let measure = walk.measure;
    // Beacon's carets first: one stands on the character after it.
    let mark_of = |start: usize, end: usize| {
        let meets = |range: &std::ops::Range<usize>| start < range.end && end > range.start;
        if beacons.iter().any(|b| b.is_empty() && b.start == start) {
            Mark::BeaconCursor
        } else if beacons.iter().any(|b| !b.is_empty() && meets(b)) {
            Mark::BeaconSelection
        } else if grab.as_ref().is_some_and(meets) {
            Mark::Grab
        } else {
            Mark::None
        }
    };
    let from = slice.bytes.start;
    let last = slice.bytes.end == text.len();
    let trailing_from = slice.trailing_from;
    let mut spans = Vec::<Span>::new();
    // Whether the last span's text fills it, so that more text can follow
    // in it.
    let mut filled = false;
    // Where the next span starts on screen.
    let mut at = 0;
    let mut next_category = categories.partition_point(|(range, _)| range.end <= from);
    let mut x = slice.x;
    let mut right = left.saturating_add(width);
    let mut next_inlay = 0;
    // Each hint shown leaves that much less room for the text.
    let mut hint = |until: usize,
                    x: usize,
                    right: &mut usize,
                    at: &mut usize,
                    spans: &mut Vec<Span>,
                    filled: &mut bool| {
        while let Some(inlay) = inlays.get(next_inlay).filter(|i| i.x <= until) {
            next_inlay += 1;
            if inlay.x < left {
                continue;
            }
            let room = right.saturating_sub(x.max(left));
            let (shown, used) = clipped(measure, &inlay.text, room, inlay.font);
            if shown.is_empty() {
                continue;
            }
            *right -= used;
            spans.push(Span {
                x: *at,
                width: used,
                text: shown,
                selected: false,
                mark: Mark::None,
                matched: false,
                detail: false,
                category: None,
                whitespace: false,
                face: inlay.face,
                inlay: inlay.face.is_none(),
                font: inlay.font,
            });
            *at += used;
            *filled = false;
        }
    };
    for (offset, cluster) in text[slice.bytes].grapheme_indices(true) {
        let offset = from + offset;
        hint(x, x, &mut right, &mut at, &mut spans, &mut filled);
        let end = x + walk.advance(cluster, x);
        if x >= right {
            break;
        }
        if end > left && end > x {
            let visible = end.min(right).saturating_sub(x.max(left));
            let whole = x >= left && end <= right;
            let marked = (tabs && cluster == "\t")
                || (trailing && cluster == " " && offset >= trailing_from);
            let digit = digits
                .iter()
                .find(|(place, _)| *place == byte_start + offset)
                .map(|(_, digit)| *digit);
            // Text that fills its cluster's width can run on with more.
            let (shown, fills) = if let Some(digit) = digit {
                (digit.to_string(), false)
            } else if marked && x >= left {
                let mark = if cluster == "\t" { "»" } else { "·" };
                let fills = measure.width(mark, Font::Text) == visible;
                (mark.to_owned(), fills)
            } else if cluster == "\t" || !whole {
                (String::new(), false)
            } else if cluster.chars().any(char::is_control) {
                ("�".into(), false)
            } else {
                (cluster.to_owned(), true)
            };
            let start = byte_start + offset;
            let selected = !selection.is_empty()
                && start < selection.end
                && start + cluster.len() > selection.start;
            let mark = mark_of(start, start + cluster.len());
            let matched = matches
                .iter()
                .any(|range| offset < range.end && offset + cluster.len() > range.start);
            let secondary = offset >= detail;
            while categories
                .get(next_category)
                .is_some_and(|(range, _)| range.end <= offset)
            {
                next_category += 1;
            }
            let category = categories
                .get(next_category)
                .filter(|(range, _)| range.start <= offset)
                .map(|(_, category)| *category);
            // A digit stands out over everything; otherwise the last
            // highlight to start wins where they overlap.
            let face = digit.map(|_| Face::Digit).or_else(|| {
                faces
                    .iter()
                    .rev()
                    .find(|(range, _)| range.start <= offset && offset < range.end)
                    .map(|(_, face)| *face)
            });
            let blank = shown.is_empty();
            if let Some(last) = spans.last_mut().filter(|last| {
                last.selected == selected
                    && last.mark == mark
                    && last.matched == matched
                    && last.detail == secondary
                    && last.category == category
                    && last.whitespace == marked
                    && last.face == face
                    && !last.inlay
                    && ((filled && fills) || (last.text.is_empty() && blank))
            }) {
                last.text.push_str(&shown);
                last.width += visible;
            } else {
                spans.push(Span {
                    x: at,
                    width: visible,
                    text: shown,
                    selected,
                    mark,
                    matched,
                    detail: secondary,
                    category,
                    whitespace: marked,
                    face,
                    inlay: false,
                    font: Font::Text,
                });
                filled = fills;
            }
            at += visible;
        }
        x = end;
    }
    // The line break has no character to show: a beacon caret on it, or a
    // selection, grab or beacon selection that goes on past it, takes the
    // cell after the text, as Emacs draws a face on the newline.
    let line_end = byte_start + text.trim_end_matches(['\n', '\r']).len();
    let mark = mark_of(line_end, line_end + 1);
    let selected = selection.start <= line_end && line_end < selection.end;
    if last && x >= left && x < right && (selected || mark != Mark::None) {
        let width = measure.column().min(right - x);
        spans.push(Span {
            x: at,
            width,
            text: String::new(),
            selected,
            mark,
            matched: false,
            detail: false,
            category: None,
            whitespace: false,
            face: None,
            inlay: false,
            font: Font::Text,
        });
        at += width;
        x += width;
        filled = false;
    }
    if last && x < right {
        hint(usize::MAX, x, &mut right, &mut at, &mut spans, &mut filled);
    }
    spans
}
/// A candidate label with its matched ranges; text from `detail` on is
/// secondary.
pub(crate) fn candidate_row<T>(
    row: &crate::interaction::picker::MatchedCandidate<T>,
    selected: Option<crate::interaction::picker::CandidateKey>,
    detail: Option<usize>,
    width: usize,
) -> Vec<Span> {
    let text = &row.candidate.label;
    let selection = if selected == Some(row.candidate.key) {
        0..text.len()
    } else {
        0..0
    };
    let marks = Marks {
        selection,
        grab: None,
        beacons: &[],
        digits: &[],
        matches: &row.highlights,
        detail: detail.unwrap_or(text.len()),
        categories: &[],
        tabs: false,
        trailing: false,
        faces: &[],
        inlays: &[],
    };
    let walk = Walk::new(&Cells, NonZeroUsize::new(4).unwrap());
    styled_row(text, 0, marks, 0, width, walk)
}
/// Lines of `text` at most `width` cells wide, broken at spaces where they
/// can be.
pub(crate) fn wrap(text: &str, width: usize) -> Vec<String> {
    let mut lines = vec![];
    for line in text.lines() {
        let mut current = String::new();
        let mut used = 0;
        for word in line.split_inclusive(' ') {
            let cells = unicode_width::UnicodeWidthStr::width(word);
            let text = unicode_width::UnicodeWidthStr::width(word.trim_end());
            if used + text > width && used > 0 {
                lines.push(std::mem::take(&mut current).trim_end().to_owned());
                used = 0;
            }
            current.push_str(word);
            used += cells;
            // A word wider than a line, such as a path, breaks where it must.
            while used > width + 1 || (used > width && !current.ends_with(' ')) {
                let mut cells = 0;
                let end = current
                    .char_indices()
                    .find(|(_, ch)| {
                        cells += unicode_width::UnicodeWidthChar::width(*ch).unwrap_or(0);
                        cells > width
                    })
                    .map_or(current.len(), |(at, _)| at);
                let rest = current.split_off(end);
                lines.push(std::mem::replace(&mut current, rest));
                used = unicode_width::UnicodeWidthStr::width(current.as_str());
            }
        }
        lines.push(current.trim_end().to_owned());
    }
    lines
}
/// A span's text with its blank rest as spaces, as a terminal shows it.
pub(crate) fn padded(span: &Span) -> String {
    let used = text_width(&Cells, &span.text, Font::Text);
    let mut text = span.text.clone();
    text.extend(std::iter::repeat_n(' ', span.width.saturating_sub(used)));
    text
}
pub(crate) fn plain(text: &str, left: usize, width: usize) -> String {
    row(text, 0, 0..0, left, width, NonZeroUsize::new(4).unwrap())
        .iter()
        .map(padded)
        .collect()
}

/// The part of a line one screen row shows: where it starts in the line's
/// text, and how far from the line's start it begins and ends.
#[derive(Clone, Debug, PartialEq)]
struct Segment {
    start: usize,
    xs: std::ops::Range<usize>,
}
/// Splits a line into screen rows `width` wide, breaking after the last
/// space that fits and inside a word only when none does. Without a width
/// the line is one row, cut at the edge and scrolled sideways.
fn segments(text: &str, width: Option<usize>, walk: Walk) -> Vec<Segment> {
    segments_with_inlays(text, width, walk, &[])
}

fn segments_with_inlays(
    text: &str,
    width: Option<usize>,
    walk: Walk,
    inlays: &[Inlay],
) -> Vec<Segment> {
    let Some(width) = width.map(|w| w.max(1)) else {
        return vec![Segment {
            start: 0,
            xs: 0..usize::MAX,
        }];
    };
    // Spaces at a row boundary stay with the preceding text, even when
    // they extend past the edge. Breaking before such a space lets the
    // next word break after it again, leaving a whitespace-only row.
    let content_end = text.trim_end_matches(['\n', '\r']).len();
    let mut out = vec![];
    let (mut start, mut first) = (0, 0);
    let mut space = None;
    let mut x = 0;
    for (offset, cluster) in text.grapheme_indices(true) {
        let end = x + walk.advance(cluster, x);
        let whitespace = cluster == " " || cluster == "\t";
        while offset < content_end
            && !whitespace
            && end - first
                + inlays
                    .iter()
                    .filter(|hint| (first..=x).contains(&hint.x))
                    .map(|hint| text_width(walk.measure, &hint.text, hint.font))
                    .sum::<usize>()
                > width
            && x > first
        {
            let (at, at_x) = space.take().unwrap_or((offset, x));
            out.push(Segment {
                start,
                xs: first..at_x,
            });
            (start, first) = (at, at_x);
        }
        if whitespace {
            space = Some((offset + cluster.len(), end));
        }
        x = end;
    }
    out.push(Segment {
        start,
        xs: first..x.max(first),
    });
    out
}
/// A screen row: a line and which of its segments.
type Place = (usize, usize);
/// How one view's lines meet its text area.
struct Rows<'a> {
    snapshot: &'a crate::core::Snapshot,
    walk: Walk<'a>,
    wrap: Option<usize>,
    /// Lines shown, the empty one after a final newline too: the caret can
    /// go there, as at the end of an Emacs buffer.
    lines: usize,
    /// The document's hints by offset, when they are shown.
    hints: &'a [(usize, String)],
    /// Hints by line, placed as lines are asked for: a document may have
    /// tens of thousands, and only the lines on screen need theirs.
    inlays: std::cell::RefCell<std::collections::HashMap<usize, std::rc::Rc<[Inlay]>>>,
    /// Rows of wrapped lines measured so far.
    measured: std::cell::RefCell<std::collections::HashMap<usize, std::rc::Rc<[Segment]>>>,
}
impl<'a> Rows<'a> {
    fn new(
        app: &'a Application,
        view: &crate::application::View,
        measure: &'a dyn Measure,
        width: usize,
    ) -> Option<Self> {
        let document = app.workspace().editor(view.document_id)?.model().document();
        let snapshot = document.snapshot();
        let wrap = app
            .options()
            .bool(Some(view.document_id), "wrap")
            .then_some(width);
        let walk = Walk::new(measure, document.whitespace().tab_width);
        let hints = match app.options().bool(Some(view.document_id), "inlay-hints") {
            true => app.inlays(view.document_id),
            false => &[],
        };
        Some(Self {
            snapshot,
            walk,
            wrap,
            lines: snapshot.line_count(),
            hints,
            inlays: Default::default(),
            measured: Default::default(),
        })
    }
    /// A line's hints, placed by the width of the text before them.
    fn inlays(&self, line: usize) -> std::rc::Rc<[Inlay]> {
        if let Some(placed) = self.inlays.borrow().get(&line) {
            return placed.clone();
        }
        let placed: std::rc::Rc<[Inlay]> =
            match (self.snapshot.line_start(line), self.snapshot.line(line)) {
                (Some(start), Some(text)) if !self.hints.is_empty() => {
                    let end = start + text.len();
                    let first = self.hints.partition_point(|(offset, _)| *offset < start);
                    self.hints[first..]
                        .iter()
                        .take_while(|(offset, _)| *offset <= end)
                        .map(|(offset, hint)| Inlay {
                            x: self.walk.x_of(&text, offset - start),
                            text: hint.chars().filter(|c| !c.is_control()).collect(),
                            face: None,
                            font: Font::Hint,
                        })
                        .collect()
                }
                _ => std::rc::Rc::new([]),
            };
        self.inlays.borrow_mut().insert(line, placed.clone());
        placed
    }
    /// The room hints take from `left` up to a character `x` from its
    /// line's start.
    fn hinted(&self, line: usize, left: usize, x: usize) -> usize {
        self.inlays(line)
            .iter()
            .filter(|hint| (left..=x).contains(&hint.x))
            .map(|hint| text_width(self.walk.measure, &hint.text, hint.font))
            .sum()
    }
    /// How far from its line's start the character is that shows `across`
    /// right of `left`; a hint counts as the character after it.
    fn unhinted(&self, line: usize, left: usize, across: usize) -> usize {
        let mut used = 0;
        for hint in self.inlays(line).iter() {
            if hint.x < left {
                continue;
            }
            let start = hint.x - left + used;
            if across < start {
                break;
            }
            let width = text_width(self.walk.measure, &hint.text, hint.font);
            if across < start + width {
                return hint.x;
            }
            used += width;
        }
        left + across - used
    }
    /// A line's rows. Moving over rows asks for the same lines again and
    /// again, so each is measured once.
    fn segments(&self, line: usize) -> std::rc::Rc<[Segment]> {
        if self.wrap.is_none() {
            return segments("", None, self.walk).into();
        }
        self.measured
            .borrow_mut()
            .entry(line)
            .or_insert_with(|| {
                segments_with_inlays(
                    &self.snapshot.line(line).unwrap_or_default(),
                    self.wrap,
                    self.walk,
                    &self.inlays(line),
                )
                .into()
            })
            .clone()
    }
    /// The row showing `offset`, and how far from its line's start it is.
    fn place(&self, offset: usize) -> (Place, usize) {
        let offset = offset.min(self.snapshot.len_bytes());
        let line = self.snapshot.line_of(offset).unwrap().min(self.lines - 1);
        let within = offset - self.snapshot.line_start(line).unwrap();
        if self.wrap.is_none() {
            let text = self.snapshot.line(line).unwrap_or_default();
            return ((line, 0), self.walk.x_of(&text, within));
        }
        let segments = self.segments(line);
        let row = segments.partition_point(|segment| segment.start <= within) - 1;
        let segment = &segments[row];
        let text = self.snapshot.line(line).unwrap_or_default();
        let x = text[segment.start..within]
            .graphemes(true)
            .fold(segment.xs.start, |x, cluster| {
                x + self.walk.advance(cluster, x)
            });
        ((line, row), x)
    }
    /// The offset of the character `x` from a line's start.
    fn offset(&self, line: usize, x: usize) -> usize {
        let text = self.snapshot.line(line).unwrap_or_default();
        if self.wrap.is_none() {
            return self.snapshot.line_start(line).unwrap() + self.walk.byte_at(&text, x);
        }
        let segments = self.segments(line);
        let row = segments.partition_point(|segment| segment.xs.start <= x) - 1;
        let segment = &segments[row];
        let mut at = segment.xs.start;
        for (offset, cluster) in text[segment.start..]
            .trim_end_matches(['\n', '\r'])
            .grapheme_indices(true)
        {
            let end = at + self.walk.advance(cluster, at);
            if x < end {
                return self.snapshot.line_start(line).unwrap() + segment.start + offset;
            }
            at = end;
        }
        self.snapshot.line_start(line).unwrap() + text.trim_end_matches(['\n', '\r']).len()
    }
    /// The offset where a row starts.
    fn start(&self, (line, row): Place) -> usize {
        let segments = self.segments(line);
        self.snapshot.line_start(line).unwrap() + segments[row.min(segments.len() - 1)].start
    }
    /// The row `count` rows on, stopping at the first and the last.
    fn step(&self, (mut line, mut row): Place, count: isize) -> Place {
        let mut rows = self.segments(line).len();
        for _ in 0..count.unsigned_abs() {
            if count > 0 {
                if row + 1 < rows {
                    row += 1;
                } else if line + 1 < self.lines {
                    line += 1;
                    row = 0;
                    rows = self.segments(line).len();
                } else {
                    break;
                }
            } else if row > 0 {
                row -= 1;
            } else if line > 0 {
                line -= 1;
                rows = self.segments(line).len();
                row = rows - 1;
            } else {
                break;
            }
        }
        (line, row)
    }
    /// Rows from `from` to `to`, at most `limit`; none when `to` is above.
    fn distance(&self, from: Place, to: Place, limit: usize) -> Option<usize> {
        if to < from {
            return None;
        }
        let mut place = from;
        for count in 0..limit {
            if place == to {
                return Some(count);
            }
            let next = self.step(place, 1);
            if next == place {
                return None;
            }
            place = next;
        }
        (place == to).then_some(limit)
    }
}

/// Scroll only the active view. Byte anchors remain application-owned and map
/// through document updates; this frontend resolves them into screen rows.
pub(crate) fn follow_caret(
    app: &Application,
    id: ViewId,
    measure: &dyn Measure,
    width: usize,
    rows: u16,
) -> Result<Option<ViewportAdjustment>, crate::application::Error> {
    let view = app.view(id).unwrap();
    let editor = app.workspace().editor(view.document_id).unwrap();
    let state = editor.model().session(view.session_id).unwrap().state();
    let snapshot = editor.model().document().snapshot();
    let head = state.selection().head;
    let layout = Rows::new(app, view, measure, width).unwrap();
    let (place, x) = layout.place(head);
    let rows = usize::from(rows);
    let (mut top, _) = layout.place(view.viewport.anchor.offset.0);
    if rows > 0 {
        if place < top {
            top = place;
        } else if layout.distance(top, place, rows).is_none_or(|d| d >= rows) {
            top = layout.step(place, 1 - rows as isize);
        }
    }
    let mut left = view.viewport.horizontal_scroll;
    if layout.wrap.is_some() {
        left = 0;
    } else if width > 0 {
        if x < left {
            left = x;
        }
        let next = step_grapheme(snapshot, ByteOffset(head), true)?;
        let cluster = snapshot.byte_slice(head..next.0).unwrap().to_string();
        let caret = layout
            .walk
            .advance(&cluster, x)
            .max(measure.column())
            .min(width);
        let (line, _) = place;
        let caret_end = x.saturating_add(caret) + layout.hinted(line, left, x);
        if caret_end > left.saturating_add(width) {
            left = caret_end - width;
        }
    }
    let anchor = ByteOffset(layout.start(top));
    Ok(
        (anchor != view.viewport.anchor.offset || left != view.viewport.horizontal_scroll)
            .then_some(ViewportAdjustment {
                view: id,
                anchor,
                horizontal_scroll: left,
            }),
    )
}

/// The row of a view's text area `width` wide that shows `offset`, and how
/// far from the area's left; none when it is scrolled out above or to the
/// left, or more than `rows` rows down.
pub(crate) fn position_of(
    app: &Application,
    view: ViewId,
    measure: &dyn Measure,
    width: usize,
    rows: u16,
    offset: usize,
) -> Option<(usize, usize)> {
    let view = app.view(view)?;
    let layout = Rows::new(app, view, measure, width)?;
    let (top, _) = layout.place(view.viewport.anchor.offset.0);
    let (place, x) = layout.place(offset);
    let row = layout.distance(top, place, rows.into())?;
    let first = if layout.wrap.is_some() {
        layout.segments(place.0)[place.1].xs.start
    } else {
        view.viewport.horizontal_scroll
    };
    let across = x.checked_sub(first)? + layout.hinted(place.0, first, x);
    Some((row, across))
}
/// The byte offset at a place in the active view's text area: `row` rows
/// down and `across` from its left. Rows past either edge resolve to the
/// lines beyond it, within the document.
pub(crate) fn offset_at(
    app: &Application,
    measure: &dyn Measure,
    width: usize,
    row: isize,
    across: usize,
) -> Option<usize> {
    let view = app.view(app.active_view()?)?;
    let layout = Rows::new(app, view, measure, width)?;
    let (top, _) = layout.place(view.viewport.anchor.offset.0);
    let (line, index) = layout.step(top, row);
    let line = line.min(layout.snapshot.line_count() - 1);
    let x = if layout.wrap.is_some() {
        let segments = layout.segments(line);
        let segment = &segments[index.min(segments.len() - 1)];
        // Past the end of a row that continues, stay on its last character.
        let last = index + 1 < segments.len();
        let room = segment.xs.len().saturating_sub(usize::from(last));
        layout
            .unhinted(line, segment.xs.start, across)
            .min(segment.xs.start + room)
    } else {
        layout.unhinted(line, view.viewport.horizontal_scroll, across)
    };
    Some(layout.offset(line, x))
}
/// Scrolls the active view by `lines` screen rows, keeping the last line
/// reachable at the top. When the caret leaves the text area, the second
/// value is where it comes back: the nearest visible row, as far across.
pub(crate) fn scroll(
    app: &Application,
    id: ViewId,
    measure: &dyn Measure,
    lines: isize,
    width: usize,
    rows: u16,
) -> Option<(ViewportAdjustment, Option<usize>)> {
    let view = app.view(id)?;
    let editor = app.workspace().editor(view.document_id)?;
    let head = editor.model().session(view.session_id)?.selection().head;
    let layout = Rows::new(app, view, measure, width)?;
    let (top, _) = layout.place(view.viewport.anchor.offset.0);
    let top = layout.step(top, lines);
    let top = (top.0.min(layout.snapshot.line_count() - 1), top.1);
    let (place, x) = layout.place(head);
    let rows = usize::from(rows.max(1));
    let bottom = layout.step(top, rows as isize - 1);
    let reveal = (place < top || place > bottom).then(|| {
        let (line, row) = if place < top { top } else { bottom };
        let x = match layout.wrap {
            Some(_) => {
                let within = layout.segments(place.0)[place.1].xs.start;
                let segments = layout.segments(line);
                let segment = &segments[row.min(segments.len() - 1)];
                (segment.xs.start + (x - within)).min(segment.xs.end)
            }
            None => x,
        };
        layout.offset(line, x)
    });
    Some((
        ViewportAdjustment {
            view: id,
            anchor: ByteOffset(layout.start(top)),
            horizontal_scroll: view.viewport.horizontal_scroll,
        },
        reveal,
    ))
}

pub(crate) struct ViewportAdjustment {
    pub view: ViewId,
    pub anchor: ByteOffset,
    pub horizontal_scroll: usize,
}

/// Rows from the one starting at offset `from` to the one starting at
/// `to`, both viewport anchors of a view: negative when `to` is above. None
/// when they are more than `limit` rows apart.
#[cfg_attr(not(feature = "gui"), allow(dead_code))]
pub(crate) fn rows_between(
    app: &Application,
    id: ViewId,
    measure: &dyn Measure,
    width: usize,
    from: usize,
    to: usize,
    limit: usize,
) -> Option<isize> {
    let view = app.view(id)?;
    let layout = Rows::new(app, view, measure, width)?;
    let (from, _) = layout.place(from);
    let (to, _) = layout.place(to);
    match layout.distance(from, to, limit) {
        Some(rows) => Some(rows as isize),
        None => Some(-(layout.distance(to, from, limit)? as isize)),
    }
}

/// Render an immutable application projection of the active view's text
/// area. Viewport decisions are applied by Runtime before this is called.
/// The rows start `first` rows from the viewport's top, above it when
/// negative, so that a frontend scrolling smoothly can show what comes
/// into view; the caret's row counts from the first row shown. `left`,
/// when given, is where the rows start across instead of the viewport's
/// horizontal scroll, as on the way to it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn frame(
    app: &Application,
    id: ViewId,
    highlighter: &mut Highlighter,
    measure: &dyn Measure,
    width: usize,
    first: isize,
    left: Option<usize>,
    rows: u16,
    modal: &Overlay,
) -> Result<Option<Frame>, crate::application::Error> {
    let Some(view) = app.view(id) else {
        return Ok(None);
    };
    let editor = app.workspace().editor(view.document_id).unwrap();
    let document = editor.model().document();
    let state = editor.model().session(view.session_id).unwrap().state();
    let snapshot = document.snapshot();
    let head = state.selection().head;
    let line = snapshot.line_of(head).unwrap();
    let tab = document.whitespace().tab_width;
    let column = logical_column_at(snapshot, ByteOffset(head), tab)?.0;
    let layout = Rows::new(app, view, measure, width).unwrap();
    let walk = layout.walk;
    let left = left.unwrap_or(view.viewport.horizontal_scroll);
    let mut output = Vec::new();
    // The rows shown, each with its line's segment.
    let (top, _) = layout.place(view.viewport.anchor.offset.0);
    let mut place = layout.step(top, first);
    let mut shown: Vec<(Place, Segment)> = vec![];
    let mut segments = layout.segments(place.0);
    while shown.len() < usize::from(rows) {
        shown.push((place, segments[place.1].clone()));
        let next = layout.step(place, 1);
        if next == place {
            break;
        }
        if next.0 != place.0 {
            segments = layout.segments(next.0);
        }
        place = next;
    }
    let rows = usize::from(rows);
    let top = shown.first().map_or(0, |((line, _), _)| *line);
    let bottom = shown.last().map_or(top, |((line, _), _)| line + 1);
    let highlights = highlighter.lines(app, view.document_id, top..bottom);
    let options = app.options();
    let show_tabs = options.bool(Some(view.document_id), "show-tabs");
    let show_trailing = options.bool(Some(view.document_id), "show-trailing-whitespace");
    // The ruler marks the first column past the limit.
    let ruler = match options.int(Some(view.document_id), "ruler") as usize {
        0 => None,
        limit => (limit * measure.column())
            .checked_sub(left)
            .filter(|x| *x < width),
    };
    let patterns: Vec<_> = app.highlights(view.document_id).collect();
    let flags = app.flags(view.document_id);
    let notes = app.notes(view.document_id);
    let mut paints = app.paints(view.document_id);
    if let (Some(ranges), Some(face)) = (
        app.paren(view.id),
        crate::application::faces::index("paren-match"),
    ) {
        paints.extend(
            ranges
                .iter()
                .map(|range| (range.clone(), crate::application::Face::Named(face))),
        );
    }
    let inline_notes = options.bool(Some(view.document_id), "inline-notes");
    let mut text = std::borrow::Cow::Borrowed("");
    let mut faces = vec![];
    let mut categories = vec![];
    let mut trailing_from = 0;
    for ((number, row), segment) in &shown {
        let number = *number;
        let start = snapshot.line_start(number).unwrap();
        if *row == 0 || output.is_empty() {
            text = snapshot.line(number).unwrap();
            trailing_from = text
                .trim_end_matches(['\n', '\r'])
                .trim_end_matches([' ', '\t'])
                .len();
            faces = patterns
                .iter()
                .flat_map(|h| {
                    h.pattern
                        .find_iter(&text)
                        .filter(|m| !m.is_empty())
                        .map(|m| (m.range(), h.face))
                })
                .collect();
            faces.sort_by_key(|(range, _)| range.start);
            faces.extend(paints.iter().filter_map(|(range, face)| {
                let from = range.start.max(start) - start;
                let to = range.end.min(start + text.len()).checked_sub(start)?;
                (from < to).then_some((from..to, *face))
            }));
            // Last, so the worst note's underline wins over everything else.
            faces.extend(notes.iter().filter_map(|note| {
                let from = note.range.start.max(start) - start;
                let to = note.range.end.min(start + text.len()).checked_sub(start)?;
                (from < to).then_some((from..to, Face::Note(note.severity)))
            }));
            // flash's search shows only its matches over the text receding.
            if let Some(flash) = &modal.flash {
                faces = flash_faces(flash, start, text.len());
            }
            let base = highlights.get(number - top).map_or(&[][..], Vec::as_slice);
            let semantic = app.tokens(view.document_id, start..start + text.len());
            categories = overlay(base, &semantic);
        }
        let last_row = layout
            .wrap
            .is_some()
            .then(|| *row + 1 == layout.segments(number).len());
        let after = |text: String, face: Option<Face>, font: Font| Inlay {
            x: usize::MAX,
            text,
            face,
            font,
        };
        let mut hints: Vec<Inlay> = layout
            .inlays(number)
            .iter()
            .filter(|hint| {
                layout.wrap.is_none()
                    || (hint.x >= segment.xs.start
                        && (hint.x < segment.xs.end || last_row == Some(true)))
            })
            .cloned()
            .collect();
        // A digit at the end of a line has no character to stand on, so it
        // stands after the text, as the indicator does.
        let content = text.trim_end_matches(['\n', '\r']).len();
        if last_row != Some(false) {
            for (_, digit) in modal.digits.iter().filter(|(at, _)| *at == start + content) {
                hints.push(after(digit.to_string(), Some(Face::Digit), Font::Text));
            }
        }
        if last_row != Some(false)
            && let Some(text) = app.indicator(view.document_id, number)
        {
            hints.push(after(format!(" {text}"), Some(Face::Todo), Font::Hint));
        }
        if let Some((offset, preview)) = &modal.preview
            && (start..=start + content).contains(offset)
        {
            let x = walk.x_of(&text, offset - start);
            if layout.wrap.is_none() || segment.xs.contains(&x) || last_row == Some(true) {
                let text: String = preview.chars().filter(|c| !c.is_control()).collect();
                hints.push(Inlay {
                    x,
                    text,
                    face: None,
                    font: Font::Text,
                });
                hints.sort_by_key(|hint| hint.x);
            }
        }
        if last_row != Some(false)
            && inline_notes
            && let Some((note, more)) = worst_note(&notes, start..start + text.len())
        {
            let first = note.text.lines().next().unwrap_or_default();
            let first: String = first.chars().filter(|c| !c.is_control()).collect();
            let more = if more > 0 {
                format!(" (+{more})")
            } else {
                String::new()
            };
            let face = crate::application::faces::index(match note.severity {
                Severity::Error => "note-error",
                Severity::Warning => "note-warning",
                Severity::Info => "note-info",
            })
            .map(Face::Named);
            hints.push(after(
                format!("    {}{more}", first.trim()),
                face,
                Font::Hint,
            ));
        }
        let marks = Marks {
            selection: state.selection().range(),
            grab: modal.grab.clone(),
            beacons: row_beacons(&modal.beacons, start..start + text.len()),
            digits: &modal.digits,
            matches: &[],
            detail: text.len(),
            categories: &categories,
            tabs: show_tabs,
            trailing: show_trailing,
            faces: &faces,
            inlays: &hints,
        };
        let (first, room) = match layout.wrap {
            Some(_) if last_row == Some(false) && hints.is_empty() => {
                (segment.xs.start, segment.xs.len().min(width))
            }
            Some(_) => (segment.xs.start, width),
            None => (left, width),
        };
        let highlight_end =
            (number + 1 == snapshot.line_count() && last_row != Some(false)).then(|| {
                let end = if layout.wrap.is_some() {
                    segment.xs.end
                } else {
                    walk.x_of(&text, content)
                };
                let hints = layout
                    .inlays(number)
                    .iter()
                    .filter(|hint| first <= hint.x && hint.x < end)
                    .map(|hint| text_width(measure, &hint.text, hint.font))
                    .sum::<usize>();
                end.saturating_sub(first).saturating_add(hints).min(room)
            });
        output.push(Row {
            line: number,
            continued: *row > 0,
            numbered: *row == 0 && number < snapshot.text_lines(),
            highlight_end,
            flag: flags
                .get(&number)
                .filter(|_| *row == 0)
                .map(|flag| (*flag).clone()),
            digit: modal
                .line_digits
                .iter()
                .find(|(line, _)| *line == number && *row == 0)
                .map(|(_, digit)| *digit),
            spans: styled_row_from(
                &text,
                start,
                marks,
                first,
                room,
                walk,
                RowSlice {
                    bytes: segment.start
                        ..layout
                            .segments(number)
                            .get(*row + 1)
                            .map_or(text.len(), |next| next.start),
                    x: segment.xs.start,
                    trailing_from,
                },
            ),
        });
    }
    let line_of = |offset| snapshot.line_of(offset);
    let note = notes
        .iter()
        .rev()
        .find(|note| note.range.contains(&head) || note.range.end == head)
        .or_else(|| {
            notes
                .iter()
                .rev()
                .find(|note| line_of(note.range.start) == Some(line))
        })
        .map(|note| (note.severity, note.text.to_owned()));
    let count = |severity| {
        notes
            .iter()
            .filter(|note| note.severity == severity)
            .count()
    };
    let problems = (count(Severity::Error), count(Severity::Warning));
    let (caret_place, caret_x) = layout.place(head);
    let caret_width = {
        let text = snapshot.line(line).unwrap_or_default();
        let within = head - snapshot.line_start(line).unwrap_or(head);
        let cluster = text
            .get(within..)
            .and_then(|rest| rest.graphemes(true).next());
        // On a tab it stays a column wide, as Emacs keeps it unless
        // `x-stretch-cursor` is set.
        cluster
            .filter(|cluster| *cluster != "\t")
            .map_or(0, |cluster| walk.advance(cluster, caret_x))
            .max(measure.column())
    };
    let cursor = shown
        .iter()
        .position(|(place, _)| *place == caret_place)
        .filter(|_| rows > 0 && width > 0)
        .and_then(|y| {
            let first = match layout.wrap {
                Some(_) => shown[y].1.xs.start,
                None => left,
            };
            // A caret at the end of a full row stays on its last character.
            let x = caret_x.checked_sub(first)? + layout.hinted(line, first, caret_x);
            let x = if layout.wrap.is_some() {
                x.min(width.saturating_sub(measure.column()))
            } else {
                x
            };
            (x < width).then_some((x, y))
        });
    Ok(Some(Frame {
        rows: output,
        cursor,
        caret_width,
        caret: (line, column),
        language: document.language().profile().name.clone(),
        ruler,
        note,
        problems,
    }))
}

/// The worst note starting on a line, the latest of equals, and how many
/// others start there.
fn worst_note<'a>(
    notes: &'a [crate::application::Note<'a>],
    line: std::ops::Range<usize>,
) -> Option<(&'a crate::application::Note<'a>, usize)> {
    let mut on_line = notes.iter().filter(|note| {
        line.contains(&note.range.start) || (line.is_empty() && note.range.start == line.start)
    });
    let first = on_line.next()?;
    let (worst, count) = on_line.fold((first, 1), |(worst, count), note| {
        let worse = note.severity >= worst.severity;
        (if worse { note } else { worst }, count + 1)
    });
    Some((worst, count - 1))
}

pub(crate) fn prompt_row(
    presentation: &crate::interaction::Presentation,
    width: usize,
) -> (Vec<Span>, Option<usize>) {
    let tab = NonZeroUsize::new(4).unwrap();
    let cursor = presentation.cursor.map(|offset| {
        let column = column_width(&presentation.text[..offset], 0, tab);
        let cluster = presentation.text[offset..]
            .graphemes(true)
            .next()
            .unwrap_or("");
        let caret_cells = (column_width(cluster, column, tab) - column)
            .max(1)
            .min(width);
        let left = column.saturating_add(caret_cells).saturating_sub(width);
        (left, column - left)
    });
    let left = cursor.map_or(0, |(left, _)| left);
    (
        row(
            &presentation.text,
            0,
            presentation.selection.clone(),
            left,
            width,
            tab,
        ),
        cursor.map(|(_, column)| column),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame(
        app: &mut Application,
        width: u16,
        height: u16,
    ) -> Result<Frame, crate::application::Error> {
        if let Some(viewport) = super::follow_caret(
            app,
            app.active_view().unwrap(),
            &Cells,
            width.into(),
            height,
        )? {
            app.dispatch(Event::SetViewport {
                view: viewport.view,
                anchor: viewport.anchor,
                horizontal_scroll: viewport.horizontal_scroll,
            })?;
        }
        Ok(super::frame(
            app,
            app.active_view().unwrap(),
            &mut Highlighter::default(),
            &Cells,
            width.into(),
            0,
            None,
            height,
            &Overlay::default(),
        )?
        .unwrap())
    }

    use crate::{
        application::Event,
        core::Selection,
        cpp::CppStyle,
        editor::{Command, Language},
    };
    use std::time::Duration;
    fn app(text: &str, language: Language) -> Application {
        let mut app = Application::default();
        app.dispatch(Event::NewDocument(language)).unwrap();
        let view = app.active_view().unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::InsertText(text.into()),
            time: Duration::ZERO,
        })
        .unwrap();
        app
    }
    fn joined_row(row: &super::Row) -> String {
        row.spans.iter().map(padded).collect()
    }
    fn joined(spans: Vec<Span>) -> String {
        spans.iter().map(padded).collect()
    }
    #[test]
    fn eof_rows_keep_carets_without_extra_numbers_or_extended_backgrounds() {
        for (text, numbered, ends) in [
            ("", vec![true], vec![Some(0)]),
            ("abc", vec![true], vec![Some(3)]),
            ("abc\n", vec![true, false], vec![None, Some(0)]),
            (
                "abc\n\n",
                vec![true, true, false],
                vec![None, None, Some(0)],
            ),
            ("abc\r\n", vec![true, false], vec![None, Some(0)]),
        ] {
            let mut app = app(text, Language::PlainText);
            let shown = frame(&mut app, 20, 5).unwrap();
            assert_eq!(
                shown
                    .rows
                    .iter()
                    .map(|row| row.numbered)
                    .collect::<Vec<_>>(),
                numbered,
                "{text:?}"
            );
            assert_eq!(
                shown
                    .rows
                    .iter()
                    .map(|row| row.highlight_end)
                    .collect::<Vec<_>>(),
                ends,
                "{text:?}"
            );
            assert!(shown.cursor.is_some(), "{text:?}");
        }
    }
    #[test]
    fn eof_background_bounds_follow_wrapping_scrolling_and_measured_widths() {
        let mut wrapped = app("abcdefghij", Language::PlainText);
        wrapped
            .dispatch(Event::SetOption {
                scope: crate::options::Scope::Global,
                name: "wrap",
                value: crate::options::Value::Bool(true),
            })
            .unwrap();
        let shown = frame(&mut wrapped, 4, 5).unwrap();
        assert_eq!(
            shown
                .rows
                .iter()
                .map(|row| row.highlight_end)
                .collect::<Vec<_>>(),
            [None, None, Some(2)]
        );
        assert_eq!(
            shown
                .rows
                .iter()
                .map(|row| row.numbered)
                .collect::<Vec<_>>(),
            [true, false, false]
        );
        let app = app("\t中e\u{301}", Language::PlainText);
        let view = app.active_view().unwrap();
        for (left, end) in [(0, 7), (5, 2), (20, 0)] {
            let shown = super::frame(
                &app,
                view,
                &mut Highlighter::default(),
                &Cells,
                20,
                0,
                Some(left),
                3,
                &Overlay::default(),
            )
            .unwrap()
            .unwrap();
            assert_eq!(shown.rows[0].highlight_end, Some(end));
        }
        struct Pixels;
        impl Measure for Pixels {
            fn width(&self, text: &str, font: Font) -> usize {
                Cells.width(text, font) * 10
            }
            fn column(&self) -> usize {
                10
            }
        }
        let shown = super::frame(
            &app,
            view,
            &mut Highlighter::default(),
            &Pixels,
            200,
            0,
            None,
            3,
            &Overlay::default(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(shown.rows[0].highlight_end, Some(70));
    }
    #[test]
    fn highlighted_patterns_style_their_spans() {
        let mut app = app("a TODO b TODO", Language::PlainText);
        app.dispatch(Event::Highlight {
            document: None,
            face: Some(crate::application::Face::Todo),
            mark: false,
            pattern: regex::Regex::new("TODO").unwrap(),
        })
        .unwrap();
        let mut frame = frame(&mut app, 20, 2).unwrap();
        let spans = std::mem::take(&mut frame.rows[0].spans);
        let faced: Vec<_> = spans
            .iter()
            .filter(|span| span.face.is_some())
            .map(|span| span.text.as_str())
            .collect();
        assert_eq!(faced, ["TODO", "TODO"]);
    }
    #[test]
    fn whitespace_marks_and_the_ruler_follow_their_options() {
        let mut app = app("a\tb c  \nx", Language::PlainText);
        let set = |app: &mut Application, name, value| {
            app.dispatch(Event::SetOption {
                scope: crate::options::Scope::Global,
                name,
                value,
            })
            .unwrap();
        };
        let first = |frame: &mut Frame| std::mem::take(&mut frame.rows[0].spans);
        let mut plain = frame(&mut app, 20, 3).unwrap();
        assert_eq!(joined(first(&mut plain)), "a   b c  ");
        assert_eq!(plain.ruler, None);
        // Each kind of whitespace has its own switch.
        set(&mut app, "show-tabs", crate::options::Value::Bool(true));
        let mut tabs = frame(&mut app, 20, 3).unwrap();
        assert_eq!(joined(first(&mut tabs)), "a»  b c  ");
        set(&mut app, "show-tabs", crate::options::Value::Bool(false));
        set(
            &mut app,
            "show-trailing-whitespace",
            crate::options::Value::Bool(true),
        );
        let mut trailing = frame(&mut app, 20, 3).unwrap();
        assert_eq!(joined(first(&mut trailing)), "a   b c··");
        set(&mut app, "show-tabs", crate::options::Value::Bool(true));
        set(&mut app, "ruler", crate::options::Value::Int(6));
        let mut marked = frame(&mut app, 20, 3).unwrap();
        let spans = first(&mut marked);
        // Inner spaces stay plain; tabs and trailing spaces are marked.
        let marks: Vec<_> = spans
            .iter()
            .filter(|span| span.whitespace)
            .map(padded)
            .collect();
        assert_eq!(marks, ["»  ", "··"]);
        assert_eq!(joined(spans), "a»  b c··");
        assert_eq!(marked.ruler, Some(6));
        // A window narrower than the ruler does not show it.
        assert!(frame(&mut app, 4, 3).unwrap().ruler.is_none());
    }
    #[test]
    fn clipping_expands_tabs_and_preserves_wide_grapheme_boundaries() {
        let tab = NonZeroUsize::new(8).unwrap();
        assert_eq!(joined(row("\t中x", 0, 0..0, 6, 4, tab)), "  中");
        assert_eq!(joined(row("\t中x", 0, 0..0, 9, 2, tab)), " x");
        assert_eq!(joined(row("中x", 0, 0..0, 0, 1, tab)), " ");
        assert_eq!(plain("e\u{301}🦀x", 0, 3), "e\u{301}🦀");
        assert_eq!(plain("abc", 0, 0), "");
    }
    #[test]
    fn control_bytes_never_reach_terminal_output_and_keep_core_width() {
        let text = "a\x1b[31m\x07b";
        let rendered = plain(text, 0, 80);
        assert!(!rendered.chars().any(char::is_control));
        assert_eq!(
            column_width(text, 0, NonZeroUsize::new(4).unwrap()),
            column_width(&rendered, 0, NonZeroUsize::new(4).unwrap())
        );
    }
    #[test]
    fn selection_is_byte_based_and_empty_selection_has_no_highlight() {
        let spans = row("a中b", 10, 11..14, 0, 8, NonZeroUsize::new(4).unwrap());
        assert_eq!(
            spans
                .iter()
                .filter(|s| s.selected)
                .map(|s| s.text.as_str())
                .collect::<String>(),
            "中"
        );
        assert!(
            row("e\u{301}", 0, 1..1, 0, 8, NonZeroUsize::new(4).unwrap())
                .iter()
                .all(|s| !s.selected)
        );
    }
    #[test]
    fn selection_over_a_line_break_takes_a_cell_after_the_text() {
        let tab = NonZeroUsize::new(4).unwrap();
        let width = |spans: Vec<Span>| {
            spans
                .iter()
                .filter(|s| s.selected)
                .map(|s| s.width)
                .sum::<usize>()
        };
        assert_eq!(width(row("ab", 0, 1..3, 0, 8, tab)), 2);
        assert_eq!(width(row("ab", 0, 0..2, 0, 8, tab)), 2);
        assert_eq!(width(row("", 5, 0..10, 0, 8, tab)), 1);
        assert_eq!(width(row("", 5, 0..5, 0, 8, tab)), 0);
        // Not when the line is scrolled past.
        assert_eq!(width(row("ab", 0, 0..3, 4, 8, tab)), 0);
    }
    #[test]
    fn wrapped_selection_marks_only_selected_line_breaks() {
        let mut app = app("aaa bbb\n\nccc", Language::PlainText);
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        let view = app.active_view().unwrap();
        for (head, expected) in [
            (7, vec![]),
            (8, vec![(1, 3, 1)]),
            (10, vec![(1, 3, 1), (2, 0, 1)]),
        ] {
            app.dispatch(Event::Edit {
                view,
                command: Command::SetSelection(Selection { anchor: 0, head }),
                time: Duration::ZERO,
            })
            .unwrap();
            let shown = frame(&mut app, 5, 10).unwrap();
            let mut blanks = Vec::new();
            for (row, line) in shown.rows.iter().enumerate() {
                for span in &line.spans {
                    if span.selected && span.text.is_empty() {
                        blanks.push((row, span.x, span.width));
                    }
                }
            }
            assert_eq!(blanks, expected);
        }
    }
    #[test]
    fn frame_uses_document_tab_width_and_reveals_caret_after_resize() {
        let style = CppStyle {
            tab_width: NonZeroUsize::new(8).unwrap(),
            ..Default::default()
        };
        let mut app = app("\t中x\nsecond\nthird", style.compile().unwrap().into());
        let view = app.active_view().unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret("\t中".len())),
            time: Duration::ZERO,
        })
        .unwrap();
        let frame = frame(&mut app, 6, 3).unwrap();
        assert_eq!(frame.cursor, Some((5, 0)));
        assert_eq!(app.view(view).unwrap().viewport.horizontal_scroll, 5);
        let frame = super::frame(
            &app,
            app.active_view().unwrap(),
            &mut Highlighter::default(),
            &Cells,
            0,
            0,
            None,
            0,
            &Overlay::default(),
        )
        .unwrap()
        .unwrap();
        assert!(frame.rows.is_empty());
        assert!(frame.cursor.is_none());
    }
    #[test]
    fn caret_grapheme_stays_visible_at_right_edge() {
        let mut app = app("abcd中", Language::PlainText);
        let view = app.active_view().unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret(4)),
            time: Duration::ZERO,
        })
        .unwrap();
        let frame = frame(&mut app, 5, 2).unwrap();
        assert_eq!(frame.cursor, Some((3, 0)));
        assert_eq!(app.view(view).unwrap().viewport.horizontal_scroll, 1);
        assert_eq!(
            frame.rows[0]
                .spans
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "bcd中"
        );
    }
    #[test]
    fn scrolling_tracks_active_view_independently() {
        let mut app = app("a\nb\nc\nd", Language::PlainText);
        let a = app.active_view().unwrap();
        let document = app.view(a).unwrap().document_id;
        assert_eq!(frame(&mut app, 10, 2).unwrap().cursor, Some((1, 1)));
        let anchor = app.view(a).unwrap().viewport.anchor;
        app.dispatch(Event::AddView(document)).unwrap();
        let b = app.active_view().unwrap();
        assert_eq!(frame(&mut app, 10, 2).unwrap().cursor, Some((0, 0)));
        assert_eq!(app.view(a).unwrap().viewport.anchor, anchor);
        assert_eq!(app.view(b).unwrap().viewport.anchor.offset, ByteOffset(0));
    }
    #[test]
    fn prompt_scroll_keeps_caret_visible_without_splitting_unicode() {
        let text = "Save as: 目录/🦀";
        let (rendered, cursor) = prompt_row(
            &crate::interaction::Presentation {
                text: text.into(),
                cursor: Some(text.len()),
                selection: 0..0,
            },
            5,
        );
        let rendered = joined(rendered);
        assert!(column_width(&rendered, 0, NonZeroUsize::new(4).unwrap()) <= 5);
        assert_eq!(cursor, Some(4));
    }
    #[test]
    fn prompt_selection_and_wide_caret_survive_horizontal_clipping() {
        let presentation = crate::interaction::Presentation {
            text: "Find: a中🦀z".into(),
            cursor: Some("Find: a中".len()),
            selection: "Find: a".len().."Find: a中🦀".len(),
        };
        let (spans, cursor) = prompt_row(&presentation, 4);
        assert_eq!(cursor, Some(2));
        assert_eq!(
            spans
                .iter()
                .filter(|s| s.selected)
                .map(|s| s.text.as_str())
                .collect::<String>(),
            "中🦀"
        );
        assert_eq!(joined(spans), "中🦀");
        let (spans, _) = prompt_row(&presentation, 0);
        assert!(spans.is_empty());
    }
    #[test]
    fn picker_highlights_and_selection_clip_at_grapheme_boundaries() {
        use crate::interaction::picker::{Candidate, CandidateKey, MatchedCandidate};
        let row = MatchedCandidate {
            candidate: std::sync::Arc::new(Candidate {
                key: CandidateKey(1),
                label: "a中e\u{301}🦀".into(),
                payload: (),
            }),
            score: 1,
            highlights: vec![1..4, 4..7],
        };
        let spans = candidate_row(&row, Some(CandidateKey(1)), None, 4);
        assert!(spans.iter().all(|span| span.selected));
        assert_eq!(
            spans
                .iter()
                .filter(|span| span.matched)
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "中e\u{301}"
        );
        assert_eq!(joined(spans), "a中e\u{301}");
        assert!(
            candidate_row(&row, None, Some(1), 4)
                .iter()
                .all(|span| !span.selected)
        );
    }
    #[test]
    fn rendering_is_read_only_even_when_caret_is_outside_viewport() {
        let mut app = Application::default();
        app.dispatch(Event::NewDocument(Language::PlainText))
            .unwrap();
        let view = app.active_view().unwrap();
        app.dispatch(Event::Edit {
            view,
            command: crate::editor::Command::InsertText("abcdefghijklmnopqrstuvwxyz".into()),
            time: std::time::Duration::ZERO,
        })
        .unwrap();
        let before = app.view(view).unwrap().viewport;
        let projected = super::frame(
            &app,
            app.active_view().unwrap(),
            &mut Highlighter::default(),
            &Cells,
            10,
            0,
            None,
            4,
            &Overlay::default(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(app.view(view).unwrap().viewport, before);
        assert!(projected.cursor.is_none());
        assert!(
            super::follow_caret(&app, app.active_view().unwrap(), &Cells, 10, 4)
                .unwrap()
                .is_some()
        );
    }
    #[test]
    fn wrapped_lines_break_after_spaces_and_inside_long_words() {
        let walk = Walk::new(&Cells, NonZeroUsize::new(4).unwrap());
        let rows = |text: &str, width| -> Vec<_> {
            super::segments(text, Some(width), walk)
                .into_iter()
                .map(|s| (s.start, s.xs))
                .collect()
        };
        // Words move to the next row whole; the space stays behind.
        assert_eq!(rows("aaa bbb ccc", 8), [(0, 0..8), (8, 8..11)]);
        assert_eq!(rows("aaa bbb ccc", 6), [(0, 0..4), (4, 4..8), (8, 8..11)]);
        // A word longer than the row breaks where the row ends.
        assert_eq!(rows("abcdefgh", 3), [(0, 0..3), (3, 3..6), (6, 6..8)]);
        // Wide characters do not straddle rows.
        assert_eq!(rows("界界界", 5), [(0, 0..4), (6, 4..6)]);
        assert_eq!(rows("", 5), [(0, 0..0)]);
        assert_eq!(rows("abc", 3), [(0, 0..3)]);
    }
    #[test]
    fn overflowing_word_separator_stays_on_the_preceding_row() {
        let walk = Walk::new(&Cells, NonZeroUsize::new(4).unwrap());
        for separator in [" ", "  ", "\t"] {
            let text = format!("abcPL{separator}提供了描述这些问题的工具");
            let rows = segments(&text, Some(5), walk);
            assert_eq!(rows[0].start, 0);
            assert_eq!(rows[1].start, "abcPL".len() + separator.len());
            for (index, row) in rows.iter().enumerate() {
                let end = rows.get(index + 1).map_or(text.len(), |next| next.start);
                assert!(
                    !text[row.start..end].trim().is_empty(),
                    "{text:?}: {rows:?}"
                );
            }
        }
        let text = "Blob/Log 可以视为一门存储领域语言：它有身份与内容、操作与依赖、资源与保留责任，以及正常执行和崩溃恢复的规则。PL 提供了描述这些问题的工具，但不同问题需要不同工具。所有权类型只处理其中一部分；整个设计还涉及资源协议、表示独立性、效果解释和带恢复的精化。";
        for width in 1..160 {
            let rows = segments(text, Some(width), walk);
            for (index, row) in rows.iter().enumerate() {
                let end = rows.get(index + 1).map_or(text.len(), |next| next.start);
                assert!(
                    !text[row.start..end].trim().is_empty(),
                    "width {width}: {row:?}"
                );
            }
        }
    }

    #[test]
    fn trailing_whitespace_does_not_create_an_empty_continuation() {
        let walk = Walk::new(&Cells, NonZeroUsize::new(4).unwrap());
        for ending in ["", "\n", "\r\n"] {
            for spaces in [" ", "  ", "\t", " \t "] {
                let text = format!("abcPL{spaces}{ending}");
                let rows = segments(&text, Some(5), walk);
                assert_eq!(rows.len(), 1, "{text:?}");
                assert_eq!(rows[0].start, 0);
            }
        }
        let mut app = app("abcPL \nnext", Language::PlainText);
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        let view = app.active_view().unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret(6)),
            time: Duration::ZERO,
        })
        .unwrap();
        let shown = frame(&mut app, 5, 5).unwrap();
        assert_eq!(shown.rows.len(), 2);
        assert_eq!(joined_row(&shown.rows[0]), "abcPL");
        assert_eq!(joined_row(&shown.rows[1]), "next");
        assert_eq!(shown.cursor, Some((4, 0)));
        assert_eq!(
            super::position_of(&app, view, &Cells, 5, 5, 7),
            Some((1, 0))
        );
    }

    #[test]
    fn long_lines_wrap_without_disabling_neighboring_lines() {
        let long = "x ".repeat(10_000);
        let mut app = app(
            &format!("short words here\n{long}\nend"),
            Language::PlainText,
        );
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        let view = app.active_view().unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret(0)),
            time: Duration::ZERO,
        })
        .unwrap();
        let shown = frame(&mut app, 10, 5).unwrap();
        let lines: Vec<_> = shown
            .rows
            .iter()
            .map(|row| (row.line, row.continued))
            .collect();
        assert_eq!(
            lines,
            [(0, false), (0, true), (1, false), (1, true), (1, true)]
        );
    }
    #[test]
    fn wrapping_measures_each_line_once_and_only_draws_visible_suffixes() {
        struct Counted(std::cell::Cell<usize>);
        impl Measure for Counted {
            fn width(&self, cluster: &str, font: Font) -> usize {
                self.0.set(self.0.get() + 1);
                Cells.width(cluster, font)
            }
            fn column(&self) -> usize {
                1
            }
        }
        let text = "a ".repeat(100_000);
        let mut app = app(&text, Language::PlainText);
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        let view = app.active_view().unwrap();
        app.dispatch(Event::SetViewport {
            view,
            anchor: ByteOffset(190_000),
            horizontal_scroll: 0,
        })
        .unwrap();
        let measure = Counted(std::cell::Cell::new(0));
        let shown = super::frame(
            &app,
            view,
            &mut Highlighter::default(),
            &measure,
            80,
            0,
            None,
            100,
            &Overlay::default(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(shown.rows.len(), 100);
        assert!(shown.rows.iter().all(|row| row.continued));
        // One whole-line measurement, then at most the visible text plus
        // a row for locating each of the viewport and caret.
        assert!(
            measure.0.get() <= text.len() + 80 * 103,
            "{} measurements",
            measure.0.get()
        );
    }

    #[test]
    fn wrapped_coordinates_and_styles_survive_tabs_unicode_edits_and_resize() {
        let mut app = app("a\t中e\u{301}🦀 words\r\nend", Language::PlainText);
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        let view = app.active_view().unwrap();
        for width in [1, 4, 7, 12] {
            let layout = Rows::new(&app, app.view(view).unwrap(), &Cells, width).unwrap();
            let text = layout.snapshot.line(0).unwrap();
            for (offset, cluster) in text.grapheme_indices(true) {
                if cluster.chars().any(char::is_control) {
                    continue;
                }
                let ((line, _), x) = layout.place(offset);
                assert_eq!(layout.offset(line, x), offset, "width {width}");
            }
        }
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret(0)),
            time: Duration::ZERO,
        })
        .unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::InsertText("prefix ".into()),
            time: Duration::ZERO,
        })
        .unwrap();
        let shown = frame(&mut app, 7, 20).unwrap();
        assert_eq!(joined_row(&shown.rows[0]), "prefix ");
        assert_eq!(shown.rows[1].line, 0);
        assert!(shown.rows[1].continued);
        assert_eq!(shown.cursor, Some((0, 1)));
    }

    #[test]
    fn wrapped_rows_keep_selection_and_preview_within_their_segment() {
        let mut app = app("aaa bbb ccc", Language::PlainText);
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        let view = app.active_view().unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection { anchor: 2, head: 6 }),
            time: Duration::ZERO,
        })
        .unwrap();
        let shown = frame(&mut app, 6, 10).unwrap();
        let selected: String = shown
            .rows
            .iter()
            .flat_map(|row| &row.spans)
            .filter(|span| span.selected)
            .map(|span| span.text.as_str())
            .collect();
        assert_eq!(selected, "a bb");
        let shown = super::frame(
            &app,
            view,
            &mut Highlighter::default(),
            &Cells,
            6,
            0,
            None,
            10,
            &Overlay {
                preview: Some((0, "!".into())),
                ..Overlay::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(joined_row(&shown.rows[0]), "!aaa ");
        assert_eq!(joined_row(&shown.rows[1]), "bbb ");
    }

    #[test]
    fn wrapping_shows_long_lines_on_several_rows() {
        let mut app = app("one two three four\nshort\nlast", Language::PlainText);
        let view = app.active_view().unwrap();
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        // The caret at `four` sits on the second row of the first line.
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret(14)),
            time: Duration::ZERO,
        })
        .unwrap();
        let shown = frame(&mut app, 10, 5).unwrap();
        let rows: Vec<_> = shown
            .rows
            .iter()
            .map(|row| (row.line, row.continued, joined_row(row)))
            .collect();
        assert_eq!(
            rows,
            [
                (0, false, "one two ".to_owned()),
                (0, true, "three four".to_owned()),
                (1, false, "short".to_owned()),
                (2, false, "last".to_owned()),
            ]
        );
        assert_eq!(shown.cursor, Some((6, 1)));
        // A click on the second row lands on it; past its end, on its end.
        assert_eq!(super::offset_at(&app, &Cells, 10, 1, 0), Some(8));
        assert_eq!(super::offset_at(&app, &Cells, 10, 0, 9), Some(7));
        assert_eq!(super::offset_at(&app, &Cells, 10, 2, 2), Some(21));
        assert_eq!(
            super::position_of(&app, view, &Cells, 10, 5, 21),
            Some((2, 2))
        );
        // In two rows the caret's row stays in view: the view starts on the
        // first line's second row and scrolls by rows.
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret(20)),
            time: Duration::ZERO,
        })
        .unwrap();
        let shown = frame(&mut app, 10, 2).unwrap();
        assert_eq!(joined_row(&shown.rows[0]), "three four");
        assert_eq!(shown.cursor, Some((1, 1)));
        let (viewport, reveal) = super::scroll(&app, view, &Cells, -1, 10, 2).unwrap();
        assert_eq!(viewport.anchor, ByteOffset(0));
        // The caret comes back to the bottom row, at its column in the row.
        assert_eq!(reveal, Some(9));
    }
    #[test]
    fn pointer_cells_resolve_to_offsets_and_scrolling_keeps_the_caret_visible() {
        let mut app = app("a\tb\nl1\nl2\nl3\nl4", Language::PlainText);
        let view = app.active_view().unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret(0)),
            time: Duration::ZERO,
        })
        .unwrap();
        frame(&mut app, 10, 2).unwrap();
        // Columns inside a tab resolve to the tab; past the end, to the end.
        assert_eq!(super::offset_at(&app, &Cells, 80, 0, 3), Some(1));
        assert_eq!(super::offset_at(&app, &Cells, 80, 0, 40), Some(3));
        assert_eq!(super::offset_at(&app, &Cells, 80, 1, 1), Some(5));
        assert_eq!(super::offset_at(&app, &Cells, 80, -1, 0), Some(0));
        assert_eq!(super::offset_at(&app, &Cells, 80, 9, 0), Some(13));
        let (viewport, reveal) =
            super::scroll(&app, app.active_view().unwrap(), &Cells, 3, 80, 2).unwrap();
        assert_eq!(viewport.anchor, ByteOffset(10));
        assert_eq!(reveal, Some(10));
        // The last line can scroll to the top and no further.
        let (viewport, _) =
            super::scroll(&app, app.active_view().unwrap(), &Cells, 30, 80, 2).unwrap();
        assert_eq!(viewport.anchor, ByteOffset(13));
        assert_eq!(
            super::scroll(&app, app.active_view().unwrap(), &Cells, -1, 80, 2)
                .unwrap()
                .1,
            None
        );
    }
    #[test]
    fn semantic_tokens_replace_the_category_under_them() {
        use crate::syntax::Category::{Function, Keyword, Type};
        let base = [(0..4, Keyword), (6..10, Keyword)];
        assert_eq!(
            super::overlay(&base, &[(2..3, Type), (6..8, Function)]),
            [
                (0..2, Keyword),
                (2..3, Type),
                (3..4, Keyword),
                (6..8, Function),
                (8..10, Keyword)
            ]
        );
    }

    /// Ten units a column, and hints in a smaller font: a frontend that
    /// measures in pixels lays text out by the same rules as cells.
    struct Pixels;
    impl Measure for Pixels {
        fn width(&self, cluster: &str, font: Font) -> usize {
            Cells.width(cluster, font) * if font == Font::Hint { 7 } else { 10 }
        }
        fn column(&self) -> usize {
            10
        }
    }
    #[test]
    fn wrapped_parameter_hints_stay_before_arguments() {
        let mut app = app("call(ARG);", Language::PlainText);
        let view = app.active_view().unwrap();
        let document = app.view(view).unwrap().document_id;
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        app.dispatch(Event::Inlays {
            document,
            hints: vec![(0, 5, "arg: ".into())],
        })
        .unwrap();
        let shown = frame(&mut app, 80, 3).unwrap();
        assert_eq!(
            shown.rows[0]
                .spans
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "call(arg: ARG);"
        );
        let shown = frame(&mut app, 10, 3).unwrap();
        let text: String = shown
            .rows
            .iter()
            .flat_map(|row| row.spans.iter())
            .map(|span| span.text.as_str())
            .collect();
        assert_eq!(text, "call(arg: ARG);");
        assert_eq!(
            super::position_of(&app, view, &Cells, 10, 3, 5),
            Some((1, 5))
        );
        assert_eq!(super::offset_at(&app, &Cells, 10, 1, 2), Some(5));
    }

    #[test]
    fn other_measures_place_text_hints_and_the_caret_by_their_widths() {
        let mut app = app("a\t中x", Language::PlainText);
        let view = app.active_view().unwrap();
        let document = app.view(view).unwrap().document_id;
        app.dispatch(Event::Inlays {
            document,
            hints: vec![(0, "a\t中".len(), "h: ".into())],
        })
        .unwrap();
        app.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "ruler",
            value: crate::options::Value::Int(3),
        })
        .unwrap();
        app.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret("a\t中".len())),
            time: Duration::ZERO,
        })
        .unwrap();
        let shown = super::frame(
            &app,
            view,
            &mut Highlighter::default(),
            &Pixels,
            200,
            0,
            None,
            2,
            &Overlay::default(),
        )
        .unwrap()
        .unwrap();
        let spans: Vec<_> = shown.rows[0]
            .spans
            .iter()
            .map(|span| (span.x, span.width, span.text.as_str(), span.inlay))
            .collect();
        // The tab runs to the stop at four columns; the hint is narrower.
        assert_eq!(
            spans,
            [
                (0, 10, "a", false),
                (10, 30, "", false),
                (40, 20, "中", false),
                (60, 21, "h: ", true),
                (81, 10, "x", false),
            ]
        );
        assert_eq!(shown.cursor, Some((81, 0)));
        assert_eq!(shown.caret, (0, 6));
        assert_eq!(shown.ruler, Some(30));
        // Back from a place: inside the tab, the wide character, the hint.
        let at = |across| super::offset_at(&app, &Pixels, 200, 0, across);
        assert_eq!(at(25), Some(1));
        assert_eq!(at(55), Some(2));
        assert_eq!(at(70), Some("a\t中".len()));
        assert_eq!(at(500), Some("a\t中x".len()));
        assert_eq!(
            super::position_of(&app, view, &Pixels, 200, 2, "a\t中".len()),
            Some((0, 81))
        );
        // Scrolled sideways by units, so that the caret's right edge shows.
        let follow = super::follow_caret(&app, view, &Pixels, 50, 2)
            .unwrap()
            .unwrap();
        assert_eq!(follow.horizontal_scroll, 81 + 10 - 50);
    }
    #[test]
    fn frames_start_rows_away_from_the_top_and_anchors_count_rows_between() {
        let mut app = app("a\nb\nc\nd\ne", Language::PlainText);
        let view = app.active_view().unwrap();
        app.dispatch(Event::SetViewport {
            view,
            anchor: ByteOffset(4),
            horizontal_scroll: 0,
        })
        .unwrap();
        let lines = |first| {
            let frame = super::frame(
                &app,
                view,
                &mut Highlighter::default(),
                &Cells,
                10,
                first,
                None,
                3,
                &Overlay::default(),
            )
            .unwrap()
            .unwrap();
            frame.rows.iter().map(|row| row.line).collect::<Vec<_>>()
        };
        // From the top, a row above it, and a row below.
        assert_eq!(lines(0), [2, 3, 4]);
        assert_eq!(lines(-1), [1, 2, 3]);
        assert_eq!(lines(1), [3, 4]);
        let between = |from, to| super::rows_between(&app, view, &Cells, 10, from, to, 10);
        assert_eq!(between(0, 6), Some(3));
        assert_eq!(between(6, 0), Some(-3));
        assert_eq!(between(4, 4), Some(0));
        assert_eq!(super::rows_between(&app, view, &Cells, 10, 0, 8, 2), None);
    }
}
