//! Resizing the active window a step at a time, after kitty's resize mode:
//! `w`ider, `n`arrower, `t`aller, `s`horter and `r`eset, Ctrl doubling the
//! step, until Esc. The message line shows the size the window had when the
//! mode began and the size it has now.
use super::{Key, KeyStroke, Presentation, Response, session::Transition};
use crate::application::{Application, Axis, Event, Update};

/// Cells per step; a cell is about twice as tall as it is wide.
const ROWS: i32 = 1;
const COLUMNS: i32 = 2;

pub struct ResizeSession {
    /// Rows and columns when the mode began, then now.
    original: (u16, u16),
    current: (u16, u16),
}
fn size(app: &Application) -> Option<(u16, u16)> {
    let area = app.window_area(app.active_view()?)?;
    Some((area.height, area.width))
}
impl ResizeSession {
    pub(super) fn new(app: &Application) -> Option<Self> {
        let size = size(app)?;
        Some(Self {
            original: size,
            current: size,
        })
    }
    pub(super) fn key(&mut self, key: KeyStroke) -> Transition {
        let step = if key.control { 2 } else { 1 };
        let event = match key.code {
            Key::Esc | Key::Enter | Key::Char('q') => return Transition::close(),
            Key::Char('g') if key.control => return Transition::close(),
            Key::Char(ch) => match ch.to_ascii_lowercase() {
                'w' => resize(Axis::Columns, COLUMNS * step),
                'n' => resize(Axis::Columns, -COLUMNS * step),
                't' => resize(Axis::Rows, ROWS * step),
                's' => resize(Axis::Rows, -ROWS * step),
                'r' => Event::ResetWindowSizes,
                _ => return Transition::Blocked,
            },
            _ => return Transition::Blocked,
        };
        Transition::active(Response {
            events: vec![event],
            redraw: true,
            ..Response::default()
        })
    }
    /// Another window or a closed one ends the mode.
    pub(super) fn observe(&mut self, app: &Application, update: &Update) -> Transition {
        match size(app) {
            Some(size) if !update.active_changed => {
                self.current = size;
                Transition::active(Response::default())
            }
            _ => Transition::close(),
        }
    }
    pub(super) fn presentation(&self) -> Presentation {
        let ((rows, columns), (was_rows, was_columns)) = (self.current, self.original);
        let text = format!(
            "resize: w wider · n narrower · t taller · s shorter · r reset · \
             Ctrl doubles · Esc quits — {rows} rows {columns} cols \
             (was {was_rows} rows {was_columns} cols)"
        );
        Presentation {
            cursor: None,
            selection: 0..0,
            text,
        }
    }
}
fn resize(axis: Axis, delta: i32) -> Event {
    Event::ResizeWindow { axis, delta }
}
