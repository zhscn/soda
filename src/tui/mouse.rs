//! Resolves mouse events against the current screen areas: the tab row
//! switches documents, the text area places and drags the caret, and the
//! wheel scrolls the active view.
use super::{layout, view};
use crate::{
    interaction::{Pointer, UserInput},
    runtime::Runtime,
};
use crossterm::event::{MouseButton, MouseEvent, MouseEventKind};

/// Lines per wheel step.
const SCROLL: isize = 3;

#[derive(Default)]
pub(super) struct Mouse {
    /// Where the left button went down in the text, while it is held.
    press: Option<usize>,
}
impl Mouse {
    pub fn handle(&mut self, event: MouseEvent, runtime: &mut Runtime, areas: &view::Areas) {
        let text = areas.text();
        let inside = |area: ratatui::layout::Rect| {
            area.contains(ratatui::layout::Position::new(event.column, event.row))
        };
        // Cells left of the text, in the gutter, select from the line start.
        let offset = |runtime: &Runtime| {
            let row = event.row as isize - text.y as isize;
            let column = event.column.saturating_sub(text.x);
            layout::offset_at(runtime.app(), row, column.into())
        };
        match event.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                self.press = None;
                if areas.tabs.is_some_and(inside) {
                    let tab = view::tab_items(runtime, areas.editor.width)
                        .into_iter()
                        .take_while(|(_, x, _)| *x <= event.column)
                        .last();
                    if let Some((document, _, _)) = tab {
                        runtime.input(UserInput::Pointer(Pointer::Document(document)));
                    }
                } else if inside(areas.editor)
                    && runtime.layer().is_none()
                    && let Some(offset) = offset(runtime)
                {
                    self.press = Some(offset);
                    runtime.input(UserInput::Pointer(Pointer::Click(offset)));
                }
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                let Some(anchor) = self.press else {
                    return;
                };
                // Rows above or below the text extend past its edges, and
                // the view follows the head.
                if let Some(head) = offset(runtime)
                    && (head != anchor || runtime.editor_caret().is_some())
                {
                    runtime.input(UserInput::Pointer(Pointer::Drag { anchor, head }));
                }
            }
            MouseEventKind::Up(_) => self.press = None,
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown
                if inside(areas.editor) && runtime.layer().is_none() =>
            {
                let lines = if event.kind == MouseEventKind::ScrollUp {
                    -SCROLL
                } else {
                    SCROLL
                };
                let Some((viewport, reveal)) =
                    layout::scroll(runtime.app(), lines, text.height, runtime.editor_caret())
                else {
                    return;
                };
                runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_column);
                if let Some(offset) = reveal {
                    runtime.input(UserInput::Pointer(Pointer::Reveal(offset)));
                }
            }
            _ => {}
        }
    }
}
