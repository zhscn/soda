//! Resolves mouse events against the current screen areas: the tab row
//! switches documents, a click in a window focuses it and places the
//! caret, a drag selects, and the wheel scrolls the window under it.
use super::{layout, view};
use crate::{
    interaction::{Pointer, UserInput},
    runtime::Runtime,
};
use crossterm::event::{MouseButton, MouseEvent, MouseEventKind};

#[derive(Default)]
pub(super) struct Mouse {
    /// Where the left button went down in the text, while it is held.
    press: Option<usize>,
}
impl Mouse {
    pub fn handle(&mut self, event: MouseEvent, runtime: &mut Runtime, areas: &view::Areas) {
        let inside = |area: ratatui::layout::Rect| {
            area.contains(ratatui::layout::Position::new(event.column, event.row))
        };
        // Offsets in the active window; cells left of the text, in the
        // gutter, select from the line start.
        let offset = |runtime: &Runtime| {
            let text = areas.text(runtime);
            let row = event.row as isize - text.y as isize;
            let column = event.column.saturating_sub(text.x);
            layout::offset_at(runtime.app(), row, column.into())
        };
        let window = areas.window_at(event.column, event.row);
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
                    return;
                }
                let Some(window) = window.filter(|_| runtime.layer().is_none()) else {
                    return;
                };
                if runtime.app().active_view() != Some(window.view) {
                    runtime.input(UserInput::Pointer(Pointer::Window(window.view)));
                }
                if window.header.is_some_and(inside) {
                    return;
                }
                if let Some(offset) = offset(runtime) {
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
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown if runtime.layer().is_none() => {
                let Some(window) = window else {
                    return;
                };
                let document = runtime.app().view(window.view).map(|view| view.document_id);
                let step = runtime.app().options().int(document, "scroll-lines") as isize;
                let lines = if event.kind == MouseEventKind::ScrollUp {
                    -step
                } else {
                    step
                };
                let active = runtime.app().active_view() == Some(window.view);
                let caret = runtime.editor_caret().filter(|_| active);
                let Some((viewport, reveal)) =
                    layout::scroll(runtime.app(), window.view, lines, window.text.height, caret)
                else {
                    return;
                };
                runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_column);
                // Other windows keep their carets; focusing one later
                // scrolls back to its caret.
                if let Some(offset) = reveal.filter(|_| active) {
                    runtime.input(UserInput::Pointer(Pointer::Reveal(offset)));
                }
            }
            _ => {}
        }
    }
}
