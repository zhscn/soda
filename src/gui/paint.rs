//! The graphical screen: where everything goes, in pixels, and drawing it.
//!
//! Text flows in rows as high as the text font's line, but a window shows
//! whatever part of a row is in it: the last row may be cut by the window's
//! edge, and while scrolling every row is somewhere between two places.
//! The window tree is laid out in columns and rows of the text font and
//! stretched to fill the editing area. Around the text, words are in a
//! proportional font, with room around them; panels are rounded, the
//! gutter has a fringe for flags and no rules, a selection is rounded, and
//! a thin scroll bar shows while a window scrolls.
use super::{
    render::{Atlas, Instance, OUTLINE, RECT, UNCLIPPED, WAVE},
    text::{Face, Fonts, Kind, UNIT},
};
use crate::{
    application::{Area, Axis, Face as AppFace, ViewId},
    editor::DocumentId,
    interaction::{CommandLine, Layer},
    runtime::Runtime,
    screen::{
        self, Cells, Font, Highlighter, Span, TextFrame, Theme,
        content::{self, Message, Role},
    },
};
use ratatui::style::{Color, Modifier, Style};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}
impl Rect {
    fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        Self { x, y, w, h }
    }
    pub fn right(&self) -> f32 {
        self.x + self.w
    }
    pub fn bottom(&self) -> f32 {
        self.y + self.h
    }
    pub fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && x < self.right() && y >= self.y && y < self.bottom()
    }
    /// As a clip: left, top, right, bottom.
    fn clip(&self) -> [f32; 4] {
        [self.x, self.y, self.right(), self.bottom()]
    }
}

pub struct Window {
    pub view: ViewId,
    pub area: Rect,
    pub header: Option<Rect>,
    /// The gutter and the text, where rows show.
    pub body: Rect,
    /// Columns of line numbers; none without them.
    digits: Option<usize>,
    pub text: Rect,
    /// Rows of text that fit whole: paging and following the caret count
    /// these, though a part of the next shows too.
    pub rows: u16,
}
impl Window {
    /// The text area's width in measured units.
    pub fn width(&self) -> usize {
        (self.text.w * UNIT) as usize
    }
    /// The strip at the right of the text where the scroll bar is.
    pub fn scroll_bar(&self) -> Rect {
        Rect::new(self.body.right() - 10.0, self.body.y, 10.0, self.body.h)
    }
}
pub struct Areas {
    /// The row of tabs while no window is open, for the splash.
    pub tabs: Option<Rect>,
    pub editor: Rect,
    /// The editing area in columns and rows of the text font.
    pub cells: (u16, u16),
    pub windows: Vec<Window>,
    pub status: Rect,
    pub message: Rect,
    /// Columns and rows of the window tree, in pixels per cell.
    scale: (f32, f32),
}
impl Areas {
    pub fn new(runtime: &Runtime, fonts: &Fonts, width: f32, height: f32) -> Self {
        let (cell, line) = (fonts.cell, fonts.line);
        let row = bar_height(fonts);
        let message = Rect::new(0.0, (height - row).max(0.0), width, row);
        let status = Rect::new(0.0, (message.y - row).max(0.0), width, row);
        let app = runtime.app();
        let options = app.options();
        let tab_bar = options.bool(None, "tab-bar");
        let alone = app.windows().is_empty();
        let tabs =
            (tab_bar && alone && height > 4.0 * row).then(|| Rect::new(0.0, 0.0, width, row));
        let top = tabs.map_or(0.0, |tabs| tabs.h);
        let editor = Rect::new(0.0, top, width, (status.y - top).max(0.0));
        let cells = (
            (editor.w / cell).floor().max(0.0) as u16,
            (editor.h / line).floor().max(0.0) as u16,
        );
        let scale = (
            editor.w / f32::from(cells.0.max(1)),
            editor.h / f32::from(cells.1.max(1)),
        );
        let windows = app
            .windows()
            .layout(Area {
                x: 0,
                y: 0,
                width: cells.0,
                height: cells.1,
            })
            .into_iter()
            .map(|(view, area)| {
                let area = Rect::new(
                    editor.x + f32::from(area.x) * scale.0,
                    editor.y + f32::from(area.y) * scale.1,
                    f32::from(area.width) * scale.0,
                    f32::from(area.height) * scale.1,
                );
                // Each window's row of tabs, as `tab-line-mode` gives it, as
                // high as the status line: the text starts below it, off
                // the grid the windows are cut on.
                let header = (tab_bar && area.h >= row + line).then_some(Rect { h: row, ..area });
                let body = match header {
                    Some(header) => Rect {
                        y: area.y + header.h,
                        h: area.h - header.h,
                        ..area
                    },
                    None => area,
                };
                let document = app.view(view).map(|view| view.document_id);
                let lines = document
                    .and_then(|document| app.workspace().editor(document))
                    .map_or(1, |editor| {
                        editor.model().document().snapshot().line_count()
                    });
                let digits = (lines.max(1).ilog10() as usize + 1).max(3);
                let numbers = app.options().choice(document, "line-numbers") != "off";
                // A fringe for flags, the numbers, then room before the
                // text; without numbers, the fringe alone.
                let fringe = cell;
                let full = fringe + digits as f32 * cell + cell;
                let (digits, gutter) = if numbers && body.w >= full + 16.0 * cell {
                    (Some(digits), full)
                } else {
                    (None, fringe + cell * 0.5)
                };
                let text = Rect {
                    x: body.x + gutter,
                    w: (body.w - gutter).max(0.0),
                    ..body
                };
                Window {
                    view,
                    area,
                    header,
                    body,
                    digits,
                    text,
                    rows: (text.h / line).floor().max(0.0) as u16,
                }
            })
            .collect();
        Self {
            tabs,
            editor,
            cells,
            windows,
            status,
            message,
            scale,
        }
    }
    pub fn active(&self, runtime: &Runtime) -> Option<&Window> {
        let active = runtime.app().active_view()?;
        self.windows.iter().find(|window| window.view == active)
    }
    pub fn window_at(&self, x: f32, y: f32) -> Option<&Window> {
        self.windows
            .iter()
            .find(|window| window.area.contains(x, y))
    }
    /// The window whose right or bottom edge the pointer is on: in the
    /// gap between it and a window to its right, or a few pixels either
    /// side of where it meets a window below.
    pub fn edge_at(&self, x: f32, y: f32) -> Option<(ViewId, Axis)> {
        const REACH: f32 = 4.0;
        self.windows.iter().find_map(|window| {
            let area = window.area;
            let (right, bottom) = (area.right(), area.bottom());
            let beside = right + 1.0 < self.editor.right()
                && (area.y..bottom).contains(&y)
                && (right - REACH..right + self.scale.0 + REACH).contains(&x);
            let above = bottom + 1.0 < self.editor.bottom()
                && (area.x..right).contains(&x)
                && (y - bottom).abs() <= REACH;
            match (beside, above) {
                (true, _) => Some((window.view, Axis::Columns)),
                (_, true) => Some((window.view, Axis::Rows)),
                _ => None,
            }
        })
    }
    /// How many cells the pointer at `(x, y)` is past `view`'s edge: how far
    /// dragging it moves the edge.
    pub fn edge_moved(&self, view: ViewId, axis: Axis, x: f32, y: f32) -> i32 {
        let Some(window) = self.windows.iter().find(|w| w.view == view) else {
            return 0;
        };
        let cells = match axis {
            Axis::Columns => (x - window.area.right() - self.scale.0 / 2.0) / self.scale.0,
            Axis::Rows => (y - window.area.bottom()) / self.scale.1,
        };
        cells.round() as i32
    }
    /// Rows the command line may use for candidates.
    pub fn list_rows(&self) -> usize {
        usize::from(self.cells.1.saturating_sub(2)).min(10)
    }
}
/// The height of the tab bar, the status line and the message row: a line
/// with room above and below.
fn bar_height(fonts: &Fonts) -> f32 {
    fonts.line + (fonts.line * 0.4).round()
}

