use crate::{
    application::{Application, ViewId},
    core::{
        ByteOffset, LogicalColumn, column_width, logical_column_at, offset_at_logical_column,
        step_grapheme,
    },
    syntax::{Category, Highlighter},
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
}
/// One visible document line: its zero-based number and clipped text.
pub(super) struct Row {
    pub line: usize,
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
        matches: &[],
        detail: text.len(),
        categories: &[],
        whitespace: false,
    };
    styled_row(text, byte_start, marks, left, width, tab)
}
/// Byte ranges styled within a row: the selection is document-relative;
/// matches, the detail offset and highlight categories are relative to the
/// row text, categories ordered and disjoint.
struct Marks<'a> {
    selection: std::ops::Range<usize>,
    matches: &'a [std::ops::Range<usize>],
    detail: usize,
    categories: &'a [(std::ops::Range<usize>, Category)],
    /// Mark tabs and trailing spaces.
    whitespace: bool,
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
        matches,
        detail,
        categories,
        whitespace,
    } = marks;
    // Spaces and tabs from here to the end of the line trail.
    let trailing = text.trim_end_matches(['\n', '\r']);
    let trailing = trailing.trim_end_matches([' ', '\t']).len();
    let mut spans = Vec::<Span>::new();
    let mut next_category = 0;
    let mut column = 0;
    let right = left.saturating_add(width);
    for (offset, cluster) in text.grapheme_indices(true) {
        let end = column_width(cluster, column, tab);
        let cells = end - column;
        if column >= right {
            break;
        }
        if end > left && cells > 0 {
            let visible = end.min(right).saturating_sub(column.max(left));
            let marked = whitespace && (cluster == "\t" || (cluster == " " && offset >= trailing));
            let rendered = if marked && column >= left {
                let mark = if cluster == "\t" { "»" } else { "·" };
                format!("{mark}{}", " ".repeat(visible - 1))
            } else if cluster == "\t" || column < left || end > right {
                " ".repeat(visible)
            } else if cluster.chars().any(char::is_control) {
                "�".into()
            } else {
                cluster.into()
            };
            let selected = !selection.is_empty()
                && byte_start + offset < selection.end
                && byte_start + offset + cluster.len() > selection.start;
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
            if let Some(last) = spans.last_mut().filter(|last| {
                last.selected == selected
                    && last.matched == matched
                    && last.detail == secondary
                    && last.category == category
                    && last.whitespace == marked
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
                });
            }
        }
        column = end;
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
        matches: &row.highlights,
        detail: detail.unwrap_or(text.len()),
        categories: &[],
        whitespace: false,
    };
    styled_row(text, 0, marks, 0, width, NonZeroUsize::new(4).unwrap())
}
pub(super) fn plain(text: &str, left: usize, width: usize) -> String {
    row(text, 0, 0..0, left, width, NonZeroUsize::new(4).unwrap())
        .into_iter()
        .map(|span| span.text)
        .collect()
}

