use super::highlight::Highlighter;
use crate::{
    application::{Application, Face, Severity, ViewId},
    core::{
        ByteOffset, LogicalColumn, column_width, logical_column_at, offset_at_logical_column,
        step_grapheme,
    },
    syntax::Category,
};
use std::num::NonZeroUsize;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug)]
pub(super) struct Span {
    pub text: String,
    pub selected: bool,
    pub matched: bool,
    /// Secondary text, such as a candidate's description.
    pub detail: bool,
    pub category: Option<Category>,
    /// A visible tab or trailing space mark.
    pub whitespace: bool,
    pub face: Option<crate::application::Face>,
    /// An inlay hint, which is not in the text.
    pub inlay: bool,
}
/// One screen row: the zero-based line it shows and its clipped text.
pub(super) struct Row {
    pub line: usize,
    /// A later row of a wrapped line, which has no number.
    pub continued: bool,
    /// The line's flag, on its first row.
    pub flag: Option<crate::application::Flag>,
    pub spans: Vec<Span>,
}
/// The text area of the active view, positioned relative to its top left.
pub(super) struct Frame {
    pub rows: Vec<Row>,
    pub cursor: Option<(u16, u16)>,
    /// Zero-based line and logical column of the caret.
    pub caret: (usize, usize),
    pub line_count: usize,
    /// The highlighting language's display name.
    pub language: String,
    /// The column of the ruler on screen, when it is in view.
    pub ruler: Option<u16>,
    /// The note to show for the caret: the worst at it, else on its line.
    pub note: Option<(crate::application::Severity, String)>,
    /// Errors and warnings in the document.
    pub problems: (usize, usize),
}