/// Tabs that fit across the tab bar: their documents, where they start and
/// how wide they are, and labels. Tabs drop from the left until the
/// active one fits.
pub fn tab_items(
    runtime: &Runtime,
    window: Option<ViewId>,
    fonts: &mut Fonts,
    width: f32,
) -> Vec<(Option<DocumentId>, Rect, String)> {
    let pad = fonts.cell * 1.2;
    let tabs = content::tabs(runtime, window);
    let widths: Vec<f32> = tabs
        .iter()
        .map(|tab| {
            let dot = if tab.dirty { fonts.cell * 1.5 } else { 0.0 };
            // As wide as its label in bold, which the active tab may be.
            let bold = Face {
                bold: true,
                ..Face::UI
            };
            fonts.width(&tab.label, bold) + dot + 2.0 * pad
        })
        .collect();
    let active = tabs.iter().position(|tab| tab.active).unwrap_or(0);
    let mut first = 0;
    while first < active && widths[first..=active].iter().sum::<f32>() > width {
        first += 1;
    }
    // Side by side from the left edge, each line between two shared.
    let mut x = 0.0;
    let mut out = vec![];
    for (tab, w) in tabs.into_iter().zip(widths).skip(first) {
        if x >= width {
            break;
        }
        out.push((tab.document, Rect::new(x, 0.0, w, 0.0), tab.label));
        x += w;
    }
    out
}
trait WidthOf {
    fn width_of(&self, text: &str) -> usize;
}
impl WidthOf for Cells {
    fn width_of(&self, text: &str) -> usize {
        screen::text_width(self, text, Font::Text)
    }
}

/// Converts a theme color; `Reset` takes the given default.
fn rgba(color: Option<Color>, default: [f32; 4]) -> [f32; 4] {
    let byte = |v: u8| f32::from(v) / 255.0;
    match color {
        Some(Color::Rgb(r, g, b)) => [byte(r), byte(g), byte(b), 1.0],
        Some(Color::Black) => [0.0, 0.0, 0.0, 1.0],
        Some(Color::White) => [1.0, 1.0, 1.0, 1.0],
        Some(Color::Gray) => [0.6, 0.6, 0.6, 1.0],
        Some(Color::DarkGray) => [0.35, 0.35, 0.35, 1.0],
        Some(Color::Red | Color::LightRed) => [0.9, 0.3, 0.3, 1.0],
        Some(Color::Green | Color::LightGreen) => [0.4, 0.8, 0.4, 1.0],
        Some(Color::Yellow | Color::LightYellow) => [0.9, 0.8, 0.3, 1.0],
        Some(Color::Blue | Color::LightBlue) => [0.4, 0.6, 0.95, 1.0],
        Some(Color::Magenta | Color::LightMagenta) => [0.8, 0.5, 0.9, 1.0],
        Some(Color::Cyan | Color::LightCyan) => [0.4, 0.8, 0.85, 1.0],
        _ => default,
    }
}
fn faded(color: [f32; 4], alpha: f32) -> [f32; 4] {
    [color[0], color[1], color[2], color[3] * alpha]
}
/// A style without its background, for words over a band or a badge.
fn without_bg(style: Style) -> Style {
    Style { bg: None, ..style }
}

/// How a window moves at this frame: how far its text is scrolled past the
/// top of its viewport, in pixels, and how much its scroll bar shows.
#[derive(Clone, Copy, Debug, Default)]
pub struct Motion {
    pub scroll: f32,
    pub bar: f32,
    /// Where the rows start across while the horizontal scroll eases.
    pub left: Option<usize>,
}