/// Scroll only the active view. Byte anchors remain application-owned and map
/// through document updates; this frontend resolves them into logical lines.
pub(super) fn follow_caret(
    app: &Application,
    id: ViewId,
    width: u16,
    rows: u16,
    caret: Option<usize>,
) -> Result<Option<ViewportAdjustment>, crate::application::Error> {
    let view = app.view(id).unwrap();
    let document = app
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .document();
    let state = app
        .workspace()
        .editor(view.document_id)
        .unwrap()
        .model()
        .session(view.session_id)
        .unwrap()
        .state();
    let snapshot = document.snapshot();
    let tab = document.whitespace().tab_width;
    let head = caret.unwrap_or(state.selection().head);
    let line = snapshot.line_of(head).unwrap();
    let column = logical_column_at(snapshot, ByteOffset(head), tab)?.0;
    let rows = usize::from(rows);
    let mut top = snapshot.line_of(view.viewport.anchor.offset.0).unwrap();
    let mut left = view.viewport.horizontal_column;
    if rows > 0 {
        if line < top {
            top = line;
        } else if line >= top.saturating_add(rows) {
            top = line + 1 - rows;
        }
    }
    if width > 0 {
        if column < left {
            left = column;
        }
        let next = step_grapheme(snapshot, ByteOffset(head), true)?;
        let cluster = snapshot.byte_slice(head..next.0).unwrap().to_string();
        let caret_cells = (column_width(&cluster, column, tab) - column)
            .max(1)
            .min(usize::from(width));
        let caret_end = column.saturating_add(caret_cells);
        if caret_end > left.saturating_add(usize::from(width)) {
            left = caret_end - usize::from(width);
        }
    }
    let anchor = ByteOffset(snapshot.line_start(top).unwrap());
    Ok(
        (anchor != view.viewport.anchor.offset || left != view.viewport.horizontal_column)
            .then_some(ViewportAdjustment {
                view: id,
                anchor,
                horizontal_column: left,
            }),
    )
}

