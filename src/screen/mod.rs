//! What a frontend shows, independent of the platform that shows it. The
//! screen is a grid of cells: `Presenter` lays it out from Runtime state,
//! reports the geometry back for paging and viewport following, draws each
//! frame into a cell buffer, and resolves mouse events against the same
//! layout. A frontend supplies the size, input and the buffer's output; the
//! terminal frontend copies the buffer to the terminal, a graphical one
//! would draw its cells with a font.
//!
//! Colors in the buffer are 24-bit, except `Reset`, which stands for the
//! frontend's own foreground or background.
mod highlight;
mod layout;
mod mouse;
mod results;
mod theme;
mod view;

pub use mouse::{MouseEvent, MouseKind};
pub use ratatui::{buffer::Buffer, layout::Rect};

use crate::{interaction::EditMode, runtime::Runtime};
use highlight::Highlighter;
use std::time::Duration;

/// How the caret shows: a block over a character in Normal and Beacon, a
/// bar between characters where text is typed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CursorShape {
    Block,
    Bar,
}
/// The caret of a drawn frame: where it is, if anywhere, and its shape.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Cursor {
    pub position: Option<(u16, u16)>,
    pub shape: CursorShape,
}

/// Rows the layout reported to Runtime last.
#[derive(PartialEq)]
struct Geometry {
    editor: u16,
    list: usize,
    page: u16,
    windows: Vec<(crate::application::ViewId, usize)>,
}

/// Presentation state of one screen: highlighting caches, the theme and
/// mouse gestures in progress.
pub struct Presenter {
    highlighter: Highlighter,
    theme: theme::Theme,
    theme_key: Option<(String, u64)>,
    /// What `theme auto` picks.
    light: bool,
    mouse: mouse::Mouse,
    geometry: Option<Geometry>,
}
impl Presenter {
    /// `light` tells whether the frontend's background is light, for the
    /// `auto` theme.
    pub fn new(light: bool) -> Self {
        Self {
            // Highlighting a frame scans for at most this long, so a jump
            // deep into a large file stays responsive while it catches up.
            highlighter: Highlighter::with_budget(Duration::from_millis(12)),
            theme: theme::Theme::build("auto", &Default::default(), light),
            theme_key: None,
            light,
            mouse: mouse::Mouse::default(),
            geometry: None,
        }
    }
    /// Tells Runtime the rows a screen of this size gives the editing
    /// area, the windows and the command line's candidates, which paging,
    /// side windows and display rules use. Call it before handling input
    /// and before drawing.
    pub fn measure(&mut self, runtime: &mut Runtime, width: u16, height: u16) {
        let areas = view::Areas::new(runtime, width, height);
        runtime.set_editing_area(areas.editor.width, areas.editor.height);
        let geometry = Geometry {
            editor: areas.editor.height,
            list: areas.list_rows(),
            page: areas.text(runtime).height,
            windows: areas
                .windows
                .iter()
                .map(|window| (window.view, usize::from(window.text.height)))
                .collect(),
        };
        if self.geometry.as_ref() != Some(&geometry) {
            runtime.resize(geometry.editor.into(), geometry.list);
            runtime.set_page_rows(geometry.page.into());
            runtime.set_window_rows(geometry.windows.clone());
            self.geometry = Some(geometry);
        }
    }
    /// Scrolls the active window to its caret and brings the theme and
    /// highlighting caches up to date. Call it before `render`.
    pub fn prepare(
        &mut self,
        runtime: &mut Runtime,
        width: u16,
        height: u16,
    ) -> Result<(), crate::application::Error> {
        let areas = view::Areas::new(runtime, width, height);
        if let Some(window) = areas.active(runtime)
            && let Some(viewport) = layout::follow_caret(
                runtime.app(),
                window.view,
                window.text.width,
                window.text.height,
            )?
        {
            runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_column);
        }
        self.highlighter.retain(runtime.app());
        let app = runtime.app();
        let key = (
            app.options().choice(None, "theme").to_owned(),
            app.faces().revision(),
        );
        if self.theme_key.as_ref() != Some(&key) {
            self.theme = theme::Theme::build(&key.0, app.faces(), self.light);
            self.theme_key = Some(key);
        }
        Ok(())
    }
    /// Draws a frame over the whole of `buffer`, whose area is the screen.
    pub fn render(
        &mut self,
        runtime: &Runtime,
        buffer: &mut Buffer,
    ) -> Result<Cursor, crate::application::Error> {
        let area = buffer.area;
        // The gutter widens with the line count, so measure again.
        let areas = view::Areas::new(runtime, area.width, area.height);
        let texts = view::frames(runtime, &mut self.highlighter, &areas)?;
        let position = view::render(buffer, runtime, &self.theme, &areas, &texts);
        let shape = if runtime.layer().is_none() && runtime.edit_mode() != EditMode::Insert {
            CursorShape::Block
        } else {
            CursorShape::Bar
        };
        Ok(Cursor { position, shape })
    }
    /// Whether the last frame left lines unhighlighted; draw again soon.
    pub fn take_pending(&mut self) -> bool {
        self.highlighter.take_pending()
    }
    /// Acts on a mouse event at a cell of a screen of this size.
    pub fn mouse(&mut self, runtime: &mut Runtime, event: MouseEvent, width: u16, height: u16) {
        let areas = view::Areas::new(runtime, width, height);
        self.mouse.handle(event, runtime, &areas);
    }
}