/// One frame being drawn.
pub struct Painter<'a> {
    pub fonts: &'a mut Fonts,
    pub atlas: &'a mut Atlas,
    pub out: Vec<Instance>,
    pub theme: &'a Theme,
    fg: [f32; 4],
    pub bg: [f32; 4],
    /// Where what is drawn may show.
    clip: [f32; 4],
    /// The caret line's band in the active window, one piece a row, in
    /// `out`: it moves with the caret while the caret glides.
    pub band: Vec<usize>,
    /// The line numbers of the active window: their glyphs in `out`, the
    /// top of their row and whether it is the caret's. Their color goes
    /// from the gutter's to the current line's as the band covers them.
    pub numbers: Vec<(std::ops::Range<usize>, f32, bool)>,
    /// The gutter's color and the current line number's, when the two
    /// differ only in color.
    pub number_colors: Option<([f32; 4], [f32; 4])>,
    /// Where the active window's caret may show.
    pub caret_clip: [f32; 4],
    /// Where in `out` the caret goes: above what it is in, under the
    /// panels that float over it, such as the key hints.
    pub caret_layer: usize,
}
impl<'a> Painter<'a> {
    pub fn new(fonts: &'a mut Fonts, atlas: &'a mut Atlas, theme: &'a Theme) -> Self {
        let fg = rgba(theme.text.fg, [0.85, 0.86, 0.9, 1.0]);
        let bg = rgba(theme.text.bg, [0.1, 0.1, 0.12, 1.0]);
        Self {
            fonts,
            atlas,
            out: Vec::with_capacity(8192),
            theme,
            fg,
            bg,
            clip: UNCLIPPED,
            band: vec![],
            caret_layer: 0,
            numbers: vec![],
            number_colors: None,
            caret_clip: UNCLIPPED,
        }
    }
    /// Colors the line numbers of the active window by how much of their
    /// row the band covers, from `top` down `height`; without a band, by
    /// whether they are on the caret's line.
    pub fn shade_numbers(&mut self, band: Option<(f32, f32)>) {
        let Some((plain, current)) = self.number_colors else {
            return;
        };
        let line = self.fonts.line;
        for (glyphs, y, caret) in &self.numbers {
            let t = match band {
                Some((top, height)) => {
                    let overlap = (y + line).min(top + height) - y.max(top);
                    (overlap / line).clamp(0.0, 1.0)
                }
                None => f32::from(u8::from(*caret)),
            };
            let color: [f32; 4] = std::array::from_fn(|i| plain[i] + (current[i] - plain[i]) * t);
            for instance in &mut self.out[glyphs.clone()] {
                instance.color = color;
            }
        }
    }
    fn push(&mut self, rect: Rect, color: [f32; 4], params: [f32; 4]) {
        self.out.push(Instance {
            rect: [rect.x, rect.y, rect.w, rect.h],
            uv: [0.0; 4],
            color,
            params,
            clip: self.clip,
        });
    }
    fn fill(&mut self, rect: Rect, color: [f32; 4], radius: f32) {
        if rect.w > 0.0 && rect.h > 0.0 && color[3] > 0.0 {
            self.push(rect, color, [RECT, radius, 0.0, 0.0]);
        }
    }
    fn outline(&mut self, rect: Rect, color: [f32; 4], radius: f32, thickness: f32) {
        self.push(rect, color, [OUTLINE, radius, thickness, 0.0]);
    }
    /// The colors of a style: foreground and, when it sets one, background.
    fn colors(&self, style: Style) -> ([f32; 4], Option<[f32; 4]>) {
        let mut fg = rgba(style.fg, self.fg);
        let mut bg = style.bg.map(|bg| rgba(Some(bg), self.bg));
        if style.add_modifier.contains(Modifier::REVERSED) {
            let back = bg.unwrap_or(self.bg);
            bg = Some(fg);
            fg = back;
        }
        if style.add_modifier.contains(Modifier::DIM) {
            fg = faded(fg, 0.6);
        }
        (fg, bg)
    }
    /// Draws words in a style and font with their row's top at `y`, at most
    /// `width` wide; returns where they end. `wavy` underlines with a wave.
    #[allow(clippy::too_many_arguments)]
    fn words(
        &mut self,
        x: f32,
        y: f32,
        text: &str,
        style: Style,
        kind: Kind,
        width: f32,
        wavy: bool,
    ) -> f32 {
        let face = Face {
            kind,
            bold: style.add_modifier.contains(Modifier::BOLD),
            italic: style.add_modifier.contains(Modifier::ITALIC),
        };
        let (fg, _) = self.colors(style);
        let baseline = y + if kind == Kind::Ui {
            self.fonts.ui_baseline
        } else {
            self.fonts.baseline
        };
        let mut shown = text;
        while !shown.is_empty() && self.fonts.width(shown, face) > width + 0.5 {
            let mut end = shown.len() - 1;
            while !shown.is_char_boundary(end) {
                end -= 1;
            }
            shown = &shown[..end];
        }
        let start = self.out.len();
        self.fonts
            .draw(self.atlas, &mut self.out, x, baseline, shown, face, fg);
        for instance in &mut self.out[start..] {
            instance.clip = self.clip;
        }
        let drawn = self.fonts.width(shown, face);
        if style.add_modifier.contains(Modifier::UNDERLINED) && drawn > 0.0 {
            let color = rgba(style.underline_color, fg);
            if wavy {
                let h = (self.fonts.line - self.fonts.baseline).clamp(3.0, 5.0);
                self.push(
                    Rect::new(x, baseline + 1.0, drawn, h),
                    color,
                    [WAVE, 0.0, 1.2, 0.0],
                );
            } else {
                self.fill(Rect::new(x, baseline + 2.0, drawn, 1.0), color, 0.0);
            }
        }
        if style.add_modifier.contains(Modifier::CROSSED_OUT) && drawn > 0.0 {
            let mid = baseline - self.fonts.size * 0.3;
            self.fill(Rect::new(x, mid, drawn, 1.0), fg, 0.0);
        }
        x + drawn
    }
    /// How wide words are in the parts' font, bold or italic as `style`.
    fn ui_width(&mut self, text: &str, style: Style) -> f32 {
        let face = Face {
            bold: style.add_modifier.contains(Modifier::BOLD),
            italic: style.add_modifier.contains(Modifier::ITALIC),
            ..Face::UI
        };
        self.fonts.width(text, face)
    }
    /// Words in the font of the parts around the text.
    fn ui(&mut self, x: f32, y: f32, text: &str, style: Style, width: f32) -> f32 {
        self.words(x, y, text, without_bg(style), Kind::Ui, width, false)
    }
    /// Spans laid out in cells, as inputs and candidate names are, from `x`
    /// on a row whose top is `y`, cut at `right`.
    fn cell_spans(&mut self, x: f32, y: f32, right: f32, spans: &[Span], base: Style) {
        let cell = self.fonts.cell;
        for span in spans {
            let style = self.theme.span(span, base);
            let at = x + span.x as f32 * cell;
            if at >= right {
                break;
            }
            let w = (span.width as f32 * cell).min(right - at);
            let (_, bg) = self.colors(style);
            if let Some(bg) = bg.filter(|bg| Some(*bg) != base.bg.map(|c| rgba(Some(c), self.bg))) {
                self.fill(Rect::new(at, y, w, self.fonts.line), bg, 0.0);
            }
            self.words(at, y, &span.text, style, Kind::Text, w, false);
        }
    }
    /// Draws within `area` only, until `unclip`.
    fn clip_to(&mut self, area: Rect) {
        self.clip = area.clip();
    }
    fn unclip(&mut self) {
        self.clip = UNCLIPPED;
    }
}

/// Draws the whole screen but the caret; returns the caret's rectangle,
/// after any text being composed, and whether it is a bar. `motion` tells
/// how each window is scrolling.
pub fn screen(
    painter: &mut Painter,
    runtime: &Runtime,
    areas: &Areas,
    highlighter: &mut Highlighter,
    preedit: &str,
    motion: &dyn Fn(ViewId) -> Motion,
) -> Result<Option<(Rect, bool)>, crate::application::Error> {
    let active = runtime.app().active_view();
    let bar =
        runtime.layer().is_some() || runtime.edit_mode() == crate::interaction::EditMode::Insert;
    let mut caret = None;
    if let Some(tabs) = areas.tabs {
        tab_bar(painter, runtime, tabs, None, true);
    }
    if areas.windows.is_empty() {
        splash(painter, areas.editor, &content::splash(runtime));
    }
    let line = painter.fonts.line;
    let mut texts = vec![];
    for window in &areas.windows {
        let moving = motion(window.view);
        // The rows that show, from the one the scroll has partly passed.
        let first = (moving.scroll / line).floor();
        let past = moving.scroll - first * line;
        let rows = ((window.text.h + past) / line).ceil().max(0.0) as u16;
        let text = {
            let measure = super::text::Measured::new(painter.fonts);
            screen::text(
                runtime,
                window.view,
                highlighter,
                &measure,
                window.width(),
                first as isize,
                moving.left,
                rows,
            )?
        };
        let current = Some(window.view) == active;
        if let Some(header) = window.header {
            tab_bar(painter, runtime, header, Some(window.view), current);
        }
        if let Some(text) = &text {
            let document = runtime.app().view(window.view).map(|view| view.document_id);
            let relative = runtime.app().options().choice(document, "line-numbers") == "relative";
            let at = editor(
                painter, runtime, window, text, current, relative, past, moving,
            );
            if current {
                caret = at;
                painter.caret_clip = window.text.clip();
            }
        }
        texts.push((window.view, text));
    }
    separators(painter, areas);
    if let Some(Layer::Labels(session)) = runtime.layer() {
        labels(painter, runtime, areas, session, motion);
    }
    let text = texts
        .iter()
        .find(|(view, _)| Some(*view) == active)
        .and_then(|(_, text)| text.as_ref());
    // The command line's candidates push the status line up over the text.
    let below = match runtime.layer() {
        Some(Layer::CommandLine(line)) if line.completes() => areas.list_rows() as f32,
        _ => 0.0,
    } * painter.fonts.line;
    status(
        painter,
        runtime,
        Rect {
            y: areas.status.y - below,
            ..areas.status
        },
        text,
    );
    let prompt = message(painter, runtime, areas.message, text);
    painter.caret_layer = painter.out.len();
    match runtime.layer() {
        Some(Layer::CommandLine(line)) => {
            let area = Rect {
                y: areas.message.y - below,
                h: areas.message.h + below,
                ..areas.message
            };
            caret = command_line(painter, area, areas.message.h, line);
            painter.caret_clip = UNCLIPPED;
            painter.caret_layer = painter.out.len();
        }
        Some(Layer::Help(session)) => {
            caret = None;
            help(painter, areas.editor, session.lines());
        }
        Some(_) => {
            caret = prompt;
            painter.caret_clip = UNCLIPPED;
        }
        None => key_hints(painter, runtime, areas),
    }
    if let (Some(at), None, Some(popup)) = (caret, runtime.layer(), runtime.completion_popup()) {
        completions(painter, areas.editor, at, popup);
    }
    if let (None, Some(words)) = (runtime.layer(), runtime.popup()) {
        floating(painter, runtime, areas.editor, caret, words);
    }
    // Text an input method is composing shows at the caret, underlined;
    // the caret follows it.
    if let Some(at) = &mut caret
        && !preedit.is_empty()
    {
        let width = painter.fonts.width(preedit, Face::TEXT);
        painter.fill(Rect { w: width, ..*at }, painter.bg, 0.0);
        let style = painter.theme.text.add_modifier(Modifier::UNDERLINED);
        painter.words(at.x, at.y, preedit, style, Kind::Text, width, false);
        at.x += width;
    }
    Ok(caret.map(|at| (at, bar)))
}

