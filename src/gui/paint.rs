//! The graphical screen: where everything goes, in pixels, and drawing it.
//!
//! Text rows are as high as the text font's line; the window tree is laid
//! out in columns and rows of that font and stretched to fill the editing
//! area. The parts around the text keep the terminal's order (tabs on top,
//! the status line and the message row below), with room around words,
//! rounded panels, thin separators and a gutter without rules.
use super::{
    render::{Atlas, Instance, OUTLINE, RECT, WAVE},
    text::{Face, Fonts, UNIT},
};
use crate::{
    application::{Area, Face as AppFace, ViewId},
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
    fn right(&self) -> f32 {
        self.x + self.w
    }
    fn bottom(&self) -> f32 {
        self.y + self.h
    }
    pub fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && x < self.right() && y >= self.y && y < self.bottom()
    }
}

pub struct Window {
    pub view: ViewId,
    pub area: Rect,
    pub header: Option<Rect>,
    /// Columns of line numbers; none without them.
    digits: Option<usize>,
    gutter: f32,
    pub text: Rect,
    /// Rows of text that fit.
    pub rows: u16,
}
impl Window {
    /// The text area's width in measured units.
    pub fn width(&self) -> usize {
        (self.text.w * UNIT) as usize
    }
}
pub struct Areas {
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
        let pad = (line * 0.3).round();
        let row = line + pad;
        let message = Rect::new(0.0, (height - row).max(0.0), width, row);
        let status = Rect::new(0.0, (message.y - row).max(0.0), width, row);
        let app = runtime.app();
        let options = app.options();
        let several = app.windows().views().len() > 1;
        let tab_bar = match options.choice(None, "tab-bar") {
            "on" => true,
            "off" => false,
            _ => !several,
        };
        let tabs = (tab_bar && height > 4.0 * row).then(|| Rect::new(0.0, 0.0, width, row));
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
        let titled = several && options.bool(None, "window-title");
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
                let header = (titled && area.h >= 2.0 * line).then_some(Rect { h: line, ..area });
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
                let flagged = document.is_some_and(|d| !app.flags(d).is_empty());
                // A fringe for flags, the numbers, and a column of room.
                let full = (digits + 2) as f32 * cell;
                let (digits, gutter) = if numbers && body.w >= full + 16.0 * cell {
                    (Some(digits), full)
                } else if flagged && body.w >= 18.0 * cell {
                    (None, 1.5 * cell)
                } else {
                    (None, 0.0)
                };
                let text = Rect {
                    x: body.x + gutter,
                    w: body.w - gutter,
                    ..body
                };
                Window {
                    view,
                    area,
                    header,
                    digits,
                    gutter,
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
    /// Rows the command line may use for candidates.
    pub fn list_rows(&self) -> usize {
        usize::from(self.cells.1.saturating_sub(2)).min(10)
    }
}

/// Tabs that fit across the tab bar: their documents, where they start and
/// end, and labels. Tabs drop from the left until the active one fits.
pub fn tab_items(runtime: &Runtime, fonts: &Fonts, width: f32) -> Vec<(DocumentId, Rect, String)> {
    let pad = fonts.cell;
    let tabs = content::tabs(runtime);
    let widths: Vec<f32> = tabs
        .iter()
        .map(|tab| {
            let dirty = if tab.dirty { 2.0 } else { 0.0 };
            (Cells.width_of(&tab.label) as f32 + dirty) * fonts.cell + 2.0 * pad
        })
        .collect();
    let active = tabs.iter().position(|tab| tab.active).unwrap_or(0);
    let mut first = 0;
    while first < active && widths[first..=active].iter().sum::<f32>() > width {
        first += 1;
    }
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

/// One frame being drawn.
pub struct Painter<'a> {
    pub fonts: &'a mut Fonts,
    pub atlas: &'a mut Atlas,
    pub out: Vec<Instance>,
    pub theme: &'a Theme,
    fg: [f32; 4],
    pub bg: [f32; 4],
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
        }
    }
    fn fill(&mut self, rect: Rect, color: [f32; 4], radius: f32) {
        if rect.w > 0.0 && rect.h > 0.0 && color[3] > 0.0 {
            self.out.push(Instance {
                rect: [rect.x, rect.y, rect.w, rect.h],
                uv: [0.0; 4],
                color,
                params: [RECT, radius, 0.0, 0.0],
            });
        }
    }
    fn outline(&mut self, rect: Rect, color: [f32; 4], radius: f32, thickness: f32) {
        self.out.push(Instance {
            rect: [rect.x, rect.y, rect.w, rect.h],
            uv: [0.0; 4],
            color,
            params: [OUTLINE, radius, thickness, 0.0],
        });
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
    /// Draws words in a style with their row's top at `y`, at most `width`
    /// wide; returns where they end. `wavy` underlines with a wave.
    #[allow(clippy::too_many_arguments)]
    fn words(
        &mut self,
        x: f32,
        y: f32,
        text: &str,
        style: Style,
        hint: bool,
        width: f32,
        wavy: bool,
    ) -> f32 {
        let face = Face {
            hint,
            bold: style.add_modifier.contains(Modifier::BOLD),
            italic: style.add_modifier.contains(Modifier::ITALIC),
        };
        let (fg, _) = self.colors(style);
        let baseline = y + self.fonts.baseline;
        let mut shown = text;
        while !shown.is_empty() && self.fonts.width(shown, face) > width + 0.5 {
            let mut end = shown.len() - 1;
            while !shown.is_char_boundary(end) {
                end -= 1;
            }
            shown = &shown[..end];
        }
        self.fonts
            .draw(self.atlas, &mut self.out, x, baseline, shown, face, fg);
        let drawn = self.fonts.width(shown, face);
        if style.add_modifier.contains(Modifier::UNDERLINED) && drawn > 0.0 {
            let color = rgba(style.underline_color, fg);
            if wavy {
                let h = (self.fonts.line - self.fonts.baseline).clamp(3.0, 5.0);
                self.out.push(Instance {
                    rect: [x, baseline + 1.0, drawn, h],
                    uv: [0.0; 4],
                    color,
                    params: [WAVE, 0.0, 1.2, 0.0],
                });
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
    /// Spans laid out in cells, as the parts around the text are, from `x`
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
            self.words(at, y, &span.text, style, false, w, false);
        }
    }
}

/// Draws the whole screen but the caret; returns the caret's rectangle,
/// after any text being composed, and whether it is a bar.
pub fn screen(
    painter: &mut Painter,
    runtime: &Runtime,
    areas: &Areas,
    highlighter: &mut Highlighter,
    preedit: &str,
) -> Result<Option<(Rect, bool)>, crate::application::Error> {
    let active = runtime.app().active_view();
    let bar =
        runtime.layer().is_some() || runtime.edit_mode() == crate::interaction::EditMode::Insert;
    let mut caret = None;
    if let Some(tabs) = areas.tabs {
        tab_bar(painter, runtime, tabs);
    }
    if areas.windows.is_empty() {
        splash(painter, areas.editor);
    }
    let mut texts = vec![];
    for window in &areas.windows {
        let text = {
            let measure = super::text::Measured::new(painter.fonts);
            screen::text(
                runtime,
                window.view,
                highlighter,
                &measure,
                window.width(),
                window.rows,
            )?
        };
        let current = Some(window.view) == active;
        if let Some(header) = window.header {
            title(painter, runtime, window.view, header, current);
        }
        if let Some(text) = &text {
            let document = runtime.app().view(window.view).map(|view| view.document_id);
            let relative = runtime.app().options().choice(document, "line-numbers") == "relative";
            let at = editor(painter, window, text, current, relative);
            if current {
                caret = at;
            }
        }
        texts.push((window.view, text));
    }
    separators(painter, areas);
    if let Some(Layer::Labels(session)) = runtime.layer() {
        labels(painter, runtime, areas, session);
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
    match runtime.layer() {
        Some(Layer::CommandLine(line)) => {
            let area = Rect {
                y: areas.message.y - below,
                h: areas.message.h + below,
                ..areas.message
            };
            caret = command_line(painter, area, line);
        }
        Some(Layer::Help(session)) => {
            caret = None;
            help(painter, areas.editor, session.lines());
        }
        Some(_) => caret = prompt,
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
        painter.words(at.x, at.y, preedit, style, false, width, false);
        at.x += width;
    }
    Ok(caret.map(|at| (at, bar)))
}

fn tab_bar(painter: &mut Painter, runtime: &Runtime, area: Rect) {
    let theme = painter.theme;
    let (_, bg) = painter.colors(theme.tabs);
    painter.fill(area, bg.unwrap_or(painter.bg), 0.0);
    let (line, pad) = (painter.fonts.line, painter.fonts.cell);
    let top = area.y + (area.h - line) / 2.0;
    let tabs = content::tabs(runtime);
    for (document, rect, label) in tab_items(runtime, painter.fonts, area.w) {
        let Some(tab) = tabs.iter().find(|tab| tab.document == document) else {
            continue;
        };
        let style = if tab.active {
            theme.tab_active
        } else {
            theme.tabs
        };
        if tab.active {
            let (_, bg) = painter.colors(style);
            let pill = Rect::new(rect.x + 2.0, area.y + 3.0, rect.w - 4.0, area.h - 6.0);
            painter.fill(pill, bg.unwrap_or(painter.bg), 6.0);
        }
        let end = painter.words(rect.x + pad, top, &label, style, false, area.w, false);
        if tab.dirty {
            let style = style.patch(theme.modified);
            painter.words(end + pad * 0.5, top, "●", style, false, pad * 2.0, false);
        }
    }
}

fn title(painter: &mut Painter, runtime: &Runtime, view: ViewId, area: Rect, current: bool) {
    let theme = painter.theme;
    let (_, bg) = painter.colors(theme.tabs);
    painter.fill(area, bg.unwrap_or(painter.bg), 0.0);
    let Some((path, dirty)) = content::title(runtime, view) else {
        return;
    };
    let style = if current {
        theme.tab_active
    } else {
        theme.tabs
    };
    let label = format!("{path}{}", if dirty { " ●" } else { "" });
    let cell = painter.fonts.cell;
    painter.words(
        area.x + cell,
        area.y,
        &label,
        style,
        false,
        area.w - cell,
        false,
    );
}

/// Side-by-side windows have a thin line between them.
fn separators(painter: &mut Painter, areas: &Areas) {
    let color = faded(rgba(painter.theme.gutter.fg, painter.fg), 0.5);
    for window in &areas.windows {
        let right = window.area.right();
        if right + 1.0 < areas.editor.right() {
            let x = (right + areas.scale.0 / 2.0).floor();
            painter.fill(Rect::new(x, window.area.y, 1.0, window.area.h), color, 0.0);
        }
    }
}

/// A window's text, gutter and caret line; returns the caret's rectangle.
fn editor(
    painter: &mut Painter,
    window: &Window,
    text: &TextFrame,
    current: bool,
    relative: bool,
) -> Option<Rect> {
    let theme = painter.theme;
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let area = window.text;
    let left = area.x - window.gutter;
    for (index, row) in text.rows.iter().enumerate() {
        let y = area.y + index as f32 * line;
        // Only the focused window marks the caret line.
        let caret_line = current && row.line == text.caret.0;
        let base = if caret_line {
            theme.text.patch(theme.cursor_line)
        } else {
            theme.text
        };
        if caret_line {
            let (_, bg) = painter.colors(theme.cursor_line);
            if let Some(bg) = bg {
                painter.fill(Rect::new(left, y, area.w + window.gutter, line), bg, 0.0);
            }
        }
        if let Some(digits) = window.digits.filter(|_| !row.continued) {
            let shown = if relative && row.line != text.caret.0 {
                row.line.abs_diff(text.caret.0)
            } else {
                row.line + 1
            };
            let number = format!("{shown:>digits$}");
            let style = if caret_line {
                theme.gutter_current
            } else {
                theme.gutter
            };
            let style = Style { bg: None, ..style };
            painter.words(
                left + cell,
                y,
                &number,
                style,
                false,
                digits as f32 * cell,
                false,
            );
        }
        // The flag sits in the fringe, before the numbers.
        if let Some(flag) = &row.flag
            && window.gutter > 0.0
        {
            let style = Style {
                bg: None,
                ..theme.gutter.patch(theme.sign(flag.face))
            };
            painter.words(left + cell * 0.25, y, &flag.sign, style, false, cell, false);
        }
        for span in &row.spans {
            let style = theme.span(span, base);
            let x = area.x + span.x as f32 / UNIT;
            let w = (span.width as f32 / UNIT).min(area.right() - x);
            if w <= 0.0 {
                break;
            }
            let (fg, bg) = painter.colors(style);
            let hint = span.font == Font::Hint;
            if span.inlay {
                // Hints sit in a soft pill, so they read as not the text.
                let pill = Rect::new(x + 1.0, y + 2.0, w - 2.0, line - 4.0);
                painter.fill(pill, faded(fg, 0.12), 4.0);
            } else if let Some(bg) =
                bg.filter(|bg| *bg != painter.colors(base).1.unwrap_or(painter.bg))
            {
                painter.fill(Rect::new(x, y, w, line), bg, 0.0);
            }
            let wavy = matches!(span.face, Some(AppFace::Note(_)));
            // A hint is lower and smaller; it shares the text's baseline.
            painter.words(x, y, &span.text, style, hint, w, wavy);
        }
        if let Some(ruler) = text.ruler {
            let x = area.x + ruler as f32 / UNIT;
            let color = rgba(theme.ruler.bg, faded(painter.fg, 0.15));
            painter.fill(Rect::new(x.floor(), y, 1.0, line), color, 0.0);
        }
    }
    text.cursor.map(|(x, y)| {
        Rect::new(
            area.x + x as f32 / UNIT,
            area.y + y as f32 * line,
            cell,
            line,
        )
    })
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
    if bar {
        painter.fill(
            Rect::new(at.x.floor(), at.y + 1.0, 2.0, at.h - 2.0),
            color,
            0.0,
        );
    } else {
        painter.fill(at, faded(color, 0.45), 2.0);
        painter.outline(at, color, 2.0, 1.0);
    }
}

fn splash(painter: &mut Painter, area: Rect) {
    let theme = painter.theme;
    let lines: [(&str, &str); 5] = [
        (":open", "Open a file"),
        ("<space>f", "Find a project file"),
        (":enew", "New document"),
        (":", "Run any command"),
        ("F1", "Help"),
    ];
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let (w, h) = (32.0 * cell, (lines.len() + 2) as f32 * line);
    if area.h < h || area.w < w {
        return;
    }
    let (x, y) = (area.x + (area.w - w) / 2.0, area.y + (area.h - h) / 2.0);
    painter.words(x + 13.0 * cell, y, "soda", theme.title, false, w, false);
    for (index, (key, doc)) in lines.iter().enumerate() {
        let y = y + (2 + index) as f32 * line;
        painter.words(x, y, &format!("{key:>10}"), theme.key, false, w, false);
        painter.words(x + 12.0 * cell, y, doc, theme.dim, false, w, false);
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
    let (cell, line) = (painter.fonts.cell, painter.fonts.line);
    let top = area.y + (area.h - line) / 2.0;
    let status = content::status(runtime, text);
    let badge = match status.mode {
        content::Mode::Normal => theme.mode_normal,
        content::Mode::Insert => theme.mode_insert,
        content::Mode::Beacon => theme.mode_visual,
        content::Mode::Prompt(_) => theme.mode_prompt,
    };
    let label = status.mode.label();
    let width = painter.fonts.width(label, Face::TEXT) + 2.0 * cell;
    let (_, badge_bg) = painter.colors(badge);
    let pill = Rect::new(cell * 0.5, area.y + 3.0, width, area.h - 6.0);
    painter.fill(pill, badge_bg.unwrap_or(painter.fg), 6.0);
    painter.words(
        pill.x + cell,
        top,
        label,
        Style { bg: None, ..badge },
        false,
        width,
        false,
    );
    // The right side: segments, then the caret's place.
    let mut right: Vec<(String, Style)> = status
        .segments
        .iter()
        .map(|(words, role)| (words.clone(), role_style(*role, theme)))
        .collect();
    if let Some((line, column, percent)) = status.place {
        right.push((format!("{line}:{column}"), theme.status_strong));
        right.push((format!("{percent:>3}%"), Style::new()));
    }
    let gap = 2.0 * cell;
    let widths: Vec<f32> = right
        .iter()
        .map(|(words, _)| painter.fonts.width(words, Face::TEXT))
        .collect();
    let total: f32 = widths.iter().sum::<f32>() + gap * right.len() as f32;
    let mut x = area.right() - total;
    for ((words, style), w) in right.iter().zip(&widths) {
        let style = theme.status.patch(*style);
        painter.words(x, top, words, Style { bg: None, ..style }, false, *w, false);
        x += w + gap;
    }
    if let Some(document) = status.document {
        let x = pill.right() + cell;
        let room = (area.right() - total - x - gap).max(0.0);
        let mut marks = String::new();
        if document.dirty {
            marks.push_str(" [+]");
        }
        if document.saving {
            marks.push_str(" saving…");
        }
        let room_cells = (room / cell) as usize;
        let path = tail(
            &document.path,
            room_cells.saturating_sub(marks.chars().count()),
        );
        let style = Style {
            bg: None,
            ..theme.status.patch(theme.status_strong)
        };
        let end = painter.words(x, top, &path, style, false, room, false);
        let style = Style {
            bg: None,
            ..theme.status.patch(theme.modified)
        };
        painter.words(end, top, &marks, style, false, room, false);
    }
}

/// The end of `text` within `width` columns, marked with `…` when cut.
fn tail(text: &str, width: usize) -> String {
    if Cells.width_of(text) <= width {
        return text.to_owned();
    }
    let mut kept = vec![];
    let mut used = 1;
    for ch in text.chars().rev() {
        let w = Cells.width_of(ch.encode_utf8(&mut [0; 4]));
        if used + w > width {
            break;
        }
        used += w;
        kept.push(ch);
    }
    std::iter::once('…').chain(kept.into_iter().rev()).collect()
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
    let top = area.y + (area.h - line) / 2.0;
    let x = cell * 0.5;
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
            let words = screen::plain(words, 0, columns);
            painter.words(
                x,
                top,
                &words,
                Style { bg: None, ..style },
                false,
                area.w,
                false,
            );
            None
        }
    }
}

/// A rounded panel with a soft edge, for what floats over the text.
fn panel(painter: &mut Painter, area: Rect) {
    let theme = painter.theme;
    let (_, bg) = painter.colors(theme.float);
    let border = rgba(theme.float_border.fg, faded(painter.fg, 0.3));
    painter.fill(
        Rect::new(area.x + 1.0, area.y + 3.0, area.w, area.h),
        [0.0, 0.0, 0.0, 0.18],
        8.0,
    );
    painter.fill(area, bg.unwrap_or(painter.bg), 8.0);
    painter.outline(area, faded(border, 0.6), 8.0, 1.0);
}

/// The command line: its input on the bottom row, the candidates above.
fn command_line(painter: &mut Painter, area: Rect, line: &CommandLine) -> Option<Rect> {
    let theme = painter.theme;
    let (cell, row_h) = (painter.fonts.cell, painter.fonts.line);
    let rows = line.rows();
    let list = line.list();
    // The input sits in the middle of the message row.
    // The message row is a line and its rounded room, as `Areas` makes it.
    let message = row_h + (row_h * 0.3).round();
    let input_top = area.bottom() - message / 2.0 - row_h / 2.0;
    painter.fill(area, painter.bg, 0.0);
    // What the line is for, at the right: an error, else the command's
    // slots and any question, then progress and the count.
    let mut info = vec![];
    if let Some(error) = line.error() {
        info.push((error.to_owned(), theme.error));
    } else if let Some(note) = line.note() {
        info.push((note.to_owned(), theme.modified));
    }
    if line.loading() {
        info.push(("loading…".into(), theme.dim));
    }
    if let Some(index) = list.index(rows) {
        info.push((format!("{}/{}", index + 1, rows.len()), theme.dim));
    }
    if line.error().is_none() {
        let heading = line.heading().unwrap_or_else(|| "command".into());
        let width: usize = info
            .iter()
            .map(|(t, _)| Cells.width_of(t) + 3)
            .sum::<usize>()
            + heading.len();
        if (width as f32) * cell < area.w / 2.0 {
            info.insert(0, (heading, theme.dim));
        }
    }
    let joined: Vec<String> = info.iter().map(|(t, _)| t.clone()).collect();
    let info_width = (Cells.width_of(&joined.join(" · ")) as f32 + 1.0) * cell;
    let info_width = info_width.min(area.w / 2.0);
    let x = cell * 0.5;
    let field = (area.w - info_width - x).max(0.0);
    let columns = (field / cell) as usize;
    let (input, column) = screen::prompt_row(&line.field(), columns);
    painter.cell_spans(x, input_top, x + field, &input, theme.text);
    let mut ix = area.right() - info_width;
    for (index, (words, style)) in info.iter().enumerate() {
        if index > 0 {
            ix = painter.words(ix, input_top, " · ", theme.dim, false, area.w, false);
        }
        ix = painter.words(
            ix,
            input_top,
            words,
            Style { bg: None, ..*style },
            false,
            area.w,
            false,
        );
    }
    // Candidates fill the rows above the status line's old place.
    // Whole rows above the message row; rounding, not flooring, so that
    // a fraction of a pixel lost in the sums does not lose a row.
    let count = ((area.h - message) / row_h).round().max(0.0) as usize;
    if count > 0 {
        let list_area = Rect::new(0.0, area.y, area.w, count as f32 * row_h);
        let (_, bg) = painter.colors(theme.float);
        painter.fill(list_area, bg.unwrap_or(painter.bg), 0.0);
        let selected = list.selected();
        for offset in 0..count {
            let Some(row) = rows.get(list.first_visible() + offset) else {
                break;
            };
            let y = list_area.y + offset as f32 * row_h;
            let chosen = selected == Some(row.candidate.key);
            let base = if chosen && line.enter_selects() {
                let (_, bg) = painter.colors(theme.candidate_selected);
                let band = Rect::new(4.0, y, area.w - 8.0, row_h);
                painter.fill(band, bg.unwrap_or(painter.fg), 4.0);
                theme.text.patch(theme.candidate_selected)
            } else {
                theme.text
            };
            if chosen {
                let marker = rgba(theme.marker.fg, painter.fg);
                painter.fill(Rect::new(4.0, y + 3.0, 3.0, row_h - 6.0), marker, 1.5);
            }
            let width = ((area.w - 2.0 * cell) / cell) as usize;
            let label = screen::candidate_row(row, None, row.candidate.payload.detail, width);
            let base = Style { bg: None, ..base };
            painter.cell_spans(2.0 * cell, y, area.right(), &label, base);
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
    painter.words(
        inner.x + cell,
        inner.y + line * 0.25,
        "Help · Esc closes",
        theme.title,
        false,
        inner.w,
        false,
    );
    let rows = ((inner.h - line * 1.5) / line).floor().max(0.0) as usize;
    let columns = ((inner.w - 2.0 * cell) / cell) as usize;
    for (index, text) in lines.enumerate().take(rows) {
        let y = inner.y + line * 1.25 + index as f32 * line;
        let text = screen::plain(text, 0, columns);
        let style = Style {
            bg: None,
            ..theme.panel
        };
        painter.words(
            inner.x + cell,
            y,
            &text,
            style,
            false,
            inner.w - 2.0 * cell,
            false,
        );
    }
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
        .map(|(k, _)| k.chars().count())
        .max()
        .unwrap_or(0);
    let doc_width = entries
        .iter()
        .map(|(_, d)| d.chars().count())
        .max()
        .unwrap_or(0);
    let column = (key_width + 2 + doc_width).min(56);
    let area = areas.editor;
    let max_rows = ((area.h / line) as usize).saturating_sub(3).clamp(1, 12);
    let columns = entries.len().div_ceil(max_rows);
    let rows = entries.len().div_ceil(columns);
    let room = ((area.w / cell) as usize).saturating_sub(4) / columns;
    let column = column.min(room.saturating_sub(2));
    if column <= key_width + 2 {
        return;
    }
    let w = (columns * (column + 2) + 2) as f32 * cell;
    let h = (rows as f32 + 1.5) * line;
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
    let title = runtime.pending_keys().unwrap_or_default();
    painter.words(
        rect.x + cell,
        rect.y + line * 0.2,
        &title,
        theme.title,
        false,
        w,
        false,
    );
    for (index, (key, doc)) in entries.iter().enumerate() {
        let x = rect.x + cell + ((index / rows) * (column + 2)) as f32 * cell;
        let y = rect.y + line * 1.1 + (index % rows) as f32 * line;
        let style = Style {
            bg: None,
            ..theme.key
        };
        painter.words(x, y, &format!("{key:>key_width$}"), style, false, w, false);
        let doc = screen::plain(doc, 0, column - key_width - 2);
        let style = Style {
            bg: None,
            ..theme.panel
        };
        painter.words(
            x + (key_width + 2) as f32 * cell,
            y,
            &doc,
            style,
            false,
            w,
            false,
        );
    }
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
        .map(|r| Cells.width_of(&r.label))
        .max()
        .unwrap_or(0);
    let detail = popup
        .rows
        .iter()
        .map(|r| Cells.width_of(&r.detail))
        .max()
        .unwrap_or(0);
    let w = ((label + detail + 4) as f32 * cell).min(area.w);
    let (above, below) = (caret.y - area.y, area.bottom() - caret.bottom());
    let wanted = popup.rows.len() as f32 * line + 8.0;
    let fits_below = below >= wanted || below >= above;
    let h = wanted.min(if fits_below { below } else { above } - 4.0);
    if h < line + 8.0 {
        return;
    }
    let x = (caret.x - (popup.typed as f32 + 1.0) * cell)
        .max(area.x)
        .min(area.right() - w);
    let y = if fits_below {
        caret.bottom() + 2.0
    } else {
        caret.y - h - 2.0
    };
    let rect = Rect::new(x, y, w, h);
    panel(painter, rect);
    let visible = ((h - 8.0) / line).floor() as usize;
    let name = ((w / cell) as usize).saturating_sub(detail + 3);
    for (row, candidate) in popup.rows.iter().take(visible).enumerate() {
        let ry = y + 4.0 + row as f32 * line;
        let base = if candidate.selected {
            let (_, bg) = painter.colors(theme.candidate_selected);
            painter.fill(
                Rect::new(x + 3.0, ry, w - 6.0, line),
                bg.unwrap_or(painter.fg),
                4.0,
            );
            theme.float.patch(theme.candidate_selected)
        } else {
            theme.float
        };
        let base = Style { bg: None, ..base };
        let shown = screen::plain(&candidate.label, 0, name);
        painter.words(x + cell, ry, &shown, base, false, name as f32 * cell, false);
        for range in &candidate.matched {
            let column = Cells.width_of(&candidate.label[..range.start]);
            if column < name {
                let matched = &candidate.label[range.clone()];
                painter.words(
                    x + cell + column as f32 * cell,
                    ry,
                    matched,
                    base.patch(theme.key),
                    false,
                    (name - column) as f32 * cell,
                    false,
                );
            }
        }
        let dx = x + w - (detail as f32 + 1.0) * cell;
        painter.words(
            dx,
            ry,
            &candidate.detail,
            base.patch(theme.detail),
            false,
            detail as f32 * cell,
            false,
        );
    }
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
    let h = (lines.len() as f32 * line + 8.0).min(area.bottom() - list.y);
    if h < line + 8.0 {
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
        list.right() + 4.0
    } else {
        list.x - w - 4.0
    };
    panel(painter, Rect::new(x, list.y, w, h));
    let shown = ((h - 8.0) / line).floor() as usize;
    for (row, text) in lines.iter().take(shown).enumerate() {
        let text = screen::plain(text, 0, inner);
        let style = Style {
            bg: None,
            ..theme.float
        };
        painter.words(
            x + cell,
            list.y + 4.0 + row as f32 * line,
            &text,
            style,
            false,
            w,
            false,
        );
    }
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
    let room = ((above.max(below) - 8.0) / line).floor().max(0.0) as usize;
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
    let (w, h) = ((inner + 2) as f32 * cell, shown as f32 * line + 8.0);
    let y = if below >= above {
        caret.bottom() + 2.0
    } else {
        caret.y - h - 2.0
    };
    let x = caret.x.min(area.right() - w).max(area.x);
    panel(painter, Rect::new(x, y, w, h));
    for (row, text) in lines[first..first + shown].iter().enumerate() {
        let text = screen::plain(text, 0, inner);
        let style = Style {
            bg: None,
            ..theme.float
        };
        painter.words(
            x + cell,
            y + 4.0 + row as f32 * line,
            &text,
            style,
            false,
            w,
            false,
        );
    }
    if shown < lines.len() {
        let place = format!("{}-{}/{}", first + 1, first + shown, lines.len());
        let pw = painter.fonts.width(&place, Face::TEXT);
        painter.words(
            x + w - pw - cell,
            y + h - line,
            &place,
            theme.dim,
            false,
            pw,
            false,
        );
    }
}

/// The labels still possible, over the text or over each window.
fn labels(
    painter: &mut Painter,
    runtime: &Runtime,
    areas: &Areas,
    session: &crate::interaction::labels::LabelSession,
) {
    let theme = painter.theme;
    let line = painter.fonts.line;
    for (target, rest) in session.targets() {
        let Some(window) = areas.windows.iter().find(|w| w.view == target.view) else {
            continue;
        };
        let text = window.text;
        let (x, y, label) = match target.offset {
            Some(offset) => {
                let measure = super::text::Measured::new(painter.fonts);
                let place = screen::position_of(
                    runtime.app(),
                    target.view,
                    &measure,
                    window.width(),
                    window.rows,
                    offset,
                );
                match place {
                    Some((row, across)) if row < usize::from(window.rows) => (
                        text.x + across as f32 / UNIT,
                        text.y + row as f32 * line,
                        rest.to_owned(),
                    ),
                    _ => continue,
                }
            }
            None => (text.x, text.y, format!(" {rest} ")),
        };
        if x >= text.right() {
            continue;
        }
        let w = painter.fonts.width(&label, Face::TEXT);
        let (fg, bg) = painter.colors(theme.label);
        painter.fill(Rect::new(x, y, w, line), bg.unwrap_or(fg), 3.0);
        painter.words(
            x,
            y,
            &label,
            Style {
                bg: None,
                ..theme.label
            },
            false,
            text.right() - x,
            false,
        );
    }
}
