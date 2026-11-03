//! Resolves mouse events against the current screen areas: the tab row
//! switches documents, a click in a window focuses it and places the
//! caret, a drag selects, and the wheel scrolls an open popup, else the
//! window under it. Dragging the column between side-by-side windows, or
//! the title row of a window below another, moves that edge.
use super::view;
use crate::{
    application::{Axis, ViewId},
    interaction::{Pointer, UserInput},
    runtime::Runtime,
    screen::{self, Cells},
};

use crossterm::event::{MouseButton, MouseEvent, MouseEventKind};

#[derive(Default)]
pub(super) struct Mouse {
    /// Where the left button went down in the text, while it is held.
    press: Option<usize>,
    /// The window whose right or bottom edge is being dragged.
    edge: Option<(ViewId, Axis)>,
}
/// The window whose right or bottom edge is at a cell: the column between
/// it and a window to its right, or the title row of a window below it.
fn edge_at(areas: &view::Areas, x: u16, y: u16) -> Option<(ViewId, Axis)> {
    let within = |from: u16, size: u16, at: u16| from <= at && at < from + size;
    match areas.window_at(x, y) {
        None => areas
            .windows
            .iter()
            .find(|w| w.area.x + w.area.width == x && within(w.area.y, w.area.height, y))
            .map(|w| (w.view, Axis::Columns)),
        Some(below) if below.header.is_some_and(|header| header.y == y) => areas
            .windows
            .iter()
            .find(|w| w.area.y + w.area.height == below.area.y && within(w.area.x, w.area.width, x))
            .map(|w| (w.view, Axis::Rows)),
        Some(_) => None,
    }
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
            screen::offset_at(runtime.app(), &Cells, text.width.into(), row, column.into())
        };
        let window = areas.window_at(event.column, event.row);
        match event.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                self.press = None;
                self.edge =
                    edge_at(areas, event.column, event.row).filter(|_| runtime.layer().is_none());
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
            MouseEventKind::Drag(MouseButton::Left) if self.edge.is_some() => {
                let (view, axis) = self.edge.unwrap();
                let Some(area) = runtime.app().window_area(view) else {
                    return;
                };
                // The edge as laid out now, in screen cells.
                let delta = match axis {
                    Axis::Columns => {
                        i32::from(event.column) - i32::from(areas.editor.x + area.x + area.width)
                    }
                    Axis::Rows => {
                        i32::from(event.row) - i32::from(areas.editor.y + area.y + area.height)
                    }
                };
                if delta != 0 {
                    runtime.input(UserInput::Pointer(Pointer::Edge { view, axis, delta }));
                }
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                let Some(anchor) = self.press else {
                    return;
                };
                // Rows above or below the text extend past its edges, and
                // the view follows the head.
                if let Some(head) = offset(runtime)
                    && head != anchor
                {
                    runtime.input(UserInput::Pointer(Pointer::Drag { anchor, head }));
                }
            }
            MouseEventKind::Up(_) => {
                self.press = None;
                self.edge = None;
            }
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown
                if runtime.layer().is_none() && runtime.popup().is_some() =>
            {
                let lines = if event.kind == MouseEventKind::ScrollUp {
                    -3
                } else {
                    3
                };
                runtime.scroll_popup(lines);
            }
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
                let Some((viewport, reveal)) = screen::scroll(
                    runtime.app(),
                    window.view,
                    &Cells,
                    lines,
                    window.text.width.into(),
                    window.text.height,
                ) else {
                    return;
                };
                runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_scroll);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interaction::{Command, KeyStroke};
    use crossterm::event::KeyModifiers;

    fn event(kind: MouseEventKind, column: u16, row: u16) -> MouseEvent {
        MouseEvent {
            kind,
            column,
            row,
            modifiers: KeyModifiers::NONE,
        }
    }
    fn drag(runtime: &mut Runtime, from: (u16, u16), to: &[(u16, u16)]) {
        let mut mouse = Mouse::default();
        let areas = |runtime: &mut Runtime| {
            let areas = view::Areas::new(runtime, 81, 24);
            runtime.set_editing_area(areas.editor.width, areas.editor.height);
            areas
        };
        let a = areas(runtime);
        mouse.handle(
            event(MouseEventKind::Down(MouseButton::Left), from.0, from.1),
            runtime,
            &a,
        );
        for &(column, row) in to {
            let a = areas(runtime);
            mouse.handle(
                event(MouseEventKind::Drag(MouseButton::Left), column, row),
                runtime,
                &a,
            );
        }
        let a = areas(runtime);
        mouse.handle(
            event(MouseEventKind::Up(MouseButton::Left), 0, 0),
            runtime,
            &a,
        );
    }
    #[test]
    fn dragging_a_separator_or_a_title_moves_that_edge() {
        let mut runtime = Runtime::new(std::path::PathBuf::from("/")).unwrap();
        runtime.start(None);
        for key in KeyStroke::parse_sequence("C-x 3 C-x 2").unwrap() {
            runtime.input(UserInput::Key(key));
        }
        let views = runtime.app().windows().views();
        let (left, upper, lower) = (views[0], views[1], views[2]);
        let areas = view::Areas::new(&runtime, 81, 24);
        runtime.set_editing_area(areas.editor.width, areas.editor.height);
        let size = |runtime: &Runtime, view| {
            let area = runtime.app().window_area(view).unwrap();
            (area.width, area.height)
        };
        assert_eq!(size(&runtime, left), (40, 22));
        // The separator is column 40; dragging it follows the pointer.
        drag(&mut runtime, (40, 5), &[(35, 5), (30, 6)]);
        assert_eq!(size(&runtime, left).0, 30);
        assert_eq!(size(&runtime, upper).0, 50);
        // The lower right window's title is row 11, the upper one's edge.
        assert_eq!(size(&runtime, upper).1, 11);
        drag(&mut runtime, (60, 11), &[(60, 16)]);
        assert_eq!((size(&runtime, upper).1, size(&runtime, lower).1), (16, 6));
        // A drag inside the text selects as before and resizes nothing.
        drag(&mut runtime, (60, 3), &[(70, 3)]);
        assert_eq!(size(&runtime, upper).1, 16);
        runtime.command(Command::Named("resize-window reset".into()));
        assert_eq!(size(&runtime, left).0, 40);
    }
}