/// A window's row of tabs, or the splash's, as Zed draws a tab bar: tabs
/// side by side with a line after each, and a line along the bottom except
/// under the active tab, which has the text's background and so opens into
/// the text below. In the focused window the active tab is underlined in
/// the accent; elsewhere its label is not bold.
fn tab_bar(
    painter: &mut Painter,
    runtime: &Runtime,
    area: Rect,
    window: Option<ViewId>,
    current: bool,
) {
    let theme = painter.theme;
    let (_, bg) = painter.colors(theme.tabs);
    painter.fill(area, bg.unwrap_or(painter.bg), 0.0);
    let line = painter.fonts.line;
    let pad = painter.fonts.cell * 1.2;
    // Centered above the edge along the bottom.
    let top = (area.y + (area.h - 1.0 - line) / 2.0).round();
    let border = rgba(theme.border.fg, painter.fg);
    let tabs = content::tabs(runtime, window);
    let mut open = None;
    for (document, rect, label) in tab_items(runtime, window, painter.fonts, area.w) {
        let Some(tab) = tabs.iter().find(|tab| tab.document == document) else {
            continue;
        };
        let x = area.x + rect.x;
        let style = if tab.active {
            let (_, bg) = painter.colors(theme.tab_active);
            painter.fill(
                Rect::new(x, area.y, rect.w, area.h),
                bg.unwrap_or(painter.bg),
                0.0,
            );
            if x > area.x {
                painter.fill(Rect::new(x - 1.0, area.y, 1.0, area.h), border, 0.0);
            }
            open = Some((x, x + rect.w));
            if current && window.is_some() {
                let accent = rgba(theme.marker.fg, painter.fg);
                painter.fill(Rect::new(x, area.y, rect.w, 2.0), accent, 0.0);
                theme.tab_active
            } else if window.is_some() {
                theme.tab_active.remove_modifier(Modifier::BOLD)
            } else {
                theme.tab_active
            }
        } else {
            theme.tabs
        };
        painter.fill(
            Rect::new(x + rect.w - 1.0, area.y, 1.0, area.h),
            border,
            0.0,
        );
        let end = painter.ui(x + pad, top, &label, style, rect.w);
        if tab.dirty {
            let dot = (line * 0.28).round();
            let color = rgba(theme.modified.fg, painter.fg);
            let x = end + painter.fonts.cell * 0.6;
            painter.fill(
                Rect::new(x, area.y + (area.h - dot) / 2.0, dot, dot),
                color,
                dot,
            );
        }
    }
    let y = area.bottom() - 1.0;
    match open {
        Some((start, end)) => {
            edge(painter, area.x, y, start - area.x);
            edge(painter, end, y, area.right() - end);
        }
        None => edge(painter, area.x, y, area.w),
    }
}

/// The line between the text and what frames it, in the color of the line
/// between windows, so the frame does not run into the caret line.
fn edge(painter: &mut Painter, x: f32, y: f32, width: f32) {
    let color = rgba(painter.theme.border.fg, painter.fg);
    painter.fill(Rect::new(x, y, width, 1.0), color, 0.0);
}

/// Side-by-side windows have a thin line between them.
fn separators(painter: &mut Painter, areas: &Areas) {
    let color = rgba(painter.theme.border.fg, painter.fg);
    for window in &areas.windows {
        let right = window.area.right();
        if right + 1.0 < areas.editor.right() {
            let x = (right + areas.scale.0 / 2.0).floor();
            painter.fill(Rect::new(x, window.area.y, 1.0, window.area.h), color, 0.0);
        }
    }
}