/// Clip by terminal cells. Partially visible tabs/wide graphemes become spaces;
/// control characters never pass through to the terminal command stream.
pub(super) fn row(
    text: &str,
    byte_start: usize,
    selection: std::ops::Range<usize>,
    left: usize,
    width: usize,
    tab: NonZeroUsize,
) -> Vec<Span> {
    let marks = Marks {
        selection,
        beacons: &[],
        digits: &[],
        matches: &[],
        detail: text.len(),
        categories: &[],
        whitespace: false,
        faces: &[],
        inlays: &[],
    };
    styled_row(text, byte_start, marks, left, width, tab)
}
/// What the modal layer shows over the text of the active window.
#[derive(Default)]
pub(super) struct Overlay {
    /// The other selections of Beacon.
    pub beacons: Vec<std::ops::Range<usize>>,
    /// Digits that extend the selection, drawn over the character there.
    pub digits: Vec<(usize, char)>,
}
/// Byte ranges styled within a row: the selection is document-relative;
/// matches, the detail offset and highlight categories are relative to the
/// row text, categories ordered and disjoint.
struct Marks<'a> {
    selection: std::ops::Range<usize>,
    /// More selections, of Beacon; carets among them show as one cell.
    beacons: &'a [std::ops::Range<usize>],
    digits: &'a [(usize, char)],
    matches: &'a [std::ops::Range<usize>],
    detail: usize,
    categories: &'a [(std::ops::Range<usize>, Category)],
    /// Mark tabs and trailing spaces.
    whitespace: bool,
    /// Highlighted ranges in the row, ordered by start.
    faces: &'a [(std::ops::Range<usize>, crate::application::Face)],
    /// Hints by logical column, in order. They take cells from the row.
    inlays: &'a [Inlay],
}
/// A hint at a logical column.
#[derive(Clone)]
struct Inlay {
    column: usize,
    text: String,
    face: Option<Face>,
}
fn cells_of(text: &str) -> usize {
    unicode_width::UnicodeWidthStr::width(text)
}
/// What shows of a hint within `room` cells.
fn clipped(text: &str, room: usize) -> String {
    let mut used = 0;
    text.chars()
        .take_while(|ch| {
            used += unicode_width::UnicodeWidthChar::width(*ch).unwrap_or(0);
            used <= room
        })
        .collect()
}
/// A row's text with categories of `over` replacing those of `base`; both
/// are ordered and disjoint.
pub(super) fn overlay(
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
fn styled_row(
    text: &str,
    byte_start: usize,
    marks: Marks,
    left: usize,
    width: usize,
    tab: NonZeroUsize,
) -> Vec<Span> {
    let Marks {
        selection,
        beacons,
        digits,
        matches,
        detail,
        categories,
        whitespace,
        faces,
        inlays,
    } = marks;
    // Spaces and tabs from here to the end of the line trail.
    let trailing = text.trim_end_matches(['\n', '\r']);
    let trailing = trailing.trim_end_matches([' ', '\t']).len();
    let mut spans = Vec::<Span>::new();
    let mut next_category = 0;
    let mut column = 0;
    let mut right = left.saturating_add(width);
    let mut next_inlay = 0;
    // Each hint shown leaves that many fewer cells for the text.
    let mut hint = |until: usize, column: usize, right: &mut usize, spans: &mut Vec<Span>| {
        while let Some(inlay) = inlays.get(next_inlay).filter(|i| i.column <= until) {
            next_inlay += 1;
            if inlay.column < left {
                continue;
            }
            let shown = clipped(&inlay.text, right.saturating_sub(column.max(left)));
            if shown.is_empty() {
                continue;
            }
            *right -= cells_of(&shown);
            spans.push(Span {
                text: shown,
                selected: false,
                matched: false,
                detail: false,
                category: None,
                whitespace: false,
                face: inlay.face,
                inlay: inlay.face.is_none(),
            });
        }
    };
    for (offset, cluster) in text.grapheme_indices(true) {
        hint(column, column, &mut right, &mut spans);
        let end = column_width(cluster, column, tab);
        let cells = end - column;
        if column >= right {
            break;
        }
        if end > left && cells > 0 {
            let visible = end.min(right).saturating_sub(column.max(left));
            let marked = whitespace && (cluster == "\t" || (cluster == " " && offset >= trailing));
            let digit = digits
                .iter()
                .find(|(place, _)| *place == byte_start + offset)
                .map(|(_, digit)| *digit);
            let rendered = if let Some(digit) = digit {
                format!("{digit}{}", " ".repeat(visible.saturating_sub(1)))
            } else if marked && column >= left {
                let mark = if cluster == "\t" { "»" } else { "·" };
                format!("{mark}{}", " ".repeat(visible - 1))
            } else if cluster == "\t" || column < left || end > right {
                " ".repeat(visible)
            } else if cluster.chars().any(char::is_control) {
                "�".into()
            } else {
                cluster.into()
            };
            let at = byte_start + offset;
            let selected = (!selection.is_empty()
                && at < selection.end
                && at + cluster.len() > selection.start)
                || beacons.iter().any(|beacon| {
                    at < beacon.end.max(beacon.start + 1) && at + cluster.len() > beacon.start
                });
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
            // The last highlight to start wins where they overlap.
            let face = faces
                .iter()
                .rev()
                .find(|(range, _)| range.start <= offset && offset < range.end)
                .map(|(_, face)| *face)
                .or(digit.map(|_| Face::Todo));
            if let Some(last) = spans.last_mut().filter(|last| {
                last.selected == selected
                    && last.matched == matched
                    && last.detail == secondary
                    && last.category == category
                    && last.whitespace == marked
                    && last.face == face
                    && !last.inlay
            }) {
                last.text.push_str(&rendered);
            } else {
                spans.push(Span {
                    text: rendered,
                    selected,
                    matched,
                    detail: secondary,
                    category,
                    whitespace: marked,
                    face,
                    inlay: false,
                });
            }
        }
        column = end;
    }
    if column < right {
        hint(usize::MAX, column, &mut right, &mut spans);
    }
    spans
}
/// A candidate label with its matched ranges; text from `detail` on is
/// secondary.
pub(super) fn candidate_row<T>(
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
        beacons: &[],
        digits: &[],
        matches: &row.highlights,
        detail: detail.unwrap_or(text.len()),
        categories: &[],
        whitespace: false,
        faces: &[],
        inlays: &[],
    };
    styled_row(text, 0, marks, 0, width, NonZeroUsize::new(4).unwrap())
}
/// Lines of `text` at most `width` cells wide, broken at spaces where they
/// can be.
pub(super) fn wrap(text: &str, width: usize) -> Vec<String> {
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
pub(super) fn plain(text: &str, left: usize, width: usize) -> String {
    row(text, 0, 0..0, left, width, NonZeroUsize::new(4).unwrap())
        .into_iter()
        .map(|span| span.text)
        .collect()
}

/// The part of a line one screen row shows: where it starts in the line's
/// text and the logical columns it covers.
#[derive(Clone, Debug, PartialEq)]
struct Segment {
    start: usize,
    columns: std::ops::Range<usize>,
}
/// Splits a line into screen rows `width` cells wide, breaking after the
/// last space that fits and inside a word only when none does. Without a
/// width the line is one row, cut at the edge and scrolled sideways.
fn segments(text: &str, width: Option<usize>, tab: NonZeroUsize) -> Vec<Segment> {
    let Some(width) = width.map(|w| w.max(1)) else {
        return vec![Segment {
            start: 0,
            columns: 0..usize::MAX,
        }];
    };
    let mut out = vec![];
    let (mut start, mut first) = (0, 0);
    let mut space = None;
    let mut column = 0;
    for (offset, cluster) in text.grapheme_indices(true) {
        let end = column_width(cluster, column, tab);
        while end - first > width && column > first {
            let (at, at_column) = space.take().unwrap_or((offset, column));
            out.push(Segment {
                start,
                columns: first..at_column,
            });
            (start, first) = (at, at_column);
        }
        if cluster == " " || cluster == "\t" {
            space = Some((offset + cluster.len(), end));
        }
        column = end;
    }
    out.push(Segment {
        start,
        columns: first..column.max(first),
    });
    out
}
/// Lines longer than this, minified code most often, are not wrapped:
/// wrapping measures a whole line again for each row it shows, so a long
/// one costs a frame seconds, while an unwrapped line costs what is seen.
const WRAP_LIMIT: usize = 4096;
/// Rows a screen may show on either side of a place, more than any has.
const WRAP_REACH: usize = 256;
/// Whether a line too long to wrap could be on screen around `places`,
/// the viewport's top and the caret: `wrap` falls back to unwrapped rows
/// while one is.
fn long_line_near(snapshot: &crate::core::Snapshot, places: &[usize]) -> bool {
    places.iter().any(|offset| {
        let line = snapshot
            .line_of((*offset).min(snapshot.len_bytes()))
            .unwrap_or(0);
        let first = line.saturating_sub(WRAP_REACH);
        let last = (line + WRAP_REACH).min(snapshot.line_count());
        let mut start = snapshot.line_start(first).unwrap_or(0);
        (first + 1..=last).any(|next| {
            let end = snapshot.line_start(next).unwrap_or(snapshot.len_bytes());
            let long = end - start > WRAP_LIMIT;
            start = end;
            long
        })
    })
}
/// A screen row: a line and which of its segments.
type Place = (usize, usize);
/// How one view's lines meet its text area.
struct Rows<'a> {
    snapshot: &'a crate::core::Snapshot,
    tab: NonZeroUsize,
    wrap: Option<usize>,
    /// Lines shown, the empty one after a final newline too: the caret can
    /// go there, as at the end of an Emacs buffer.
    lines: usize,
    /// Hints by line, when they are shown.
    inlays: std::collections::BTreeMap<usize, Vec<Inlay>>,
    /// Rows of wrapped lines measured so far.
    measured: std::cell::RefCell<std::collections::HashMap<usize, std::rc::Rc<[Segment]>>>,
}
impl<'a> Rows<'a> {
    fn new(app: &'a Application, view: &crate::application::View, width: u16) -> Option<Self> {
        let document = app.workspace().editor(view.document_id)?.model().document();
        let snapshot = document.snapshot();
        let wrap = app
            .options()
            .bool(Some(view.document_id), "wrap")
            .then_some(usize::from(width))
            .filter(|_| {
                let session = app
                    .workspace()
                    .editor(view.document_id)
                    .and_then(|editor| editor.model().session(view.session_id));
                let head = session.map_or(0, |session| session.state().selection().head);
                !long_line_near(snapshot, &[view.viewport.anchor.offset.0, head])
            });
        let tab = document.whitespace().tab_width;
        let mut inlays = std::collections::BTreeMap::<usize, Vec<Inlay>>::new();
        if app.options().bool(Some(view.document_id), "inlay-hints") {
            for (offset, text) in app.inlays(view.document_id) {
                let line = snapshot.line_of(offset)?;
                let column = logical_column_at(snapshot, ByteOffset(offset), tab).ok()?.0;
                let text = text.chars().filter(|c| !c.is_control()).collect();
                inlays.entry(line).or_default().push(Inlay {
                    column,
                    text,
                    face: None,
                });
            }
        }
        Some(Self {
            snapshot,
            tab,
            wrap,
            lines: snapshot.line_count(),
            inlays,
            measured: Default::default(),
        })
    }
    /// The cells hints take from `left` up to a character at `column`. A
    /// wrapped line keeps its hints at the end, so it has none to count.
    fn hinted(&self, line: usize, left: usize, column: usize) -> usize {
        if self.wrap.is_some() {
            return 0;
        }
        let hints = self.inlays.get(&line).map_or(&[][..], Vec::as_slice);
        hints
            .iter()
            .filter(|hint| (left..=column).contains(&hint.column))
            .map(|hint| cells_of(&hint.text))
            .sum()
    }
    /// The logical column under a cell `cells` right of `left`; a cell of a
    /// hint counts as the character after it.
    fn unhinted(&self, line: usize, left: usize, cells: usize) -> usize {
        let mut used = 0;
        if self.wrap.is_none() {
            for hint in self.inlays.get(&line).into_iter().flatten() {
                if hint.column < left {
                    continue;
                }
                let start = hint.column - left + used;
                if cells < start {
                    break;
                }
                let width = cells_of(&hint.text);
                if cells < start + width {
                    return hint.column;
                }
                used += width;
            }
        }
        left + cells - used
    }
    /// A line's rows. Moving over rows asks for the same lines again and
    /// again, so each is measured once.
    fn segments(&self, line: usize) -> std::rc::Rc<[Segment]> {
        if self.wrap.is_none() {
            return segments("", None, self.tab).into();
        }
        self.measured
            .borrow_mut()
            .entry(line)
            .or_insert_with(|| {
                segments(
                    &self.snapshot.line(line).unwrap_or_default(),
                    self.wrap,
                    self.tab,
                )
                .into()
            })
            .clone()
    }
    /// The row showing `offset` and the logical column there.
    fn place(&self, offset: usize) -> (Place, usize) {
        let offset = offset.min(self.snapshot.len_bytes());
        let line = self.snapshot.line_of(offset).unwrap().min(self.lines - 1);
        let column =
            logical_column_at(self.snapshot, ByteOffset(offset), self.tab).map_or(0, |c| c.0);
        let within = offset - self.snapshot.line_start(line).unwrap();
        let row = self
            .segments(line)
            .iter()
            .rposition(|segment| segment.start <= within)
            .unwrap_or(0);
        ((line, row), column)
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
pub(super) fn follow_caret(
    app: &Application,
    id: ViewId,
    width: u16,
    rows: u16,
) -> Result<Option<ViewportAdjustment>, crate::application::Error> {
    let view = app.view(id).unwrap();
    let editor = app.workspace().editor(view.document_id).unwrap();
    let state = editor.model().session(view.session_id).unwrap().state();
    let snapshot = editor.model().document().snapshot();
    let head = state.selection().head;
    let layout = Rows::new(app, view, width).unwrap();
    let tab = layout.tab;
    let (place, column) = layout.place(head);
    let rows = usize::from(rows);
    let (mut top, _) = layout.place(view.viewport.anchor.offset.0);
    if rows > 0 {
        if place < top {
            top = place;
        } else if layout.distance(top, place, rows).is_none_or(|d| d >= rows) {
            top = layout.step(place, 1 - rows as isize);
        }
    }
    let mut left = view.viewport.horizontal_column;
    if layout.wrap.is_some() {
        left = 0;
    } else if width > 0 {
        if column < left {
            left = column;
        }
        let next = step_grapheme(snapshot, ByteOffset(head), true)?;
        let cluster = snapshot.byte_slice(head..next.0).unwrap().to_string();
        let caret_cells = (column_width(&cluster, column, tab) - column)
            .max(1)
            .min(usize::from(width));
        let (line, _) = place;
        let caret_end = column.saturating_add(caret_cells) + layout.hinted(line, left, column);
        if caret_end > left.saturating_add(usize::from(width)) {
            left = caret_end - usize::from(width);
        }
    }
    let anchor = ByteOffset(layout.start(top));
    Ok(
        (anchor != view.viewport.anchor.offset || left != view.viewport.horizontal_column)
            .then_some(ViewportAdjustment {
                view: id,
                anchor,
                horizontal_column: left,
            }),
    )
}

/// The row and column, within a view's text area `width` cells wide, that
/// shows `offset`; none when it is scrolled out above or to the left, or
/// more than `rows` rows down.
pub(super) fn cell_of(
    app: &Application,
    view: ViewId,
    width: u16,
    rows: u16,
    offset: usize,
) -> Option<(usize, usize)> {
    let view = app.view(view)?;
    let layout = Rows::new(app, view, width)?;
    let (top, _) = layout.place(view.viewport.anchor.offset.0);
    let (place, column) = layout.place(offset);
    let row = layout.distance(top, place, rows.into())?;
    let first = if layout.wrap.is_some() {
        layout.segments(place.0)[place.1].columns.start
    } else {
        view.viewport.horizontal_column
    };
    let cells = column.checked_sub(first)? + layout.hinted(place.0, first, column);
    Some((row, cells))
}
/// The byte offset under a cell of the active view's text area. Rows past
/// either edge resolve to the lines beyond it, within the document.
pub(super) fn offset_at(app: &Application, width: u16, row: isize, column: usize) -> Option<usize> {
    let view = app.view(app.active_view()?)?;
    let layout = Rows::new(app, view, width)?;
    let (top, _) = layout.place(view.viewport.anchor.offset.0);
    let (line, index) = layout.step(top, row);
    let line = line.min(layout.snapshot.line_count() - 1);
    let column = if layout.wrap.is_some() {
        let segments = layout.segments(line);
        let segment = &segments[index.min(segments.len() - 1)];
        // Past the end of a row that continues, stay on its last cell.
        let last = index + 1 < segments.len();
        let room = segment.columns.len().saturating_sub(usize::from(last));
        segment.columns.start + column.min(room)
    } else {
        layout.unhinted(line, view.viewport.horizontal_column, column)
    };
    offset_at_logical_column(layout.snapshot, line, LogicalColumn(column), layout.tab)
        .ok()
        .map(|offset| offset.0)
}
/// Scrolls the active view by `lines` screen rows, keeping the last line
/// reachable at the top. When the caret leaves the text area, the second
/// value is where it comes back: the nearest visible row, at the same column.
pub(super) fn scroll(
    app: &Application,
    id: ViewId,
    lines: isize,
    width: u16,
    rows: u16,
) -> Option<(ViewportAdjustment, Option<usize>)> {
    let view = app.view(id)?;
    let editor = app.workspace().editor(view.document_id)?;
    let head = editor.model().session(view.session_id)?.selection().head;
    let layout = Rows::new(app, view, width)?;
    let (top, _) = layout.place(view.viewport.anchor.offset.0);
    let top = layout.step(top, lines);
    let top = (top.0.min(layout.snapshot.line_count() - 1), top.1);
    let (place, column) = layout.place(head);
    let rows = usize::from(rows.max(1));
    let bottom = layout.step(top, rows as isize - 1);
    let reveal = (place < top || place > bottom).then(|| {
        let (line, row) = if place < top { top } else { bottom };
        let column = match layout.wrap {
            Some(_) => {
                let within = layout.segments(place.0)[place.1].columns.start;
                let segments = layout.segments(line);
                let segment = &segments[row.min(segments.len() - 1)];
                (segment.columns.start + (column - within)).min(segment.columns.end)
            }
            None => column,
        };
        offset_at_logical_column(layout.snapshot, line, LogicalColumn(column), layout.tab)
            .unwrap()
            .0
    });
    Some((
        ViewportAdjustment {
            view: id,
            anchor: ByteOffset(layout.start(top)),
            horizontal_column: view.viewport.horizontal_column,
        },
        reveal,
    ))
}

pub(super) struct ViewportAdjustment {
    pub view: ViewId,
    pub anchor: ByteOffset,
    pub horizontal_column: usize,
}

/// Render an immutable application projection of the active view's text
/// area. Viewport decisions are applied by Runtime before this is called.
pub(super) fn frame(
    app: &Application,
    id: ViewId,
    highlighter: &mut Highlighter,
    width: u16,
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
    let layout = Rows::new(app, view, width).unwrap();
    let lines = layout.lines;
    let left = view.viewport.horizontal_column;
    let mut output = Vec::new();
    // The rows shown, each with its line's segment.
    let (mut place, _) = layout.place(view.viewport.anchor.offset.0);
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
    let show_whitespace = options.bool(Some(view.document_id), "show-whitespace");
    // The ruler marks the first column past the limit.
    let ruler = match options.int(Some(view.document_id), "ruler") as usize {
        0 => None,
        limit => limit
            .checked_sub(left)
            .filter(|column| *column < usize::from(width))
            .map(|column| column as u16),
    };
    let patterns: Vec<_> = app.highlights(view.document_id).collect();
    let flags = app.flags(view.document_id);
    let notes = app.notes(view.document_id);
    let mut text = std::borrow::Cow::Borrowed("");
    for ((number, row), segment) in &shown {
        let number = *number;
        if *row == 0 || output.is_empty() {
            text = snapshot.line(number).unwrap();
        }
        let mut faces: Vec<_> = patterns
            .iter()
            .flat_map(|h| {
                h.pattern
                    .find_iter(&text)
                    .filter(|m| !m.is_empty())
                    .map(|m| (m.range(), h.face))
            })
            .collect();
        faces.sort_by_key(|(range, _)| range.start);
        // Last, so the worst note's underline wins over everything else.
        let start = snapshot.line_start(number).unwrap();
        faces.extend(notes.iter().filter_map(|note| {
            let from = note.range.start.max(start) - start;
            let to = note.range.end.min(start + text.len()).checked_sub(start)?;
            (from < to).then_some((from..to, Face::Note(note.severity)))
        }));
        let line_start = snapshot.line_start(number).unwrap();
        let base = highlights.get(number - top).map_or(&[][..], Vec::as_slice);
        let semantic = app.tokens(view.document_id, line_start..line_start + text.len());
        let categories = overlay(base, &semantic);
        // A wrapped line would lose what hints push past the edge, so they
        // wait at its end, on a row of their own width.
        let last_row = layout
            .wrap
            .is_some()
            .then(|| *row + 1 == layout.segments(number).len());
        let mut hints: Vec<Inlay> = match last_row {
            None => layout.inlays.get(&number).cloned().unwrap_or_default(),
            Some(false) => vec![],
            Some(true) => (layout.inlays.get(&number).into_iter().flatten())
                .map(|hint| Inlay {
                    column: usize::MAX,
                    text: format!(" {}", hint.text),
                    face: None,
                })
                .collect(),
        };
        // A digit at the end of a line has no character to stand on, so it
        // stands after the text, as the indicator does.
        if last_row != Some(false) {
            let end = line_start + text.trim_end_matches(['\n', '\r']).len();
            for (_, digit) in modal.digits.iter().filter(|(at, _)| *at == end) {
                hints.push(Inlay {
                    column: usize::MAX,
                    text: digit.to_string(),
                    face: Some(Face::Todo),
                });
            }
        }
        if last_row != Some(false)
            && let Some(text) = app.indicator(view.document_id, number)
        {
            hints.push(Inlay {
                column: usize::MAX,
                text: format!(" {text}"),
                face: Some(Face::Todo),
            });
        }
        let marks = Marks {
            selection: state.selection().range(),
            beacons: &modal.beacons,
            digits: &modal.digits,
            matches: &[],
            detail: text.len(),
            categories: &categories,
            whitespace: show_whitespace,
            faces: &faces,
            inlays: &hints,
        };
        let (first, cells) = match layout.wrap {
            Some(_) if hints.is_empty() => (segment.columns.start, segment.columns.len()),
            Some(_) => (segment.columns.start, usize::from(width)),
            None => (left, usize::from(width)),
        };
        output.push(Row {
            line: number,
            continued: *row > 0,
            flag: flags
                .get(&number)
                .filter(|_| *row == 0)
                .map(|flag| (*flag).clone()),
            spans: styled_row(
                &text,
                snapshot.line_start(number).unwrap(),
                marks,
                first,
                cells,
                tab,
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
    let (caret_place, _) = layout.place(head);
    let cursor = shown
        .iter()
        .position(|(place, _)| *place == caret_place)
        .filter(|_| rows > 0 && width > 0)
        .and_then(|y| {
            let first = match layout.wrap {
                Some(_) => shown[y].1.columns.start,
                None => left,
            };
            // A caret at the end of a full row stays on its last cell.
            let x = column.checked_sub(first)? + layout.hinted(line, first, column);
            let x = if layout.wrap.is_some() {
                x.min(usize::from(width) - 1)
            } else {
                x
            };
            (x < usize::from(width)).then_some((x as u16, y as u16))
        });
    Ok(Some(Frame {
        rows: output,
        cursor,
        caret: (line, column),
        line_count: lines,
        language: document.language().profile().name.clone(),
        ruler,
        note,
        problems,
    }))
}

pub(super) fn prompt_row(
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
        if let Some(viewport) = super::follow_caret(app, app.active_view().unwrap(), width, height)?
        {
            app.dispatch(Event::SetViewport {
                view: viewport.view,
                anchor: viewport.anchor,
                horizontal_column: viewport.horizontal_column,
            })?;
        }
        Ok(super::frame(
            app,
            app.active_view().unwrap(),
            &mut Highlighter::default(),
            width,
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
        row.spans.iter().map(|span| span.text.as_str()).collect()
    }
    fn joined(spans: Vec<Span>) -> String {
        spans.into_iter().map(|span| span.text).collect()
    }
    #[test]
    fn highlighted_patterns_style_their_spans() {
        let mut app = app("a TODO b TODO", Language::PlainText);
        app.dispatch(Event::Highlight {
            document: None,
            face: Some(crate::application::Face::Todo),
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
        set(
            &mut app,
            "show-whitespace",
            crate::options::Value::Bool(true),
        );
        set(&mut app, "ruler", crate::options::Value::Int(6));
        let mut marked = frame(&mut app, 20, 3).unwrap();
        let spans = first(&mut marked);
        // Inner spaces stay plain; tabs and trailing spaces are marked.
        let marks: Vec<_> = spans
            .iter()
            .filter(|span| span.whitespace)
            .map(|span| span.text.as_str())
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
        assert_eq!(app.view(view).unwrap().viewport.horizontal_column, 5);
        let frame = super::frame(
            &app,
            app.active_view().unwrap(),
            &mut Highlighter::default(),
            0,
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
        assert_eq!(app.view(view).unwrap().viewport.horizontal_column, 1);
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
            10,
            4,
            &Overlay::default(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(app.view(view).unwrap().viewport, before);
        assert!(projected.cursor.is_none());
        assert!(
            super::follow_caret(&app, app.active_view().unwrap(), 10, 4)
                .unwrap()
                .is_some()
        );
    }
    #[test]
    fn wrapped_lines_break_after_spaces_and_inside_long_words() {
        let tab = NonZeroUsize::new(4).unwrap();
        let rows = |text: &str, width| -> Vec<_> {
            super::segments(text, Some(width), tab)
                .into_iter()
                .map(|s| (s.start, s.columns))
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
    fn lines_too_long_to_wrap_turn_wrapping_off_while_near() {
        let long = "x ".repeat(super::WRAP_LIMIT);
        let mut near = app(
            &format!("short words here\n{long}\nend"),
            Language::PlainText,
        );
        near.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        // The long line is on screen: every line takes one row, as unwrapped.
        let shown = frame(&mut near, 10, 5).unwrap();
        let lines: Vec<_> = shown
            .rows
            .iter()
            .map(|row| (row.line, row.continued))
            .collect();
        assert_eq!(lines, [(0, false), (1, false), (2, false)]);
        // Far from it, lines wrap again.
        let text = format!(
            "{long}\n{}short words here",
            "\n".repeat(2 * super::WRAP_REACH)
        );
        let mut far = app(&text, Language::PlainText);
        far.dispatch(Event::SetOption {
            scope: crate::options::Scope::Global,
            name: "wrap",
            value: crate::options::Value::Bool(true),
        })
        .unwrap();
        let view = far.active_view().unwrap();
        far.dispatch(Event::Edit {
            view,
            command: Command::SetSelection(Selection::caret(text.len())),
            time: Duration::ZERO,
        })
        .unwrap();
        frame(&mut far, 10, 5).unwrap();
        let shown = frame(&mut far, 10, 5).unwrap();
        assert!(shown.rows.iter().any(|row| row.continued));
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
        assert_eq!(super::offset_at(&app, 10, 1, 0), Some(8));
        assert_eq!(super::offset_at(&app, 10, 0, 9), Some(7));
        assert_eq!(super::offset_at(&app, 10, 2, 2), Some(21));
        assert_eq!(super::cell_of(&app, view, 10, 5, 21), Some((2, 2)));
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
        let (viewport, reveal) = super::scroll(&app, view, -1, 10, 2).unwrap();
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
        assert_eq!(super::offset_at(&app, 80, 0, 3), Some(1));
        assert_eq!(super::offset_at(&app, 80, 0, 40), Some(3));
        assert_eq!(super::offset_at(&app, 80, 1, 1), Some(5));
        assert_eq!(super::offset_at(&app, 80, -1, 0), Some(0));
        assert_eq!(super::offset_at(&app, 80, 9, 0), Some(13));
        let (viewport, reveal) = super::scroll(&app, app.active_view().unwrap(), 3, 80, 2).unwrap();
        assert_eq!(viewport.anchor, ByteOffset(10));
        assert_eq!(reveal, Some(10));
        // The last line can scroll to the top and no further.
        let (viewport, _) = super::scroll(&app, app.active_view().unwrap(), 30, 80, 2).unwrap();
        assert_eq!(viewport.anchor, ByteOffset(13));
        assert_eq!(
            super::scroll(&app, app.active_view().unwrap(), -1, 80, 2)
                .unwrap()
                .1,
            None
        );
    }
}
