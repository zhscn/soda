//! What a frontend shows, independent of how it draws: the layout of each
//! window's text, its highlighting, the theme, and what the parts around
//! the text say. Rows of text are lines of one height; across a row, text
//! is measured by the frontend (`Measure`), in terminal cells or in pixels,
//! and laid out by the same rules either way: tab stops, wrapping, inlay
//! hints, sideways scrolling, the caret and the way back from a place on
//! screen to an offset.
//!
//! A frontend arranges the screen itself, in its own units: the windows of
//! Application's window tree, gutters, tab bar, status line and panels.
//! The terminal frontend draws all of it in cells (`tui`).
pub(crate) mod content;
mod highlight;
mod layout;
mod results;
mod theme;

pub(crate) use highlight::Highlighter;
pub use layout::{Cells, Font, Measure};
pub(crate) use layout::{
    Frame as TextFrame, Overlay, Span, candidate_row, offset_at, padded, plain, position_of,
    prompt_row, scroll, wrap,
};
pub(crate) use theme::Theme;

use crate::{application::ViewId, runtime::Runtime};

/// The text of a view in an area `width` across and `rows` down. The
/// active view also shows Beacon's other selections, the digits that
/// extend the selection, and the rest of the selected completion.
pub(crate) fn text(
    runtime: &Runtime,
    view: ViewId,
    highlighter: &mut Highlighter,
    measure: &dyn Measure,
    width: usize,
    rows: u16,
) -> Result<Option<TextFrame>, crate::application::Error> {
    let overlay = if runtime.app().active_view() == Some(view) {
        Overlay {
            beacons: runtime.beacons(),
            digits: runtime.expand_hints(),
            preview: runtime
                .completion_popup()
                .and_then(|popup| popup.preview)
                .filter(|_| {
                    let document = runtime.app().view(view).map(|v| v.document_id);
                    runtime.app().options().bool(document, "completion-preview")
                }),
        }
    } else {
        Overlay::default()
    };
    layout::frame(
        runtime.app(),
        view,
        highlighter,
        measure,
        width,
        rows,
        &overlay,
    )
}
/// Scrolls a view so that its caret shows in an area `width` across and
/// `rows` down.
pub(crate) fn follow(
    runtime: &mut Runtime,
    view: ViewId,
    measure: &dyn Measure,
    width: usize,
    rows: u16,
) -> Result<(), crate::application::Error> {
    if let Some(viewport) = layout::follow_caret(runtime.app(), view, measure, width, rows)? {
        runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_scroll);
    }
    Ok(())
}