/// A window's text, gutter and caret line, its rows `past` pixels above
/// where the frame's first row would start; returns the caret's rectangle.
#[allow(clippy::too_many_arguments)]
fn editor(
    painter: &mut Painter,
    runtime: &Runtime,
    window: &Window,
    text: &TextFrame,
    current: bool,
    relative: bool,
    past: f32,
    moving: Motion,
) -> Option<Rect> {
    let theme = painter.theme;
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let area = window.text;
    let left = window.body.x;
    painter.clip_to(window.body);
    let top = area.y - past;
    let selection = rgba(theme.selection.bg, faded(painter.fg, 0.25));
    // Only the focused window marks the caret line. Its band goes under
    // every row: gliding, it passes over the rows next to its own.
    let (_, band) = painter.colors(theme.cursor_line);
    for (index, row) in text.rows.iter().enumerate() {
        if let Some(bg) = band.filter(|_| current && row.line == text.caret.0) {
            let y = top + index as f32 * line;
            let index = painter.out.len();
            painter.fill(Rect::new(left, y, window.body.w, line), bg, 0.0);
            if painter.out.len() > index {
                painter.band.push(index);
            }
        }
    }
    for (index, row) in text.rows.iter().enumerate() {
        let y = top + index as f32 * line;
        let caret_line = current && row.line == text.caret.0;
        let base = if caret_line {
            theme.text.patch(theme.cursor_line)
        } else {
            theme.text
        };
        if let Some(digits) = window.digits.filter(|_| !row.continued) {
            let shown = if relative && row.line != text.caret.0 {
                row.line.abs_diff(text.caret.0)
            } else {
                row.line + 1
            };
            let number = format!("{shown:>digits$}");
            // In the active window the number's color follows the band, as
            // long as the two styles differ only in color.
            let shaded = current
                && theme.gutter.add_modifier == theme.gutter_current.add_modifier
                && theme.gutter.sub_modifier == theme.gutter_current.sub_modifier;
            let style = if caret_line && !shaded {
                theme.gutter_current
            } else {
                theme.gutter
            };
            let start = painter.out.len();
            let x = left + cell;
            let width = digits as f32 * cell;
            painter.words(x, y, &number, without_bg(style), Kind::Text, width, false);
            if shaded {
                let plain = rgba(theme.gutter.fg, painter.fg);
                let bright = rgba(theme.gutter_current.fg, painter.fg);
                painter.number_colors = Some((plain, bright));
                let end = painter.out.len();
                painter.numbers.push((start..end, y, caret_line));
            }
        }
        // A flag is a dot in the fringe, in its face's color.
        if let Some(flag) = row.flag.as_ref().filter(|_| !row.continued) {
            let color = rgba(theme.sign(flag.face).fg, painter.fg);
            let dot = (line * 0.32).round();
            let x = left + (cell - dot) / 2.0 + 1.0;
            painter.fill(Rect::new(x, y + (line - dot) / 2.0, dot, dot), color, dot);
        }
        // The selection, one rounded piece over spans side by side.
        let mut run: Option<(f32, f32)> = None;
        let mut runs = vec![];
        for span in row.spans.iter().filter(|span| span.selected) {
            let (x, w) = (area.x + span.x as f32 / UNIT, span.width as f32 / UNIT);
            run = match run {
                Some((start, end)) if (x - end).abs() < 0.5 => Some((start, x + w)),
                Some(done) => {
                    runs.push(done);
                    Some((x, x + w))
                }
                None => Some((x, x + w)),
            };
        }
        runs.extend(run);
        for (start, end) in runs {
            let end = end.min(area.right());
            painter.fill(Rect::new(start, y, end - start, line), selection, 3.0);
        }
        for span in &row.spans {
            let style = theme.span(span, base);
            let x = area.x + span.x as f32 / UNIT;
            let w = (span.width as f32 / UNIT).min(area.right() - x);
            if w <= 0.0 {
                break;
            }
            let (fg, bg) = painter.colors(style);
            let kind = match span.font {
                Font::Hint => Kind::Hint,
                Font::Text => Kind::Text,
            };
            if span.inlay {
                // Hints sit in a soft pill, so they read as not the text.
                let pill = Rect::new(x + 1.0, y + 2.0, w - 2.0, line - 4.0);
                painter.fill(pill, faded(fg, 0.12), 4.0);
            } else if !span.selected
                && let Some(bg) =
                    bg.filter(|bg| *bg != painter.colors(base).1.unwrap_or(painter.bg))
            {
                painter.fill(Rect::new(x, y, w, line), bg, 0.0);
            }
            let wavy = matches!(span.face, Some(AppFace::Note(_)));
            painter.words(x, y, &span.text, style, kind, w, wavy);
        }
        // A digit that extends a selection of lines covers the first column
        // that shows, as meow's covers the line's first character.
        if let Some(digit) = row.digit {
            let cell = painter.fonts.cell;
            let (_, bg) = painter.colors(theme.digit);
            painter.fill(
                Rect::new(area.x, y, cell, line),
                bg.unwrap_or(painter.bg),
                0.0,
            );
            let text = digit.to_string();
            painter.words(
                area.x,
                y,
                &text,
                without_bg(theme.digit),
                Kind::Text,
                cell,
                false,
            );
        }
        if let Some(ruler) = text.ruler {
            let x = area.x + ruler as f32 / UNIT;
            let color = rgba(theme.ruler.bg, faded(painter.fg, 0.15));
            painter.fill(Rect::new(x.floor(), y, 1.0, line), color, 0.0);
        }
    }
    scroll_bar(painter, runtime, window, moving);
    painter.unclip();
    text.cursor.map(|(x, y)| {
        let x = area.x + x as f32 / UNIT;
        // A block covers the whole character, two columns for a Chinese
        // one, but not past the window.
        let width = (text.caret_width as f32 / UNIT)
            .min(area.right() - x)
            .max(1.0);
        Rect::new(x, top + y as f32 * line, width, line)
    })
}

/// Where a window's scroll bar thumb is, when the document is longer than
/// the window: its top in the bar's strip and its height. The last line
/// can scroll to the top, so the range is the lines and a window less one.
pub fn thumb(runtime: &Runtime, window: &Window, scroll: f32, line: f32) -> Option<(f32, f32)> {
    let (top_line, lines) = top_line(runtime, window.view)?;
    let rows = f32::from(window.rows.max(1));
    if lines <= rows {
        return None;
    }
    let range = lines - 1.0;
    let at = (top_line + scroll / line).clamp(0.0, range);
    let track = window.body.h;
    let height = (rows / (lines + rows - 1.0) * track).clamp(24.0_f32.min(track), track);
    Some((at / range * (track - height), height))
}
/// The line at the top of a view, and how many lines its document has.
fn top_line(runtime: &Runtime, view: ViewId) -> Option<(f32, f32)> {
    let view = runtime.app().view(view)?;
    let editor = runtime.app().workspace().editor(view.document_id)?;
    let snapshot = editor.model().document().snapshot();
    let top = snapshot.line_of(view.viewport.anchor.offset.0).unwrap_or(0);
    Some((top as f32, snapshot.line_count() as f32))
}
/// The line a press on a window's scroll bar strip at `y` scrolls to the
/// top: the thumb's middle goes there.
pub fn line_at(runtime: &Runtime, window: &Window, y: f32, line: f32) -> Option<usize> {
    let (_, lines) = top_line(runtime, window.view)?;
    let (_, height) = thumb(runtime, window, 0.0, line)?;
    let track = window.body.h - height;
    let at = ((y - window.body.y - height / 2.0) / track.max(1.0)).clamp(0.0, 1.0);
    Some((at * (lines - 1.0)).round() as usize)
}
/// A thin thumb at the window's right, shown while it scrolls.
fn scroll_bar(painter: &mut Painter, runtime: &Runtime, window: &Window, moving: Motion) {
    if moving.bar <= 0.0 {
        return;
    }
    let line = painter.fonts.line;
    let Some((top, height)) = thumb(runtime, window, moving.scroll, line) else {
        return;
    };
    let color = rgba(painter.theme.scrollbar.bg, faded(painter.fg, 0.4));
    let strip = window.scroll_bar();
    let thumb = Rect::new(strip.right() - 7.0, strip.y + top, 5.0, height);
    painter.fill(thumb, faded(color, 0.6 * moving.bar), 2.5);
}

/// The caret: a translucent block over a character, or a bar between
/// characters, in the color of the mode.
pub fn cursor(painter: &mut Painter, runtime: &Runtime, at: Rect, bar: bool) {
    let theme = painter.theme;
    let accent = match (runtime.layer(), runtime.edit_mode()) {
        (None, crate::interaction::EditMode::Beacon) => theme.mode_visual,
        (None, crate::interaction::EditMode::Insert) => theme.mode_insert,
        (None, _) => theme.mode_normal,
        _ => theme.mode_prompt,
    };
    let color = rgba(accent.bg, painter.fg);
    painter.clip = painter.caret_clip;
    if bar {
        // As wide as the text is heavy, over the edge between characters;
        // at the line start, half of it is left of the text, which shows.
        let width = (painter.fonts.cell * 0.2).round().max(2.0);
        painter.clip[0] -= width;
        painter.fill(
            Rect::new((at.x - width / 2.0).round(), at.y + 1.0, width, at.h - 2.0),
            color,
            width / 2.0,
        );
    } else {
        painter.fill(at, faded(color, 0.45), 2.0);
        painter.outline(at, color, 2.0, 1.0);
    }
    painter.unclip();
}

fn splash(painter: &mut Painter, area: Rect, lines: &[(String, &str)]) {
    let theme = painter.theme;
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let keys = lines
        .iter()
        .map(|(key, _)| painter.fonts.width(key, Face::TEXT))
        .fold(10.0 * cell, f32::max);
    let docs = lines
        .iter()
        .map(|(_, doc)| painter.fonts.width(doc, Face::UI))
        .fold(0.0, f32::max);
    let (w, h) = (
        keys + 2.0 * cell + docs,
        (lines.len() + 2) as f32 * line * 1.2,
    );
    if area.h < h || area.w < w {
        return;
    }
    let (x, y) = (area.x + (area.w - w) / 2.0, area.y + (area.h - h) / 2.0);
    let title = theme.title.add_modifier(Modifier::BOLD);
    let width = painter.fonts.width("soda", Face::UI);
    painter.ui(x + (w - width) / 2.0, y, "soda", title, w);
    for (index, (key, doc)) in lines.iter().enumerate() {
        let y = y + (2.0 + index as f32) * line * 1.2;
        let key_width = painter.fonts.width(key, Face::TEXT);
        let style = without_bg(theme.key);
        painter.words(x + keys - key_width, y, key, style, Kind::Text, w, false);
        painter.ui(x + keys + 2.0 * cell, y, doc, theme.dim, w);
    }
}

