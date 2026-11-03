//! Graphical frontend: a window drawn with wgpu. Text is laid out by
//! `screen` with a measure in fractions of a pixel, on the grid of a
//! monospace font, and the parts around it are arranged in pixels
//! (`paint`). Runtime owns command execution, interaction state and task
//! scheduling, as for the terminal.
mod input;
mod paint;
mod render;
mod text;

use crate::{
    application::ViewId,
    host,
    interaction::{Key, KeyStroke, Pointer, UserInput},
    runtime::Runtime,
    screen::{self, Highlighter, Theme},
};
use paint::{Areas, Painter};
use render::Renderer;
use std::{io, path::PathBuf, sync::Arc, time::Duration};
use text::{Fonts, Measured, UNIT};
use winit::{
    application::ApplicationHandler,
    dpi::{LogicalSize, PhysicalPosition, PhysicalSize},
    event::{ElementState, Ime, MouseButton, MouseScrollDelta, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    keyboard::ModifiersState,
    window::{Window, WindowId},
};

/// How often the loop looks for background results while nothing happens.
const POLL: Duration = Duration::from_millis(30);
/// How long the caret takes to glide to a new place.
const GLIDE: Duration = Duration::from_millis(80);

/// The caret gliding from where it was to where it goes, as IntelliJ's
/// smooth caret movement does: the caret itself moves, with no trail.
#[derive(Default)]
struct Glide {
    from: Option<paint::Rect>,
    to: Option<paint::Rect>,
    start: Option<std::time::Instant>,
    bar: bool,
}
impl Glide {
    /// How far along it is, eased out: fast first, settling at the end.
    fn progress(&self, now: std::time::Instant) -> f32 {
        let t = self.start.map_or(1.0, |start| {
            (now - start).as_secs_f32() / GLIDE.as_secs_f32()
        });
        let t = t.clamp(0.0, 1.0);
        1.0 - (1.0 - t).powi(3)
    }
    fn at(&self, now: std::time::Instant) -> Option<paint::Rect> {
        let (from, to) = (self.from?, self.to?);
        let t = self.progress(now);
        let mix = |a: f32, b: f32| a + (b - a) * t;
        Some(paint::Rect {
            x: mix(from.x, to.x),
            y: mix(from.y, to.y),
            w: mix(from.w, to.w),
            h: mix(from.h, to.h),
        })
    }
    /// Where the caret shows now on its way to `target`, and whether it is
    /// still moving. A new target starts from where the caret shows; a
    /// change of shape, or no gliding, puts it there at once.
    fn place(
        &mut self,
        target: Option<(paint::Rect, bool)>,
        smooth: bool,
        now: std::time::Instant,
    ) -> (Option<paint::Rect>, bool) {
        let Some((target, bar)) = target else {
            *self = Self::default();
            return (None, false);
        };
        if !smooth || bar != self.bar || self.to.is_none() {
            *self = Self {
                from: Some(target),
                to: Some(target),
                start: None,
                bar,
            };
            return (Some(target), false);
        }
        if self.to != Some(target) {
            self.from = self.at(now);
            self.to = Some(target);
            self.start = Some(now);
        }
        (self.at(now), self.progress(now) < 1.0)
    }
}

/// Run the graphical frontend using the shared owner-thread runtime.
pub fn run(path: Option<PathBuf>, config: bool) -> io::Result<()> {
    let event_loop = EventLoop::new().map_err(io::Error::other)?;
    let runtime = host::start(path, config, Box::new(crate::clipboard::Clipboard::local()))?;
    let mut app = App {
        runtime,
        gui: None,
        error: None,
    };
    let outcome = host::guard(|| {
        event_loop.run_app(&mut app).map_err(io::Error::other)?;
        match app.error.take() {
            Some(error) => Err(io::Error::other(error)),
            None => Ok(()),
        }
    });
    host::finish(&mut app.runtime, outcome)
}

/// Draws one frame offscreen and writes it to `out` as a binary PPM image,
/// without a window: for looking at the screen from tests and scripts.
/// `keys` are typed first. Nothing is saved, not even the state.
pub fn snapshot(
    path: Option<PathBuf>,
    config: bool,
    size: (u32, u32),
    scale: f32,
    keys: &str,
    out: &std::path::Path,
) -> io::Result<()> {
    let mut runtime = host::start(
        path,
        config,
        Box::new(crate::clipboard::Clipboard::Internal),
    )?;
    let renderer = Renderer::offscreen(size.0, size.1).map_err(io::Error::other)?;
    let mut gui = Gui::new(renderer, scale);
    let settle = |runtime: &mut Runtime, gui: &mut Gui| {
        for _ in 0..20 {
            runtime.poll();
            gui.measure(runtime);
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    settle(&mut runtime, &mut gui);
    let keys =
        KeyStroke::parse_sequence(keys).map_err(|error| io::Error::other(format!("{error:?}")))?;
    for key in keys {
        runtime.input(UserInput::Key(key));
        gui.measure(&mut runtime);
    }
    settle(&mut runtime, &mut gui);
    // Highlighting and the glyph atlas may take a few frames to settle.
    for _ in 0..10 {
        gui.draw(&mut runtime).map_err(io::Error::other)?;
        if !gui.pending {
            break;
        }
    }
    let pixels = gui
        .renderer
        .read()
        .ok_or_else(|| io::Error::other("nothing drawn"))?;
    let mut image = format!("P6\n{} {}\n255\n", size.0, size.1).into_bytes();
    image.extend(pixels.chunks(4).flat_map(|p| [p[0], p[1], p[2]]));
    std::fs::write(out, image)
}

/// Rows the layout reported to Runtime last.
#[derive(PartialEq)]
struct Geometry {
    cells: (u16, u16),
    list: usize,
    page: u16,
    windows: Vec<(ViewId, usize)>,
}

struct App {
    runtime: Runtime,
    gui: Option<Gui>,
    error: Option<String>,
}
struct Gui {
    renderer: Renderer,
    /// Pixels in a point.
    scale: f32,
    fonts: Fonts,
    highlighter: Highlighter,
    theme: Theme,
    theme_key: Option<(String, u64)>,
    modifiers: ModifiersState,
    pointer: (f32, f32),
    /// Where the left button went down in the text, while it is held.
    press: Option<usize>,
    /// Pixels scrolled that do not make a row yet.
    scrolled: f32,
    /// What an input method is composing.
    preedit: String,
    /// Whether the input method is on: where text is typed.
    ime: bool,
    geometry: Option<Geometry>,
    /// Draw again soon: highlighting or the atlas is catching up, or the
    /// caret is gliding.
    pending: bool,
    caret: Glide,
}

impl App {
    fn window(&self) -> Option<&Arc<Window>> {
        self.gui.as_ref()?.renderer.window()
    }
    fn fail(&mut self, event_loop: &ActiveEventLoop, error: String) {
        self.error = Some(error);
        event_loop.exit();
    }
}

impl Gui {
    fn new(renderer: Renderer, scale: f32) -> Self {
        Self {
            renderer,
            scale,
            fonts: Fonts::new(14.0),
            highlighter: Highlighter::with_budget(Duration::from_millis(12)),
            theme: Theme::build("auto", &Default::default(), false),
            theme_key: None,
            modifiers: ModifiersState::default(),
            pointer: (0.0, 0.0),
            press: None,
            scrolled: 0.0,
            preedit: String::new(),
            ime: false,
            geometry: None,
            pending: false,
            caret: Glide::default(),
        }
    }
    fn redraw(&self) {
        if let Some(window) = self.renderer.window() {
            window.request_redraw();
        }
    }
    /// The text size the options ask for, in pixels.
    fn font_size(&self, runtime: &Runtime) -> f32 {
        let points = runtime.app().options().int(None, "font-size") as f32;
        (points * self.scale).round()
    }
    fn areas(&mut self, runtime: &Runtime) -> Areas {
        let size = self.font_size(runtime);
        self.fonts.resize(size);
        let (width, height) = self.renderer.size();
        Areas::new(runtime, &self.fonts, width as f32, height as f32)
    }
    /// Tells Runtime the rows the screen gives the editing area, the
    /// windows and the command line's candidates.
    fn measure(&mut self, runtime: &mut Runtime) {
        let areas = self.areas(runtime);
        runtime.set_editing_area(areas.cells.0, areas.cells.1);
        let geometry = Geometry {
            cells: areas.cells,
            list: areas.list_rows(),
            page: areas.active(runtime).map_or(areas.cells.1, |w| w.rows),
            windows: areas
                .windows
                .iter()
                .map(|window| (window.view, usize::from(window.rows)))
                .collect(),
        };
        if self.geometry.as_ref() != Some(&geometry) {
            runtime.resize(geometry.cells.1.into(), geometry.list);
            runtime.set_page_rows(geometry.page.into());
            runtime.set_window_rows(geometry.windows.clone());
            self.geometry = Some(geometry);
        }
    }
    fn draw(&mut self, runtime: &mut Runtime) -> Result<(), String> {
        self.measure(runtime);
        let areas = self.areas(runtime);
        if let Some(window) = areas.active(runtime) {
            let (view, width, rows) = (window.view, window.width(), window.rows);
            let measure = Measured::new(&mut self.fonts);
            screen::follow(runtime, view, &measure, width, rows).map_err(|e| e.to_string())?;
        }
        // The gutter widens with the line count, so measure again.
        let areas = self.areas(runtime);
        self.highlighter.retain(runtime.app());
        let app = runtime.app();
        let key = (
            app.options().choice(None, "theme").to_owned(),
            app.faces().revision(),
        );
        if self.theme_key.as_ref() != Some(&key) {
            // A window has no terminal background to follow; `auto` is dark.
            self.theme = Theme::build(&key.0, app.faces(), false);
            self.theme_key = Some(key);
        }
        let mut painter = Painter::new(&mut self.fonts, &mut self.renderer.atlas, &self.theme);
        let caret = paint::screen(
            &mut painter,
            runtime,
            &areas,
            &mut self.highlighter,
            &self.preedit,
        )
        .map_err(|e| e.to_string())?;
        // Text being composed stays put while the caret glides.
        let smooth = runtime.app().options().bool(None, "smooth-caret") && self.preedit.is_empty();
        let (shown, gliding) = self.caret.place(caret, smooth, std::time::Instant::now());
        if let (Some(at), Some((target, bar))) = (shown, caret) {
            // The caret line's band goes along, so the two never part.
            let shift = at.y - target.y;
            for &index in &painter.band {
                painter.out[index].rect[1] += shift;
            }
            // The band's span, or the caret's row without one; the line
            // numbers brighten where it covers them.
            let rows = painter.band.iter().map(|&index| painter.out[index].rect);
            let band = rows.fold(None, |span: Option<(f32, f32)>, rect| {
                let (top, bottom) = (rect[1], rect[1] + rect[3]);
                Some(match span {
                    Some((t, h)) => (t.min(top), (t + h).max(bottom) - t.min(top)),
                    None => (top, bottom - top),
                })
            });
            painter.shade_numbers(band.or(Some((at.y, at.h))));
            paint::cursor(&mut painter, runtime, at, bar);
        } else {
            painter.shade_numbers(None);
        }
        let (background, instances) = (painter.bg, std::mem::take(&mut painter.out));
        self.renderer.draw(background, &instances);
        runtime.take_redraw();
        self.pending = self.highlighter.take_pending() || self.renderer.atlas.cleared || gliding;
        self.renderer.atlas.cleared = false;
        // The input method's candidates open by the caret.
        if let (Some((rect, true)), Some(window)) = (caret, self.renderer.window()) {
            window.set_ime_cursor_area(
                PhysicalPosition::new(rect.x as f64, rect.y as f64),
                PhysicalSize::new(rect.w as f64, rect.h as f64),
            );
        }
        Ok(())
    }
    /// The byte offset under the pointer in the active window's text.
    fn offset(&mut self, runtime: &Runtime, areas: &Areas) -> Option<usize> {
        let window = areas.active(runtime)?;
        let (x, y) = self.pointer;
        let row = ((y - window.text.y) / self.fonts.line).floor() as isize;
        let across = ((x - window.text.x).max(0.0) * UNIT) as usize;
        let width = window.width();
        let measure = Measured::new(&mut self.fonts);
        screen::offset_at(runtime.app(), &measure, width, row, across)
    }
    fn press(&mut self, runtime: &mut Runtime) {
        self.press = None;
        let areas = self.areas(runtime);
        let (x, y) = self.pointer;
        if runtime.layer().is_some() {
            return;
        }
        if areas.tabs.is_some_and(|tabs| tabs.contains(x, y)) {
            let tab = paint::tab_items(runtime, &self.fonts, areas.editor.w)
                .into_iter()
                .find(|(_, rect, _)| x >= rect.x && x < rect.x + rect.w);
            if let Some((document, _, _)) = tab {
                runtime.input(UserInput::Pointer(Pointer::Document(document)));
            }
            return;
        }
        let Some(window) = areas.window_at(x, y) else {
            return;
        };
        let (view, header) = (window.view, window.header);
        if runtime.app().active_view() != Some(view) {
            runtime.input(UserInput::Pointer(Pointer::Window(view)));
        }
        if header.is_some_and(|header| header.contains(x, y)) {
            return;
        }
        let areas = self.areas(runtime);
        if let Some(offset) = self.offset(runtime, &areas) {
            self.press = Some(offset);
            runtime.input(UserInput::Pointer(Pointer::Click(offset)));
        }
    }
    fn drag(&mut self, runtime: &mut Runtime) {
        let Some(anchor) = self.press else {
            return;
        };
        let areas = self.areas(runtime);
        if let Some(head) = self.offset(runtime, &areas)
            && head != anchor
        {
            runtime.input(UserInput::Pointer(Pointer::Drag { anchor, head }));
        }
    }
    /// Scrolls the popup, else the window under the pointer, by rows.
    fn scroll(&mut self, runtime: &mut Runtime, rows: isize) {
        if rows == 0 || runtime.layer().is_some() {
            return;
        }
        if runtime.popup().is_some() {
            runtime.scroll_popup(rows);
            return;
        }
        let areas = self.areas(runtime);
        let (x, y) = self.pointer;
        let Some(window) = areas.window_at(x, y) else {
            return;
        };
        let (view, width, height) = (window.view, window.width(), window.rows);
        let active = runtime.app().active_view() == Some(view);
        let measure = Measured::new(&mut self.fonts);
        let Some((viewport, reveal)) =
            screen::scroll(runtime.app(), view, &measure, rows, width, height)
        else {
            return;
        };
        runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_scroll);
        // Other windows keep their carets; focusing one later scrolls back.
        if let Some(offset) = reveal.filter(|_| active) {
            runtime.input(UserInput::Pointer(Pointer::Reveal(offset)));
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.gui.is_some() {
            return;
        }
        let attributes = Window::default_attributes()
            .with_title("soda")
            .with_inner_size(LogicalSize::new(1100.0, 720.0));
        let window = match event_loop.create_window(attributes) {
            Ok(window) => Arc::new(window),
            Err(error) => return self.fail(event_loop, error.to_string()),
        };
        let renderer = match Renderer::new(window.clone()) {
            Ok(renderer) => renderer,
            Err(error) => return self.fail(event_loop, error),
        };
        window.set_ime_allowed(false);
        let mut gui = Gui::new(renderer, window.scale_factor() as f32);
        gui.measure(&mut self.runtime);
        self.gui = Some(gui);
        window.request_redraw();
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _: WindowId, event: WindowEvent) {
        let Some(gui) = &mut self.gui else {
            return;
        };
        let runtime = &mut self.runtime;
        match event {
            // Closing the window asks about unsaved documents, as quitting
            // does.
            WindowEvent::CloseRequested => {
                runtime.command(crate::interaction::Command::Named("quit".into()))
            }
            WindowEvent::Resized(size) => {
                gui.renderer.resize(size.width, size.height);
                gui.measure(runtime);
                gui.redraw();
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                gui.scale = scale_factor as f32;
                gui.measure(runtime);
                gui.redraw();
            }
            WindowEvent::ModifiersChanged(modifiers) => gui.modifiers = modifiers.state(),
            WindowEvent::KeyboardInput { event, .. } => {
                if let Some(stroke) = input::stroke(&event, gui.modifiers) {
                    runtime.input(UserInput::Key(stroke));
                }
            }
            WindowEvent::Ime(Ime::Preedit(text, _)) => {
                gui.preedit = text;
                gui.redraw();
            }
            WindowEvent::Ime(Ime::Commit(text)) => {
                gui.preedit.clear();
                for ch in text.chars() {
                    runtime.input(UserInput::Key(KeyStroke::plain(Key::Char(ch))));
                }
            }
            WindowEvent::Focused(true) => runtime.input(UserInput::FocusGained),
            WindowEvent::Focused(false) => runtime.input(UserInput::FocusLost),
            WindowEvent::CursorMoved { position, .. } => {
                gui.pointer = (position.x as f32, position.y as f32);
                gui.drag(runtime);
            }
            WindowEvent::MouseInput {
                state,
                button: MouseButton::Left,
                ..
            } => match state {
                ElementState::Pressed => gui.press(runtime),
                ElementState::Released => gui.press = None,
            },
            WindowEvent::MouseWheel { delta, .. } => {
                let step = runtime.app().options().int(None, "scroll-lines") as f32;
                let pixels = match delta {
                    MouseScrollDelta::LineDelta(_, lines) => lines * step * gui.fonts.line,
                    MouseScrollDelta::PixelDelta(position) => position.y as f32,
                };
                gui.scrolled -= pixels;
                let rows = (gui.scrolled / gui.fonts.line).trunc();
                gui.scrolled -= rows * gui.fonts.line;
                gui.scroll(runtime, rows as isize);
            }
            WindowEvent::RedrawRequested => {
                if let Err(error) = gui.draw(runtime) {
                    self.fail(event_loop, error);
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        self.runtime.poll();
        if self.runtime.quit_requested() {
            event_loop.exit();
            return;
        }
        // Ctrl-Z stops a terminal program; a window goes to the dock.
        if self.runtime.take_suspend()
            && let Some(window) = self.window()
        {
            window.set_minimized(true);
        }
        if let Some(gui) = &mut self.gui {
            // Typing goes through the input method only where text is typed.
            let typing = self.runtime.layer().is_some()
                || self.runtime.edit_mode() == crate::interaction::EditMode::Insert;
            if typing != gui.ime {
                gui.ime = typing;
                if let Some(window) = gui.renderer.window() {
                    window.set_ime_allowed(typing);
                }
                gui.preedit.clear();
            }
            gui.measure(&mut self.runtime);
            if self.runtime.take_redraw() || gui.pending {
                gui.redraw();
            }
        }
        event_loop.set_control_flow(ControlFlow::WaitUntil(std::time::Instant::now() + POLL));
    }
}

#[cfg(test)]
mod tests {
    use super::{GLIDE, Glide, paint::Rect};
    use std::time::{Duration, Instant};

    fn rect(x: f32) -> Rect {
        Rect {
            x,
            y: 10.0,
            w: 8.0,
            h: 20.0,
        }
    }
    #[test]
    fn the_caret_glides_to_a_new_place_without_a_trail() {
        let mut glide = Glide::default();
        let start = Instant::now();
        // The first place shows at once.
        assert_eq!(
            glide.place(Some((rect(0.0), false)), true, start),
            (Some(rect(0.0)), false)
        );
        // A new place starts from the old one and gets there in time,
        // more than half way at half the time.
        assert_eq!(
            glide.place(Some((rect(100.0), false)), true, start),
            (Some(rect(0.0)), true)
        );
        let (half, moving) = glide.place(Some((rect(100.0), false)), true, start + GLIDE / 2);
        assert!(moving && half.unwrap().x > 50.0 && half.unwrap().x < 100.0);
        assert_eq!(
            glide.place(Some((rect(100.0), false)), true, start + GLIDE),
            (Some(rect(100.0)), false)
        );
        // Moving again mid-way starts from where the caret shows.
        let later = start + GLIDE + Duration::from_millis(1);
        glide.place(Some((rect(0.0), false)), true, later);
        let (shown, _) = glide.place(Some((rect(200.0), false)), true, later + GLIDE / 2);
        assert!(shown.unwrap().x < 100.0, "{shown:?}");
        // A new shape, or no gliding, goes at once.
        let now = later + GLIDE * 4;
        assert_eq!(
            glide.place(Some((rect(5.0), true)), true, now),
            (Some(rect(5.0)), false)
        );
        assert_eq!(
            glide.place(Some((rect(50.0), true)), false, now),
            (Some(rect(50.0)), false)
        );
        assert_eq!(glide.place(None, true, now), (None, false));
    }
}
