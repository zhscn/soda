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
    /// Moves the caret's way by `dy`, as the text under it scrolls.
    fn shift(&mut self, dy: f32) {
        for rect in [&mut self.from, &mut self.to].into_iter().flatten() {
            rect.y += dy;
        }
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

/// How long a scroll takes to settle.
const SCROLL: Duration = Duration::from_millis(150);
/// How long a scroll bar stays after scrolling, then how long it fades.
const BAR: Duration = Duration::from_millis(800);
const FADE: Duration = Duration::from_millis(300);

/// A window's scrolling as the frontend shows it: the viewport anchor it
/// saw last, and how far the text is shifted past the anchor's row, easing
/// from `from` to the resting `to`. The rest is a part of a row a touchpad
/// scrolled; it stays until the anchor moves otherwise.
struct Scrolling {
    anchor: usize,
    from: f32,
    to: f32,
    start: Option<std::time::Instant>,
    /// The shift at the last frame, in terms of the current anchor: the
    /// text moved on screen by the difference since.
    last: f32,
    /// When it last moved, for the scroll bar.
    moved: Option<std::time::Instant>,
}
impl Scrolling {
    fn new(anchor: usize) -> Self {
        Self {
            anchor,
            from: 0.0,
            to: 0.0,
            start: None,
            last: 0.0,
            moved: None,
        }
    }
    fn progress(&self, now: std::time::Instant) -> f32 {
        let t = self.start.map_or(1.0, |start| {
            ((now - start).as_secs_f32() / SCROLL.as_secs_f32()).clamp(0.0, 1.0)
        });
        1.0 - (1.0 - t).powi(3)
    }
    /// The shift now.
    fn at(&self, now: std::time::Instant) -> f32 {
        self.from + (self.to - self.from) * self.progress(now)
    }
    fn moving(&self, now: std::time::Instant) -> bool {
        self.progress(now) < 1.0
    }
    /// How much the scroll bar shows: fully for a while after moving, then
    /// fading.
    fn bar(&self, now: std::time::Instant) -> f32 {
        let Some(moved) = self.moved else {
            return 0.0;
        };
        let since = now - moved;
        if since <= BAR {
            1.0
        } else {
            1.0 - ((since - BAR).as_secs_f32() / FADE.as_secs_f32()).min(1.0)
        }
    }
    /// The anchor moved `rows` rows down: the shift takes them, so the
    /// text stays where it was, and eases to `rest` when `smooth`.
    fn moved_by(
        &mut self,
        anchor: usize,
        rows: f32,
        line: f32,
        rest: f32,
        smooth: bool,
        now: std::time::Instant,
    ) {
        let current = self.at(now) - rows * line;
        self.last -= rows * line;
        self.anchor = anchor;
        self.to = rest;
        if smooth {
            self.from = current;
            self.start = Some(now);
        } else {
            self.from = rest;
            self.start = None;
        }
        self.moved = Some(now);
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
    // A frame before the keys, as a window shows one, so that what they
    // scroll scrolls from there.
    gui.draw(&mut runtime).map_err(io::Error::other)?;
    let keys = match keys {
        "" => vec![],
        keys => KeyStroke::parse_sequence(keys)
            .map_err(|error| io::Error::other(format!("{error:?}")))?,
    };
    for key in keys {
        runtime.input(UserInput::Key(key));
        gui.measure(&mut runtime);
    }
    settle(&mut runtime, &mut gui);
    // Highlighting, the glyph atlas, scrolling and the caret may take a
    // while to settle; the frame shows where they come to rest.
    for _ in 0..100 {
        gui.draw(&mut runtime).map_err(io::Error::other)?;
        if gui.settled {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
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
    /// The window whose scroll bar is being dragged.
    thumb: Option<ViewId>,
    /// Pixels scrolled that do not make a row yet, without smooth
    /// scrolling.
    scrolled: f32,
    scrolls: std::collections::BTreeMap<ViewId, Scrolling>,
    /// What an input method is composing.
    preedit: String,
    /// Whether the input method is on: where text is typed.
    ime: bool,
    geometry: Option<Geometry>,
    /// Draw again soon: highlighting or the atlas is catching up, or the
    /// caret is gliding.
    pending: bool,
    /// Nothing moves but scroll bars fading.
    settled: bool,
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
            fonts: Fonts::new(text::Settings {
                size: (14.0 * scale).round(),
                line_height: 135,
                text: String::new(),
                ui: String::new(),
            }),
            highlighter: Highlighter::with_budget(Duration::from_millis(12)),
            theme: Theme::build("auto", &Default::default(), false),
            theme_key: None,
            modifiers: ModifiersState::default(),
            pointer: (0.0, 0.0),
            press: None,
            thumb: None,
            scrolled: 0.0,
            scrolls: std::collections::BTreeMap::new(),
            preedit: String::new(),
            ime: false,
            geometry: None,
            pending: false,
            settled: true,
            caret: Glide::default(),
        }
    }
    fn redraw(&self) {
        if let Some(window) = self.renderer.window() {
            window.request_redraw();
        }
    }
    /// The fonts the options ask for.
    fn settings(&self, runtime: &Runtime) -> text::Settings {
        let options = runtime.app().options();
        let points = options.int(None, "font-size") as f32;
        text::Settings {
            size: (points * self.scale).round(),
            line_height: options.int(None, "line-height"),
            text: options.text(None, "font").to_owned(),
            ui: options.text(None, "ui-font").to_owned(),
        }
    }
    fn areas(&mut self, runtime: &Runtime) -> Areas {
        let settings = self.settings(runtime);
        self.fonts.configure(settings);
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
        let now = std::time::Instant::now();
        let shift = self.settle(runtime, &areas, now);
        self.caret.shift(shift);
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
        let scrolls = &self.scrolls;
        let motion = |view: ViewId| {
            scrolls
                .get(&view)
                .map_or(paint::Motion::default(), |s| paint::Motion {
                    scroll: s.at(now),
                    bar: s.bar(now),
                })
        };
        let mut painter = Painter::new(&mut self.fonts, &mut self.renderer.atlas, &self.theme);
        let caret = paint::screen(
            &mut painter,
            runtime,
            &areas,
            &mut self.highlighter,
            &self.preedit,
            &motion,
        )
        .map_err(|e| e.to_string())?;
        // Text being composed stays put while the caret glides.
        let smooth = runtime.app().options().bool(None, "smooth-caret") && self.preedit.is_empty();
        let (shown, gliding) = self.caret.place(caret, smooth, now);
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
        // Scrolls easing and scroll bars fading draw again too.
        let moving = self.scrolls.values().any(|s| s.moving(now));
        let fading = self.scrolls.values().any(|s| s.bar(now) > 0.0);
        self.settled =
            !(self.highlighter.take_pending() || self.renderer.atlas.cleared || gliding || moving);
        self.pending = !self.settled || fading;
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
    /// Brings each window's scrolling up to its viewport: a viewport that
    /// moved a few rows scrolls there smoothly; one that jumped further is
    /// just there. Returns how far the active window's text moved down on
    /// screen since the last frame, for the caret to go along.
    fn settle(&mut self, runtime: &Runtime, areas: &Areas, now: std::time::Instant) -> f32 {
        let smooth = runtime.app().options().bool(None, "smooth-scroll");
        let line = self.fonts.line;
        let active = runtime.app().active_view();
        let mut shift = 0.0;
        self.scrolls
            .retain(|view, _| areas.windows.iter().any(|window| window.view == *view));
        for window in &areas.windows {
            let Some(view) = runtime.app().view(window.view) else {
                continue;
            };
            let anchor = view.viewport.anchor.offset.0;
            let scrolling = self
                .scrolls
                .entry(window.view)
                .or_insert_with(|| Scrolling::new(anchor));
            if scrolling.anchor != anchor {
                let reach = usize::from(window.rows) * 3 + 8;
                let measure = Measured::new(&mut self.fonts);
                let rows = screen::rows_between(
                    runtime,
                    window.view,
                    &measure,
                    window.width(),
                    (scrolling.anchor, anchor),
                    reach,
                );
                match rows {
                    Some(rows) => {
                        scrolling.moved_by(anchor, rows as f32, line, 0.0, smooth, now);
                    }
                    // Too far to scroll through: the text is just there.
                    None => {
                        *scrolling = Scrolling::new(anchor);
                        scrolling.moved = Some(now);
                    }
                }
            }
            let at = scrolling.at(now);
            if Some(window.view) == active {
                shift = scrolling.last - at;
            }
            scrolling.last = at;
        }
        shift
    }
    /// The byte offset under the pointer in the active window's text.
    fn offset(&mut self, runtime: &Runtime, areas: &Areas) -> Option<usize> {
        let window = areas.active(runtime)?;
        let (x, y) = self.pointer;
        let now = std::time::Instant::now();
        let scroll = self.scrolls.get(&window.view).map_or(0.0, |s| s.at(now));
        let row = ((y - window.text.y + scroll) / self.fonts.line).floor() as isize;
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
            let tab = paint::tab_items(runtime, &mut self.fonts, areas.editor.w)
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
        // A press on a showing scroll bar takes the thumb there.
        let now = std::time::Instant::now();
        let bar = self.scrolls.get(&view).map_or(0.0, |s| s.bar(now));
        if bar > 0.0 && window.scroll_bar().contains(x, y) {
            self.thumb = Some(view);
            self.drag_thumb(runtime);
            return;
        }
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
    /// Scrolls the window whose scroll bar is held so that the thumb's
    /// middle is under the pointer.
    fn drag_thumb(&mut self, runtime: &mut Runtime) {
        let Some(view) = self.thumb else {
            return;
        };
        let areas = self.areas(runtime);
        let Some(window) = areas.windows.iter().find(|w| w.view == view) else {
            return;
        };
        let Some(line) = paint::line_at(runtime, window, self.pointer.1, self.fonts.line) else {
            return;
        };
        let app = runtime.app();
        let Some(document) = app.view(view) else {
            return;
        };
        let horizontal = document.viewport.horizontal_scroll;
        let Some(editor) = app.workspace().editor(document.document_id) else {
            return;
        };
        let Some(start) = editor.model().document().snapshot().line_start(line) else {
            return;
        };
        runtime.update_viewport(view, crate::core::ByteOffset(start), horizontal);
        // The thumb follows the pointer at once.
        let scrolling = self
            .scrolls
            .entry(view)
            .or_insert_with(|| Scrolling::new(start));
        *scrolling = Scrolling {
            moved: Some(std::time::Instant::now()),
            ..Scrolling::new(start)
        };
        self.redraw();
    }
    fn drag(&mut self, runtime: &mut Runtime) {
        if self.thumb.is_some() {
            return self.drag_thumb(runtime);
        }
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
    /// Scrolls the popup, else the window under the pointer, by `pixels`;
    /// down when positive. A wheel's notches scroll whole rows, smoothly; a
    /// touchpad scrolls by pixels, leaving part of a row scrolled.
    fn scroll(&mut self, runtime: &mut Runtime, pixels: f32, precise: bool) {
        if pixels == 0.0 || runtime.layer().is_some() {
            return;
        }
        let line = self.fonts.line;
        if runtime.popup().is_some() {
            self.scrolled += pixels;
            let rows = (self.scrolled / line).trunc();
            self.scrolled -= rows * line;
            runtime.scroll_popup(rows as isize);
            return;
        }
        let areas = self.areas(runtime);
        let (x, y) = self.pointer;
        let Some(window) = areas.window_at(x, y) else {
            return;
        };
        let (view, width, height) = (window.view, window.width(), window.rows);
        let smooth = runtime.app().options().bool(None, "smooth-scroll");
        let now = std::time::Instant::now();
        let Some(before) = runtime.app().view(view).map(|v| v.viewport.anchor.offset.0) else {
            return;
        };
        let scrolling = self
            .scrolls
            .entry(view)
            .or_insert_with(|| Scrolling::new(before));
        // Without smooth scrolling, or with a wheel, whole rows; a touchpad
        // keeps the part of a row it scrolled as the rest.
        let rest = if precise && smooth {
            scrolling.to
        } else {
            self.scrolled
        };
        let total = rest + pixels;
        let rows = (total / line).floor();
        let rest = total - rows * line;
        if !(precise && smooth) {
            self.scrolled = if precise { rest } else { 0.0 };
        }
        let active = runtime.app().active_view() == Some(view);
        let mut after = before;
        let mut reveal = None;
        if rows != 0.0 {
            let measure = Measured::new(&mut self.fonts);
            if let Some((viewport, back)) =
                screen::scroll(runtime.app(), view, &measure, rows as isize, width, height)
            {
                runtime.update_viewport(viewport.view, viewport.anchor, viewport.horizontal_scroll);
                after = viewport.anchor.0;
                reveal = back;
            }
        }
        let measure = Measured::new(&mut self.fonts);
        let moved = screen::rows_between(runtime, view, &measure, width, (before, after), 1 << 20)
            .unwrap_or(0) as f32;
        let scrolling = self.scrolls.get_mut(&view).unwrap();
        if precise && smooth {
            // At either end the rest cannot go further.
            let rest = if moved != rows { 0.0 } else { rest.max(0.0) };
            let rest = if after == 0 && total < 0.0 { 0.0 } else { rest };
            scrolling.moved_by(after, moved, line, rest, false, now);
        } else if moved != 0.0 {
            scrolling.moved_by(after, moved, line, 0.0, smooth, now);
        }
        // Other windows keep their carets; focusing one later scrolls back.
        if let Some(offset) = reveal.filter(|_| active) {
            runtime.input(UserInput::Pointer(Pointer::Reveal(offset)));
        }
        self.redraw();
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
                ElementState::Released => {
                    gui.press = None;
                    gui.thumb = None;
                }
            },
            WindowEvent::MouseWheel { delta, .. } => {
                let step = runtime.app().options().int(None, "scroll-lines") as f32;
                let (pixels, precise) = match delta {
                    MouseScrollDelta::LineDelta(_, lines) => (lines * step * gui.fonts.line, false),
                    MouseScrollDelta::PixelDelta(position) => (position.y as f32, true),
                };
                gui.scroll(runtime, -pixels, precise);
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
    use super::{BAR, FADE, GLIDE, Glide, SCROLL, Scrolling, paint::Rect};
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
    #[test]
    fn a_moved_viewport_keeps_the_text_in_place_then_eases_to_rest() {
        let start = Instant::now();
        let mut scrolling = Scrolling::new(0);
        assert_eq!(scrolling.at(start), 0.0);
        assert_eq!(scrolling.bar(start), 0.0);
        // Two rows down: at first the text is where it was, two rows
        // further down than the new anchor puts it; then it settles.
        scrolling.moved_by(10, 2.0, 20.0, 0.0, true, start);
        assert_eq!(scrolling.at(start), -40.0);
        assert_eq!(scrolling.last, -40.0);
        let half = scrolling.at(start + SCROLL / 2);
        assert!(half > -20.0 && half < 0.0, "{half}");
        assert_eq!(scrolling.at(start + SCROLL), 0.0);
        assert!(scrolling.moving(start) && !scrolling.moving(start + SCROLL));
        // The scroll bar shows, then fades.
        assert_eq!(scrolling.bar(start + BAR), 1.0);
        assert_eq!(scrolling.bar(start + BAR + FADE), 0.0);
        // A touchpad's part of a row rests without easing.
        scrolling.moved_by(20, 1.0, 20.0, 7.0, false, start);
        assert_eq!(scrolling.at(start), 7.0);
        assert!(!scrolling.moving(start));
    }
}