/// The style of a piece of the status line or the message row.
fn role_style(role: Role, theme: &Theme) -> Style {
    match role {
        Role::Plain => Style::new(),
        Role::Key => theme.key,
        Role::Modified => theme.modified,
        Role::Detail => theme.detail,
        Role::Severity(crate::application::Severity::Error) => theme.status_error,
        Role::Severity(crate::application::Severity::Warning) => theme.status_warning,
        Role::Severity(severity) => theme.severity(severity),
        Role::Face(face) => face.map_or(theme.status, |face| theme.status.patch(theme.face(face))),
    }
}

fn status(painter: &mut Painter, runtime: &Runtime, area: Rect, text: Option<&TextFrame>) {
    let theme = painter.theme;
    let (_, bg) = painter.colors(theme.status);
    painter.fill(area, bg.unwrap_or(painter.bg), 0.0);
    edge(painter, area.x, area.y, area.w);
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    // Words and the mode's pill center below the edge.
    let inner = Rect::new(area.x, area.y + 1.0, area.w, area.h - 1.0);
    let top = (inner.y + (inner.h - line) / 2.0).round();
    let status = content::status(runtime, text);
    // The mode's pill, when there is a mode to name; the path follows it.
    let mut left = cell * 0.6;
    if let Some(mode) = status.mode {
        let badge = match mode {
            content::Mode::Normal => theme.mode_normal,
            content::Mode::Insert => theme.mode_insert,
            content::Mode::Beacon => theme.mode_visual,
            content::Mode::Prompt(_) => theme.mode_prompt,
        };
        let label = mode.label();
        let bold = Face {
            bold: true,
            ..Face::UI
        };
        let width = painter.fonts.width(label, bold) + 1.6 * cell;
        let (_, badge_bg) = painter.colors(badge);
        let pill = Rect::new(cell * 0.6, inner.y + 3.0, width, inner.h - 6.0);
        painter.fill(pill, badge_bg.unwrap_or(painter.fg), 7.0);
        let style = badge.add_modifier(Modifier::BOLD);
        painter.ui(pill.x + 0.8 * cell, top, label, style, width);
        left = pill.right() + cell;
    }
    // The right side: segments.
    let right: Vec<(String, Style)> = status
        .segments
        .iter()
        .map(|(words, role)| (words.clone(), role_style(*role, theme)))
        .collect();
    let gap = 1.6 * cell;
    let widths: Vec<f32> = right
        .iter()
        .map(|(words, style)| painter.ui_width(words, theme.status.patch(*style)))
        .collect();
    let total: f32 = widths.iter().sum::<f32>() + gap * right.len() as f32;
    let mut x = area.right() - total;
    for ((words, style), w) in right.iter().zip(&widths) {
        let style = theme.status.patch(*style);
        painter.ui(x, top, words, style, *w);
        x += w + gap;
    }
    if let Some(document) = status.document {
        let x = left;
        let room = (area.right() - total - x - gap).max(0.0);
        // The caret's place follows the document, as Emacs's mode line.
        let place = status
            .place
            .map(|(line, column)| format!("{line}:{column}"));
        let place_width = place
            .as_deref()
            .map_or(0.0, |place| painter.ui_width(place, theme.status) + gap);
        let style = theme.status.patch(theme.status_strong);
        let path = fitting(
            painter.fonts,
            &document.path,
            room - 6.0 * cell - place_width,
        );
        let mut end = painter.ui(x, top, &path, style, room);
        if document.dirty {
            let dot = (line * 0.28).round();
            let color = rgba(theme.modified.fg, painter.fg);
            let y = (inner.y + (inner.h - dot) / 2.0).round();
            painter.fill(Rect::new(end + cell * 0.6, y, dot, dot), color, dot);
            end += cell * 0.6 + dot;
        }
        if document.saving {
            let style = theme.status.add_modifier(Modifier::DIM);
            end = painter.ui(end + 2.0 * cell, top, "saving…", style, room);
        }
        if let Some(place) = place {
            painter.ui(end + gap, top, &place, theme.status, room);
        }
    }
}

/// The end of a path within `width` pixels of the parts' font, marked with
/// `…` when cut: the file name stays.
fn fitting(fonts: &mut Fonts, text: &str, width: f32) -> String {
    if fonts.width(text, Face::UI) <= width {
        return text.to_owned();
    }
    let chars: Vec<char> = text.chars().collect();
    for start in 1..chars.len() {
        let tail: String = std::iter::once('…')
            .chain(chars[start..].iter().copied())
            .collect();
        if fonts.width(&tail, Face::UI) <= width {
            return tail;
        }
    }
    String::new()
}

/// The bottom row; returns the prompt's caret.
fn message(
    painter: &mut Painter,
    runtime: &Runtime,
    area: Rect,
    text: Option<&TextFrame>,
) -> Option<Rect> {
    let theme = painter.theme;
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let top = (area.y + (area.h - line) / 2.0).round();
    let x = cell * 0.8;
    let columns = ((area.w - x) / cell) as usize;
    match content::message(runtime, text) {
        Message::Prompt(presentation) => {
            let (row, caret) = screen::prompt_row(&presentation, columns);
            painter.cell_spans(x, top, area.right(), &row, theme.text);
            caret.map(|column| {
                let column = column.min(columns.saturating_sub(1));
                Rect::new(x + column as f32 * cell, top, cell, line)
            })
        }
        Message::Words(words, role) => {
            let style = match role {
                Role::Plain => theme.text,
                Role::Severity(severity) => theme.severity(severity),
                role => role_style(role, theme),
            };
            let words = words.lines().next().unwrap_or("");
            painter.ui(x, top, words, style, area.w - x);
            None
        }
    }
}

/// A rounded panel with a soft shadow, for what floats over the text.
fn panel(painter: &mut Painter, area: Rect) {
    let theme = painter.theme;
    let (_, bg) = painter.colors(theme.float);
    let border = rgba(theme.float_border.fg, faded(painter.fg, 0.3));
    for (spread, alpha) in [(6.0, 0.06), (3.0, 0.1)] {
        let shadow = Rect::new(
            area.x - spread / 2.0,
            area.y + spread / 2.0,
            area.w + spread,
            area.h + spread,
        );
        painter.fill(shadow, [0.0, 0.0, 0.0, alpha], 10.0 + spread / 2.0);
    }
    painter.fill(area, bg.unwrap_or(painter.bg), 10.0);
    painter.outline(area, faded(border, 0.5), 10.0, 1.0);
}