/// The byte offset under a cell of the active view's text area. Rows past
/// either edge resolve to the lines beyond it, within the document.
/// The row and column, within a view's text area, that shows `offset`;
/// none when it is scrolled out above, below or to the left.
pub(super) fn cell_of(app: &Application, view: ViewId, offset: usize) -> Option<(usize, usize)> {
    let view = app.view(view)?;
    let document = app.workspace().editor(view.document_id)?.model().document();
    let snapshot = document.snapshot();
    let top = snapshot.line_of(view.viewport.anchor.offset.0)?;
    let row = snapshot.line_of(offset)?.checked_sub(top)?;
    let column = logical_column_at(
        snapshot,
        ByteOffset(offset),
        document.whitespace().tab_width,
    )
    .ok()?
    .0
    .checked_sub(view.viewport.horizontal_column)?;
    Some((row, column))
}
pub(super) fn offset_at(app: &Application, row: isize, column: usize) -> Option<usize> {
    let view = app.view(app.active_view()?)?;
    let document = app.workspace().editor(view.document_id)?.model().document();
    let snapshot = document.snapshot();
    let top = snapshot.line_of(view.viewport.anchor.offset.0)?;
    let line = top
        .saturating_add_signed(row)
        .min(snapshot.line_count() - 1);
    let column = LogicalColumn(view.viewport.horizontal_column + column);
    offset_at_logical_column(snapshot, line, column, document.whitespace().tab_width)
        .ok()
        .map(|offset| offset.0)
}
/// Scrolls the active view by `lines`, keeping the last line reachable at
/// the top. When the caret leaves the text area, the second value is where
/// it comes back: the nearest visible line, at the same column.
pub(super) fn scroll(
    app: &Application,
    id: ViewId,
    lines: isize,
    rows: u16,
    caret: Option<usize>,
) -> Option<(ViewportAdjustment, Option<usize>)> {
    let view = app.view(id)?;
    let editor = app.workspace().editor(view.document_id)?;
    let document = editor.model().document();
    let snapshot = document.snapshot();
    let tab = document.whitespace().tab_width;
    let top = snapshot.line_of(view.viewport.anchor.offset.0)?;
    let top = top
        .saturating_add_signed(lines)
        .min(snapshot.line_count() - 1);
    let head = caret.unwrap_or(editor.model().session(view.session_id)?.selection().head);
    let line = snapshot.line_of(head)?;
    let bottom = top + usize::from(rows.max(1)) - 1;
    let reveal = (line < top || line > bottom).then(|| {
        let column = logical_column_at(snapshot, ByteOffset(head), tab).unwrap();
        offset_at_logical_column(snapshot, line.clamp(top, bottom), column, tab)
            .unwrap()
            .0
    });
    Some((
        ViewportAdjustment {
            view: id,
            anchor: ByteOffset(snapshot.line_start(top)?),
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
    caret: Option<usize>,
) -> Result<Option<Frame>, crate::application::Error> {
    let Some(view) = app.view(id) else {
        return Ok(None);
    };
    let editor = app.workspace().editor(view.document_id).unwrap();
    let document = editor.model().document();
    let state = editor.model().session(view.session_id).unwrap().state();
    let snapshot = document.snapshot();
    let head = caret.unwrap_or(state.selection().head);
    let line = snapshot.line_of(head).unwrap();
    let tab = document.whitespace().tab_width;
    let column = logical_column_at(snapshot, ByteOffset(head), tab)?.0;
    let rows = usize::from(rows);
    let top = snapshot.line_of(view.viewport.anchor.offset.0).unwrap();
    let left = view.viewport.horizontal_column;
    let mut output = Vec::new();
    let bottom = top.saturating_add(rows).min(snapshot.line_count());
    let highlights = highlighter.lines(app, view.document_id, top..bottom);
    let options = app.options();
    let show_whitespace = options.bool(Some(view.document_id), "show-whitespace");
    // The ruler marks the first column past the limit, as Vim's colorcolumn.
    let ruler = match options.int(Some(view.document_id), "ruler") as usize {
        0 => None,
        limit => limit
            .checked_sub(left)
            .filter(|column| *column < usize::from(width))
            .map(|column| column as u16),
    };
    for number in top..bottom {
        let text = snapshot.line(number).unwrap();
        let marks = Marks {
            selection: state.selection().range(),
            matches: &[],
            detail: text.len(),
            categories: highlights.get(number - top).map_or(&[], Vec::as_slice),
            whitespace: show_whitespace,
        };
        output.push(Row {
            line: number,
            spans: styled_row(
                &text,
                snapshot.line_start(number).unwrap(),
                marks,
                left,
                usize::from(width),
                tab,
            ),
        });
    }
    let cursor = if rows > 0
        && width > 0
        && line >= top
        && line - top < rows
        && column >= left
        && column - left < usize::from(width)
    {
        Some(((column - left) as u16, (line - top) as u16))
    } else {
        None
    };
    Ok(Some(Frame {
        rows: output,
        cursor,
        caret: (line, column),
        line_count: snapshot.line_count(),
        language: highlighter
            .language(view.document_id)
            .unwrap_or("text")
            .to_owned(),
        ruler,
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
        if let Some(viewport) =
            super::follow_caret(app, app.active_view().unwrap(), width, height, None)?
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
            None,
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
    fn joined(spans: Vec<Span>) -> String {
        spans.into_iter().map(|span| span.text).collect()
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
            None,
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
            None,
        )
        .unwrap()
        .unwrap();
        assert_eq!(app.view(view).unwrap().viewport, before);
        assert!(projected.cursor.is_none());
        assert!(
            super::follow_caret(&app, app.active_view().unwrap(), 10, 4, None)
                .unwrap()
                .is_some()
        );
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
        assert_eq!(super::offset_at(&app, 0, 3), Some(1));
        assert_eq!(super::offset_at(&app, 0, 40), Some(3));
        assert_eq!(super::offset_at(&app, 1, 1), Some(5));
        assert_eq!(super::offset_at(&app, -1, 0), Some(0));
        assert_eq!(super::offset_at(&app, 9, 0), Some(13));
        let (viewport, reveal) =
            super::scroll(&app, app.active_view().unwrap(), 3, 2, None).unwrap();
        assert_eq!(viewport.anchor, ByteOffset(10));
        assert_eq!(reveal, Some(10));
        // The last line can scroll to the top and no further.
        let (viewport, _) = super::scroll(&app, app.active_view().unwrap(), 30, 2, None).unwrap();
        assert_eq!(viewport.anchor, ByteOffset(13));
        assert_eq!(
            super::scroll(&app, app.active_view().unwrap(), -1, 2, None)
                .unwrap()
                .1,
            None
        );
    }
}
