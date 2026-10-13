use crate::{
    application::{Application, Event},
    core::{ByteOffset, column_width, logical_column_at, step_grapheme},
};
use std::num::NonZeroUsize;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug)]
pub(super) struct Span {
    pub text: String,
    pub selected: bool,
}
pub(super) struct Frame {
    pub rows: Vec<Vec<Span>>,
    pub cursor: Option<(u16, u16)>,
    pub status: String,
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
    let mut spans = Vec::<Span>::new();
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
            let rendered = if cluster == "\t" || column < left || end > right {
                " ".repeat(visible)
            } else if cluster.chars().any(char::is_control) {
                "�".into()
            } else {
                cluster.into()
            };
            let selected = !selection.is_empty()
                && byte_start + offset < selection.end
                && byte_start + offset + cluster.len() > selection.start;
            if let Some(last) = spans.last_mut().filter(|last| last.selected == selected) {
                last.text.push_str(&rendered);
            } else {
                spans.push(Span {
                    text: rendered,
                    selected,
                });
            }
        }
        column = end;
    }
    spans
}
pub(super) fn plain(text: &str, left: usize, width: usize) -> String {
    row(text, 0, 0..0, left, width, NonZeroUsize::new(4).unwrap())
        .into_iter()
        .map(|span| span.text)
        .collect()
}

/// Scroll only the active view. Byte anchors remain application-owned and map
/// through document updates; this frontend resolves them into logical lines.
pub(super) fn frame(
    app: &mut Application,
    width: u16,
    height: u16,
) -> Result<Frame, crate::application::Error> {
    let Some(id) = app.active_view() else {
        return Ok(Frame {
            rows: Vec::new(),
            cursor: None,
            status: "Soda — ^N New buffer  ^O Open  ^Q Quit".into(),
        });
    };
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
    let head = state.selection().head;
    let line = snapshot.line_of(head).unwrap();
    let column = logical_column_at(snapshot, ByteOffset(head), tab)?.0;
    let rows = usize::from(height.saturating_sub(2));
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
    if anchor != view.viewport.anchor.offset || left != view.viewport.horizontal_column {
        app.dispatch(Event::SetViewport {
            view: id,
            anchor,
            horizontal_column: left,
        })?;
    }
    let view = app.view(id).unwrap();
    let editor = app.workspace().editor(view.document_id).unwrap();
    let document = editor.model().document();
    let state = editor.model().session(view.session_id).unwrap().state();
    let snapshot = document.snapshot();
    let mut output = Vec::new();
    for line in top..top.saturating_add(rows).min(snapshot.line_count()) {
        let text = snapshot.line(line).unwrap();
        output.push(row(
            &text,
            snapshot.line_start(line).unwrap(),
            state.selection().range(),
            left,
            usize::from(width),
            tab,
        ));
    }
    let path = document
        .file()
        .path()
        .map_or_else(|| "[untitled]".into(), |p| p.display().to_string());
    let status = format!(
        "{}{}{}  {}:{}  ^O Open  ^S Save  ^Q Quit",
        path,
        if document.is_dirty() { " *" } else { "" },
        if app.workspace().is_saving(view.document_id) {
            " [saving]"
        } else {
            ""
        },
        line + 1,
        column + 1
    );
    let cursor = if rows > 0 && width > 0 && line >= top && line - top < rows {
        Some(((column - left) as u16, (line - top) as u16))
    } else {
        None
    };
    Ok(Frame {
        rows: output,
        cursor,
        status,
    })
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
        let frame = frame(&mut app, 6, 5).unwrap();
        assert_eq!(frame.cursor, Some((5, 0)));
        assert_eq!(app.view(view).unwrap().viewport.horizontal_column, 5);
        let frame = super::frame(&mut app, 0, 1).unwrap();
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
        let frame = frame(&mut app, 5, 4).unwrap();
        assert_eq!(frame.cursor, Some((3, 0)));
        assert_eq!(app.view(view).unwrap().viewport.horizontal_column, 1);
        assert_eq!(
            frame.rows[0]
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
        assert_eq!(frame(&mut app, 10, 4).unwrap().cursor, Some((1, 1)));
        let anchor = app.view(a).unwrap().viewport.anchor;
        app.dispatch(Event::AddView(document)).unwrap();
        let b = app.active_view().unwrap();
        assert_eq!(frame(&mut app, 10, 4).unwrap().cursor, Some((0, 0)));
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
}