/// The command line: its input in a message-high row under the status
/// line, the candidates below it.
fn command_line(
    painter: &mut Painter,
    area: Rect,
    message: f32,
    line: &CommandLine,
) -> Option<Rect> {
    let theme = painter.theme;
    let (cell, row_h) = (painter.fonts.cell, painter.fonts.line);
    let rows = line.rows();
    let list = line.list();
    // The input sits in the middle of a message-high row at the top.
    let input_top = area.y + message / 2.0 - row_h / 2.0;
    painter.fill(area, painter.bg, 0.0);
    // What the line is for, at the right, in at most half the row.
    let info = content::command_info(line, theme, |whole| {
        painter.fonts.width(whole, Face::UI) < area.w / 2.0
    });
    let joined: Vec<&str> = info.iter().map(|(t, _)| t.as_str()).collect();
    let info_width =
        (painter.fonts.width(&joined.join(" · "), Face::UI) + 2.0 * cell).min(area.w / 2.0);
    let x = cell * 0.8;
    let field = (area.w - info_width - x).max(0.0);
    let columns = (field / cell) as usize;
    let (input, column) = screen::prompt_row(&line.field(), columns);
    // Enter takes the input as typed: it shows selected, as vertico's
    // prompt does.
    let input_style = if line.input_selected() {
        let (_, bg) = painter.colors(theme.candidate_selected);
        let band = Rect::new(x - cell * 0.4, input_top, field, row_h);
        painter.fill(band, bg.unwrap_or(painter.fg), 6.0);
        without_bg(theme.text.patch(theme.candidate_selected))
    } else {
        theme.text
    };
    painter.cell_spans(x, input_top, x + field, &input, input_style);
    let mut ix = area.right() - info_width + cell;
    for (index, (words, style)) in info.iter().enumerate() {
        if index > 0 {
            ix = painter.ui(ix, input_top, " · ", theme.dim, area.w);
        }
        ix = painter.ui(ix, input_top, words, *style, area.w);
    }
    // Whole rows below the input's row; rounding, not flooring, so that
    // a fraction of a pixel lost in the sums does not lose a row.
    let count = ((area.h - message) / row_h).round().max(0.0) as usize;
    if count > 0 {
        let list_area = Rect::new(0.0, area.y + message, area.w, count as f32 * row_h);
        let (_, bg) = painter.colors(theme.float);
        painter.fill(list_area, bg.unwrap_or(painter.bg), 0.0);
        let selected = list.selected();
        for offset in 0..count {
            let Some(row) = rows.get(list.first_visible() + offset) else {
                break;
            };
            let y = list_area.y + offset as f32 * row_h;
            let chosen = selected == Some(row.candidate.key);
            let base = if chosen {
                let (_, bg) = painter.colors(theme.candidate_selected);
                let band = Rect::new(6.0, y, area.w - 12.0, row_h);
                painter.fill(band, bg.unwrap_or(painter.fg), 6.0);
                theme.text.patch(theme.candidate_selected)
            } else {
                theme.text
            };
            if chosen {
                let marker = rgba(theme.marker.fg, painter.fg);
                painter.fill(Rect::new(6.0, y + 4.0, 3.0, row_h - 8.0), marker, 1.5);
            }
            // The name in the text font; the words after it, such as a
            // command's description, in the parts' font, from the column
            // the candidate puts them at.
            let label = &row.candidate.label;
            let detail = row.candidate.payload.detail.filter(|at| *at <= label.len());
            let name_end = detail.unwrap_or(label.len());
            let name_columns = Cells.width_of(&label[..name_end]);
            let width = ((area.w - 2.0 * cell) / cell) as usize;
            let spans = screen::candidate_row(row, None, None, width.min(name_columns));
            let base = without_bg(base);
            painter.cell_spans(2.0 * cell, y, area.right(), &spans, base);
            if let Some(at) = detail {
                let words = label[at..].trim();
                let dx = 2.0 * cell + name_columns as f32 * cell;
                let style = base.patch(theme.detail);
                painter.ui(dx, y, words, style, (area.right() - dx - cell).max(0.0));
            }
        }
    }
    column.map(|c| {
        let c = c.min(columns.saturating_sub(1));
        Rect::new(x + c as f32 * cell, input_top, cell, row_h)
    })
}

fn help<'a>(painter: &mut Painter, area: Rect, lines: impl Iterator<Item = &'a str>) {
    let theme = painter.theme;
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let inner = Rect::new(
        area.x + cell,
        area.y + line * 0.5,
        area.w - 2.0 * cell,
        area.h - line,
    );
    panel(painter, inner);
    painter.clip_to(inner);
    let title = theme.title.add_modifier(Modifier::BOLD);
    painter.ui(
        inner.x + cell,
        inner.y + line * 0.3,
        "Help · Esc closes",
        title,
        inner.w,
    );
    let rows = ((inner.h - line * 1.6) / line).floor().max(0.0) as usize;
    let columns = ((inner.w - 2.0 * cell) / cell) as usize;
    // Help aligns its keys in columns, so it keeps the text font.
    for (index, text) in lines.enumerate().take(rows) {
        let y = inner.y + line * 1.4 + index as f32 * line;
        let text = screen::plain(text, 0, columns);
        let style = without_bg(theme.panel);
        let width = inner.w - 2.0 * cell;
        painter.words(inner.x + cell, y, &text, style, Kind::Text, width, false);
    }
    painter.unclip();
}

/// Keys that continue a pending binding, in columns at the lower right.
fn key_hints(painter: &mut Painter, runtime: &Runtime, areas: &Areas) {
    let theme = painter.theme;
    let mut entries = runtime.key_continuations();
    if entries.is_empty() {
        return;
    }
    entries.sort();
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let key_width = entries
        .iter()
        .map(|(k, _)| painter.fonts.width(k, Face::TEXT))
        .fold(0.0, f32::max);
    let doc_width = entries
        .iter()
        .map(|(_, d)| painter.fonts.width(d, Face::UI))
        .fold(0.0, f32::max);
    let column = (key_width + cell * 1.5 + doc_width).min(cell * 56.0);
    let area = areas.editor;
    let max_rows = ((area.h / line) as usize).saturating_sub(3).clamp(1, 12);
    let columns = entries.len().div_ceil(max_rows);
    let rows = entries.len().div_ceil(columns);
    let room = (area.w - 4.0 * cell) / columns as f32;
    let column = column.min(room - 2.0 * cell);
    if column <= key_width + cell * 2.0 {
        return;
    }
    let w = columns as f32 * (column + 2.0 * cell) + cell;
    let h = (rows as f32 + 1.6) * line;
    if w > area.w || h > area.h {
        return;
    }
    let rect = Rect::new(
        area.right() - w - cell,
        area.bottom() - h - line * 0.5,
        w,
        h,
    );
    panel(painter, rect);
    painter.clip_to(rect);
    let title = runtime.pending_keys().unwrap_or_default();
    let style = theme.title.add_modifier(Modifier::BOLD);
    painter.ui(rect.x + cell * 1.5, rect.y + line * 0.3, &title, style, w);
    for (index, (key, doc)) in entries.iter().enumerate() {
        let x = rect.x + cell * 1.5 + (index / rows) as f32 * (column + 2.0 * cell);
        let y = rect.y + line * 1.3 + (index % rows) as f32 * line;
        let width = painter.fonts.width(key, Face::TEXT);
        let style = without_bg(theme.key);
        painter.words(x + key_width - width, y, key, style, Kind::Text, w, false);
        let room = column - key_width - cell * 1.5;
        painter.ui(x + key_width + cell * 1.5, y, doc, theme.panel, room);
    }
    painter.unclip();
}

/// The candidates, under the word at the caret, or above it near the bottom.
fn completions(
    painter: &mut Painter,
    area: Rect,
    caret: Rect,
    popup: crate::interaction::completion::Popup,
) {
    let theme = painter.theme;
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let label = popup
        .rows
        .iter()
        .map(|r| painter.fonts.width(&r.label, Face::TEXT))
        .fold(0.0, f32::max);
    let detail = popup
        .rows
        .iter()
        .map(|r| painter.fonts.width(&r.detail, Face::UI))
        .fold(0.0, f32::max);
    let w = (label + detail + 4.0 * cell).min(area.w);
    let (above, below) = (caret.y - area.y, area.bottom() - caret.bottom());
    let wanted = popup.rows.len() as f32 * line + 10.0;
    let fits_below = below >= wanted || below >= above;
    let h = wanted.min(if fits_below { below } else { above } - 4.0);
    if h < line + 10.0 {
        return;
    }
    let x = (caret.x - (popup.typed as f32 + 1.0) * cell)
        .max(area.x)
        .min(area.right() - w);
    let y = if fits_below {
        caret.bottom() + 3.0
    } else {
        caret.y - h - 3.0
    };
    let rect = Rect::new(x, y, w, h);
    panel(painter, rect);
    painter.clip_to(rect);
    let visible = ((h - 10.0) / line).floor() as usize;
    for (row, candidate) in popup.rows.iter().take(visible).enumerate() {
        let ry = y + 5.0 + row as f32 * line;
        let base = if candidate.selected {
            let (_, bg) = painter.colors(theme.candidate_selected);
            let band = Rect::new(x + 4.0, ry, w - 8.0, line);
            painter.fill(band, bg.unwrap_or(painter.fg), 5.0);
            theme.float.patch(theme.candidate_selected)
        } else {
            theme.float
        };
        let base = without_bg(base);
        let name = w - detail - 3.0 * cell;
        painter.words(
            x + cell,
            ry,
            &candidate.label,
            base,
            Kind::Text,
            name,
            false,
        );
        for range in &candidate.matched {
            let column = Cells.width_of(&candidate.label[..range.start]) as f32 * cell;
            if column < name {
                let matched = &candidate.label[range.clone()];
                let style = base.patch(theme.key);
                let room = name - column;
                painter.words(
                    x + cell + column,
                    ry,
                    matched,
                    style,
                    Kind::Text,
                    room,
                    false,
                );
            }
        }
        let dx = x + w - detail - cell;
        painter.ui(dx, ry, &candidate.detail, base.patch(theme.detail), detail);
    }
    painter.unclip();
    if let Some(doc) = popup.rows.iter().find(|r| r.selected && !r.doc.is_empty()) {
        documentation(painter, area, rect, &doc.doc);
    }
}

/// The selected candidate's documentation, beside the list.
fn documentation(painter: &mut Painter, area: Rect, list: Rect, doc: &str) {
    let theme = painter.theme;
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let (left, right) = (list.x - area.x, area.right() - list.right());
    let room = left.max(right);
    if room < 16.0 * cell {
        return;
    }
    let widest = ((room / cell) as usize - 4).min(72);
    let lines = screen::wrap(doc.trim_end(), widest);
    let h = (lines.len() as f32 * line + 10.0).min(area.bottom() - list.y);
    if h < line + 10.0 {
        return;
    }
    let inner = lines
        .iter()
        .map(|l| Cells.width_of(l))
        .max()
        .unwrap_or(0)
        .min(widest);
    let w = (inner + 2) as f32 * cell;
    let x = if right >= left {
        list.right() + 6.0
    } else {
        list.x - w - 6.0
    };
    let rect = Rect::new(x, list.y, w, h);
    panel(painter, rect);
    painter.clip_to(rect);
    let shown = ((h - 10.0) / line).floor() as usize;
    for (row, text) in lines.iter().take(shown).enumerate() {
        let style = without_bg(theme.float);
        let y = list.y + 5.0 + row as f32 * line;
        painter.words(x + cell, y, text, style, Kind::Text, w - 2.0 * cell, false);
    }
    painter.unclip();
}

/// Words in a box by the caret, on whichever side has more room; they
/// scroll when they do not fit.
fn floating(
    painter: &mut Painter,
    runtime: &Runtime,
    area: Rect,
    caret: Option<Rect>,
    words: &str,
) {
    let theme = painter.theme;
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let widest = ((area.w / cell) as usize).saturating_sub(4).min(80);
    if widest < 8 || area.h < 3.0 * line {
        return;
    }
    let lines = screen::wrap(words, widest);
    let caret = caret.unwrap_or(Rect::new(area.x, area.y, cell, line));
    let (above, below) = (caret.y - area.y, area.bottom() - caret.bottom());
    let room = ((above.max(below) - 10.0) / line).floor().max(0.0) as usize;
    if room == 0 {
        return;
    }
    let shown = lines.len().min(room);
    let first = runtime.popup_scroll(shown, lines.len());
    let inner = lines
        .iter()
        .map(|l| Cells.width_of(l))
        .max()
        .unwrap_or(0)
        .min(widest);
    let (w, h) = ((inner + 2) as f32 * cell, shown as f32 * line + 10.0);
    let y = if below >= above {
        caret.bottom() + 3.0
    } else {
        caret.y - h - 3.0
    };
    let x = caret.x.min(area.right() - w).max(area.x);
    let rect = Rect::new(x, y, w, h);
    panel(painter, rect);
    painter.clip_to(rect);
    for (row, text) in lines[first..first + shown].iter().enumerate() {
        let style = without_bg(theme.float);
        let y = y + 5.0 + row as f32 * line;
        painter.words(x + cell, y, text, style, Kind::Text, w - 2.0 * cell, false);
    }
    if shown < lines.len() {
        let place = format!("{}-{}/{}", first + 1, first + shown, lines.len());
        let pw = painter.fonts.width(&place, Face::UI);
        painter.ui(x + w - pw - cell, y + h - line - 3.0, &place, theme.dim, pw);
    }
    painter.unclip();
}

/// The labels still possible, over the text or over each window.
fn labels(
    painter: &mut Painter,
    runtime: &Runtime,
    areas: &Areas,
    session: &crate::interaction::labels::LabelSession,
    motion: &dyn Fn(ViewId) -> Motion,
) {
    let theme = painter.theme;
    let line = painter.fonts.line;
    for (target, rest) in session.targets() {
        let Some(window) = areas.windows.iter().find(|w| w.view == target.view) else {
            continue;
        };
        let text = window.text;
        let scroll = motion(window.view).scroll;
        let (x, y, label) = match target.offset {
            Some(offset) => {
                let measure = super::text::Measured::new(painter.fonts);
                let place = screen::position_of(
                    runtime.app(),
                    target.view,
                    &measure,
                    window.width(),
                    window.rows + 1,
                    offset,
                );
                match place {
                    Some((row, across)) => (
                        text.x + across as f32 / UNIT,
                        text.y + row as f32 * line - scroll,
                        rest.to_owned(),
                    ),
                    None => continue,
                }
            }
            None => (text.x, text.y, format!(" {rest} ")),
        };
        if x >= text.right() || y >= text.bottom() {
            continue;
        }
        painter.clip_to(window.body);
        let w = painter.fonts.width(&label, Face::TEXT);
        let (fg, bg) = painter.colors(theme.label);
        painter.fill(Rect::new(x, y, w, line), bg.unwrap_or(fg), 3.0);
        let room = text.right() - x;
        painter.words(
            x,
            y,
            &label,
            without_bg(theme.label),
            Kind::Text,
            room,
            false,
        );
        painter.unclip();
    }
}
