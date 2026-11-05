//! The terminal's screen, in cells: buffer tabs, the editing area with its line number
//! gutter, the status line and the message row, with the command line panel,
//! key hints and help drawn over the editing area. Everything here reads
//! state; viewport changes happen before drawing.
use crate::{
    application::{Area, ViewId},
    interaction::{CommandLine, Layer},
    runtime::Runtime,
    screen::{
        self, Cells, Highlighter, Span, TextFrame, Theme,
        content::{self, Message, Role},
    },
};
use ratatui::{
    buffer::Buffer,
    layout::{Position, Rect},
    style::Style,
    text::{Line, Span as Text},
    widgets::{Block, BorderType, Clear, Widget},
};

/// One window: its row of tabs, then the line number gutter and the text.
pub(super) struct Window {
    pub view: ViewId,
    pub area: Rect,
    /// The window's row of tabs, as `tab-line-mode`'s.
    pub header: Option<Rect>,
    pub gutter: u16,
    pub text: Rect,
}
/// Screen regions for one terminal size.
pub(super) struct Areas {
    /// The row of tabs while no window is open, for the splash.
    pub tabs: Option<Rect>,
    /// Every window together.
    pub editor: Rect,
    pub windows: Vec<Window>,
    pub status: Option<Rect>,
    pub message: Rect,
}
impl Areas {
    pub fn new(runtime: &Runtime, width: u16, height: u16) -> Self {
        let message = Rect::new(0, height.saturating_sub(1), width, height.min(1));
        let status = (height >= 2).then(|| Rect::new(0, height - 2, width, 1));
        let options = runtime.app().options();
        let tab_bar = options.bool(None, "tab-bar");
        let alone = runtime.app().windows().is_empty();
        let tabs = (height >= 4 && tab_bar && alone).then(|| Rect::new(0, 0, width, 1));
        let top = u16::from(tabs.is_some());
        let bottom = height.saturating_sub(if status.is_some() { 2 } else { 1 });
        let editor = Rect::new(0, top, width, bottom.saturating_sub(top));
        let app = runtime.app();
        let layout = app.windows().layout(Area {
            x: editor.x,
            y: editor.y,
            width: editor.width,
            height: editor.height,
        });
        let windows = layout
            .into_iter()
            .map(|(view, area)| {
                let area = Rect::new(area.x, area.y, area.width, area.height);
                let header = (tab_bar && area.height >= 2).then_some(Rect { height: 1, ..area });
                let body = match header {
                    Some(_) => Rect {
                        y: area.y + 1,
                        height: area.height - 1,
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
                let digits = lines.max(1).ilog10() as u16 + 1;
                // ` 123 │ ` keeps numbers right-aligned with a separator.
                let gutter = digits.max(3) + 4;
                let numbers = app.options().choice(document, "line-numbers") != "off";
                // Without numbers, flags keep a column of their own.
                let flagged = document.is_some_and(|d| !app.flags(d).is_empty());
                let gutter = if numbers && body.width >= gutter + 16 {
                    gutter
                } else if flagged && body.width >= 18 {
                    2
                } else {
                    0
                };
                Window {
                    view,
                    area,
                    header,
                    gutter,
                    text: Rect {
                        x: body.x + gutter,
                        width: body.width - gutter,
                        ..body
                    },
                }
            })
            .collect();
        Self {
            tabs,
            editor,
            windows,
            status,
            message,
        }
    }
    pub fn active(&self, runtime: &Runtime) -> Option<&Window> {
        let active = runtime.app().active_view()?;
        self.windows.iter().find(|window| window.view == active)
    }
    /// The active window's text, or the whole editing area without one.
    pub fn text(&self, runtime: &Runtime) -> Rect {
        self.active(runtime)
            .map_or(self.editor, |window| window.text)
    }
    pub fn window_at(&self, x: u16, y: u16) -> Option<&Window> {
        self.windows
            .iter()
            .find(|window| window.area.contains(Position::new(x, y)))
    }
    /// Rows the command line may use for candidates, keeping a line of
    /// text above the status line it pushes up.
    pub fn list_rows(&self) -> usize {
        usize::from(self.editor.height.saturating_sub(2)).min(10)
    }
}

/// Rows the layout reported to Runtime last.
#[derive(PartialEq)]
struct Geometry {
    editor: u16,
    list: usize,
    page: u16,
    windows: Vec<(ViewId, usize)>,
}
/// Presentation state of the terminal's screen: highlighting caches and
/// the theme.
pub(super) struct Presenter {
    highlighter: Highlighter,
    theme: Theme,
    theme_key: Option<(String, u64)>,
    geometry: Option<Geometry>,
}
impl Presenter {
    pub fn new() -> Self {
        Self {
            // Highlighting a frame scans for at most this long, so a jump
            // deep into a large file stays responsive while it catches up.
            highlighter: Highlighter::with_budget(std::time::Duration::from_millis(12)),
            theme: Theme::build(crate::application::themes::DEFAULT, &Default::default()),
            theme_key: None,
            geometry: None,
        }
    }
    /// Tells Runtime the rows a screen of this size gives the editing
    /// area, the windows and the command line's candidates, which paging,
    /// side windows and display rules use. Call it before handling input
    /// and before drawing.
    pub fn measure(&mut self, runtime: &mut Runtime, width: u16, height: u16) {
        let areas = Areas::new(runtime, width, height);
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
        let areas = Areas::new(runtime, width, height);
        if let Some(window) = areas.active(runtime) {
            let (view, text) = (window.view, window.text);
            screen::follow(runtime, view, &Cells, text.width.into(), text.height)?;
        }
        self.highlighter.retain(runtime.app());
        let app = runtime.app();
        let key = (
            screen::theme_name(runtime).to_owned(),
            app.faces().revision(),
        );
        if self.theme_key.as_ref() != Some(&key) {
            self.theme = Theme::build(&key.0, app.faces());
            self.theme_key = Some(key);
        }
        Ok(())
    }
    /// Draws a frame over the whole of `buffer`, whose area is the screen;
    /// returns where the caret shows, if it does.
    pub fn render(
        &mut self,
        runtime: &Runtime,
        buffer: &mut Buffer,
    ) -> Result<Option<(u16, u16)>, crate::application::Error> {
        let area = buffer.area;
        // The gutter widens with the line count, so measure again.
        let areas = Areas::new(runtime, area.width, area.height);
        let texts = frames(runtime, &mut self.highlighter, &areas)?;
        Ok(render(buffer, runtime, &self.theme, &areas, &texts))
    }
    /// Whether the last frame left lines unhighlighted; draw again soon.
    pub fn take_pending(&mut self) -> bool {
        self.highlighter.take_pending()
    }
}

/// The text of every window.
pub(super) fn frames(
    runtime: &Runtime,
    highlighter: &mut Highlighter,
    areas: &Areas,
) -> Result<Vec<Option<TextFrame>>, crate::application::Error> {
    areas
        .windows
        .iter()
        .map(|window| {
            let (width, rows) = (window.text.width.into(), window.text.height);
            screen::text(
                runtime,
                window.view,
                highlighter,
                &Cells,
                width,
                0,
                None,
                rows,
            )
        })
        .collect()
}

/// Draws the screen into `buf`; returns where the caret shows, if it does.
pub(super) fn render(
    buf: &mut Buffer,
    runtime: &Runtime,
    theme: &Theme,
    areas: &Areas,
    texts: &[Option<TextFrame>],
) -> Option<(u16, u16)> {
    let screen = buf.area;
    buf.set_style(screen, theme.text);
    if let Some(area) = areas.tabs {
        tabs(buf, area, runtime, None, true, theme);
    }
    let active = runtime.app().active_view();
    let mut cursor = None;
    if areas.windows.is_empty() {
        splash(buf, areas.editor, &content::splash(runtime), theme);
    } else {
        separators(buf, areas, theme);
    }
    for (window, text) in areas.windows.iter().zip(texts) {
        let current = Some(window.view) == active;
        if let Some(header) = window.header {
            tabs(buf, header, runtime, Some(window.view), current, theme);
        }
        if let Some(text) = text {
            let document = runtime.app().view(window.view).map(|view| view.document_id);
            let relative = runtime.app().options().choice(document, "line-numbers") == "relative";
            let position = editor(buf, window, text, theme, current, relative);
            if current {
                cursor = position;
            }
        }
    }
    if let Some(Layer::Labels(session)) = runtime.layer() {
        labels(buf, areas, runtime, session, theme);
    }
    let text = areas
        .windows
        .iter()
        .zip(texts)
        .find(|(window, _)| Some(window.view) == active)
        .and_then(|(_, text)| text.as_ref());
    // The command line grows the rows below the status line upward, over
    // the editing area, so its candidates sit under its input.
    let below = match runtime.layer() {
        Some(Layer::CommandLine(line)) if line.completes() => areas.list_rows() as u16,
        _ => 0,
    };
    if let Some(area) = areas.status {
        status(
            buf,
            Rect {
                y: area.y - below,
                ..area
            },
            runtime,
            theme,
            text,
        );
    }
    let prompt = message(buf, areas.message, runtime, theme, text);
    match runtime.layer() {
        Some(Layer::CommandLine(line)) => {
            let area = Rect {
                y: areas.message.y - below,
                height: below + 1,
                ..areas.message
            };
            cursor = command_line(buf, area, line, theme);
        }
        Some(Layer::Help(session)) => {
            cursor = None;
            popup(buf, areas.editor, " Help · Esc closes ", theme);
            let inner = inset(inset(areas.editor));
            let inner = Rect::new(inner.x, inner.y - 1, inner.width, inner.height + 2);
            for (y, line) in session.lines().enumerate().take(inner.height.into()) {
                let line = screen::plain(line, 0, inner.width.into());
                buf.set_stringn(
                    inner.x,
                    inner.y + y as u16,
                    line,
                    inner.width.into(),
                    theme.panel,
                );
            }
        }
        Some(_) => cursor = prompt,
        None => key_hints(buf, areas, runtime, theme),
    }
    if let (Some(position), None, Some(popup)) =
        (cursor, runtime.layer(), runtime.completion_popup())
    {
        completions(buf, areas, position, popup, theme);
    }
    if let (None, Some(words)) = (runtime.layer(), runtime.popup()) {
        floating(buf, areas.editor, cursor, words, runtime, theme);
    }
    cursor.map(|position| (position.x, position.y))
}

/// Text in a box by the caret, on whichever side has more room. Text that
/// does not fit scrolls, with its place shown on the border.
fn floating(
    buf: &mut Buffer,
    area: Rect,
    caret: Option<Position>,
    words: &str,
    runtime: &Runtime,
    theme: &Theme,
) {
    let widest = area.width.saturating_sub(4).min(80);
    if widest < 8 || area.height < 3 {
        return;
    }
    let lines = screen::wrap(words, usize::from(widest));
    let caret = caret.unwrap_or(Position::new(area.x, area.y));
    let (above, below) = (caret.y - area.y, area.bottom().saturating_sub(caret.y + 1));
    let room = above.max(below).saturating_sub(2);
    if room == 0 {
        return;
    }
    let shown = lines.len().min(usize::from(room));
    let first = runtime.popup_scroll(shown, lines.len());
    let inner = lines
        .iter()
        .map(|line| screen::plain(line, 0, usize::from(widest)).chars().count())
        .max()
        .unwrap_or(0) as u16;
    let (wide, high) = (inner + 4, shown as u16 + 2);
    let y = if below >= above {
        caret.y + 1
    } else {
        caret.y - high
    };
    let x = caret.x.min(area.right().saturating_sub(wide)).max(area.x);
    float_box(buf, Rect::new(x, y, wide, high), theme);
    for (row, line) in lines[first..first + shown].iter().enumerate() {
        buf.set_stringn(
            x + 2,
            y + 1 + row as u16,
            screen::plain(line, 0, usize::from(inner)),
            usize::from(inner),
            theme.float,
        );
    }
    if shown < lines.len() {
        let place = format!(" {}-{}/{} ", first + 1, first + shown, lines.len());
        let at = (x + wide).saturating_sub(place.len() as u16 + 1).max(x);
        buf.set_stringn(
            at,
            y + high - 1,
            place,
            usize::from(wide),
            theme.float_border,
        );
    }
}

/// The candidates, under the word at the caret, or above it near the bottom.
fn completions(
    buf: &mut Buffer,
    areas: &Areas,
    caret: Position,
    popup: crate::interaction::completion::Popup,
    theme: &Theme,
) {
    let width = |text: &str| screen::plain(text, 0, usize::MAX >> 1).chars().count();
    let label = popup
        .rows
        .iter()
        .map(|r| width(&r.label))
        .max()
        .unwrap_or(0);
    let detail = popup.rows.iter().map(|r| r.detail.len()).max().unwrap_or(0);
    let area = areas.editor;
    // Border, marker and a gap on the left; the same on the right, less the
    // marker, so the labels line up with the word being typed.
    let wide = ((label + detail + 5) as u16).min(area.width);
    let (above, below) = (caret.y - area.y, area.bottom().saturating_sub(caret.y + 1));
    let wanted = popup.rows.len() as u16 + 2;
    let fits_below = below >= wanted || below >= above;
    let high = wanted.min(if fits_below { below } else { above });
    if high < 3 {
        return;
    }
    let x = caret
        .x
        .saturating_sub(popup.typed as u16 + 2)
        .max(area.x)
        .min(area.right().saturating_sub(wide));
    let y = if fits_below {
        caret.y + 1
    } else {
        caret.y - high
    };
    float_box(buf, Rect::new(x, y, wide, high), theme);
    let name = wide.saturating_sub(detail as u16 + 5) as usize;
    for (row, candidate) in popup.rows.iter().take(usize::from(high - 2)).enumerate() {
        let y = y + 1 + row as u16;
        let style = if candidate.selected {
            let band = Rect::new(x + 1, y, wide - 2, 1);
            buf.set_style(band, theme.candidate_selected);
            buf.set_string(x + 1, y, "▌", theme.marker.patch(theme.candidate_selected));
            theme.float.patch(theme.candidate_selected)
        } else {
            theme.float
        };
        buf.set_stringn(x + 2, y, &candidate.label, name, style);
        for range in &candidate.matched {
            let column = width(&candidate.label[..range.start]);
            if column < name {
                let matched = &candidate.label[range.clone()];
                buf.set_stringn(x + 2 + column as u16, y, matched, 1, style.patch(theme.key));
            }
        }
        buf.set_stringn(
            x + wide - detail as u16 - 2,
            y,
            &candidate.detail,
            detail,
            style.patch(theme.detail),
        );
    }
    if let Some(doc) = popup.rows.iter().find(|r| r.selected && !r.doc.is_empty()) {
        documentation(buf, area, Rect::new(x, y, wide, high), &doc.doc, theme);
    }
}

/// The selected candidate's documentation, in a box beside the list on
/// whichever side has more room, from the list's top row down.
fn documentation(buf: &mut Buffer, area: Rect, list: Rect, doc: &str, theme: &Theme) {
    let (left, right) = (list.x - area.x, area.right().saturating_sub(list.right()));
    let room = left.max(right);
    if room < 16 {
        return;
    }
    let widest = (room - 4).min(72);
    let lines = screen::wrap(doc.trim_end(), usize::from(widest));
    let high = (lines.len() as u16 + 2).min(area.bottom().saturating_sub(list.y));
    if high < 3 {
        return;
    }
    let inner = lines
        .iter()
        .map(|line| screen::plain(line, 0, usize::from(widest)).chars().count())
        .max()
        .unwrap_or(0) as u16;
    let wide = inner + 4;
    let x = if right >= left {
        list.right()
    } else {
        list.x - wide
    };
    float_box(buf, Rect::new(x, list.y, wide, high), theme);
    for (row, line) in lines.iter().take(usize::from(high - 2)).enumerate() {
        buf.set_stringn(
            x + 2,
            list.y + 1 + row as u16,
            screen::plain(line, 0, usize::from(inner)),
            usize::from(inner),
            theme.float,
        );
    }
}

/// Draws the labels still possible over the text, or over each window.
fn labels(
    buf: &mut Buffer,
    areas: &Areas,
    runtime: &Runtime,
    session: &crate::interaction::labels::LabelSession,
    theme: &Theme,
) {
    for (target, rest) in session.targets() {
        let Some(window) = areas.windows.iter().find(|w| w.view == target.view) else {
            continue;
        };
        let text = window.text;
        let (row, column, label) = match target.offset {
            Some(offset) => {
                let cells = &screen::Cells;
                let width = text.width.into();
                match screen::position_of(
                    runtime.app(),
                    target.view,
                    cells,
                    width,
                    text.height,
                    offset,
                ) {
                    Some((row, column)) => (row, column, rest.to_owned()),
                    None => continue,
                }
            }
            None => (0, 0, format!(" {rest} ")),
        };
        if row >= usize::from(text.height) || column >= usize::from(text.width) {
            continue;
        }
        let x = text.x + column as u16;
        let width = usize::from(text.right() - x);
        buf.set_stringn(x, text.y + row as u16, label, width, theme.label);
    }
}
/// Draws spans placed from `x`, each text followed by blanks to its width,
/// within `width` cells.
fn spans(buf: &mut Buffer, x: u16, y: u16, width: u16, spans: &[Span], base: Style, theme: &Theme) {
    let right = x.saturating_add(width);
    for span in spans {
        let style = theme.span(span, base);
        let start = u16::try_from(span.x).map_or(right, |at| x.saturating_add(at));
        if start >= right {
            break;
        }
        let room = usize::from(right - start).min(span.width);
        buf.set_stringn(start, y, screen::padded(span), room, style);
    }
}

/// Side-by-side windows leave a column between them.
fn separators(buf: &mut Buffer, areas: &Areas, theme: &Theme) {
    for y in areas.editor.top()..areas.editor.bottom() {
        for x in areas.editor.left()..areas.editor.right() {
            if areas.window_at(x, y).is_none() {
                buf[(x, y)].set_symbol("│").set_style(theme.gutter);
            }
        }
    }
}
fn editor(
    buf: &mut Buffer,
    window: &Window,
    text: &TextFrame,
    theme: &Theme,
    current: bool,
    relative: bool,
) -> Option<Position> {
    let area = window.text;
    let digits = usize::from(window.gutter.saturating_sub(4));
    let left = area.x - window.gutter;
    for (index, row) in text.rows.iter().enumerate() {
        let y = area.y + index as u16;
        // Only the focused window marks the caret line.
        let caret_line = current && row.line == text.caret.0;
        let base = if caret_line {
            theme.text.patch(theme.cursor_line)
        } else {
            theme.text
        };
        if caret_line {
            buf.set_style(Rect::new(left, y, area.width + window.gutter, 1), base);
        }
        if window.gutter > 0 {
            let style = if caret_line {
                theme.gutter_current
            } else {
                theme.gutter
            };
            // Relative numbers count from the caret line, which keeps its own.
            let shown = if relative && row.line != text.caret.0 {
                row.line.abs_diff(text.caret.0)
            } else {
                row.line + 1
            };
            let number = if window.gutter == 2 {
                "  ".to_owned()
            } else if row.continued {
                format!(" {:>digits$} │ ", "")
            } else {
                format!(" {shown:>digits$} │ ")
            };
            buf.set_stringn(left, y, &number, window.gutter.into(), style);
            // The flag takes the first cell, before the number.
            if let Some(flag) = &row.flag {
                let style = style.patch(theme.sign(flag.face));
                buf.set_stringn(left, y, &flag.sign, 1, style);
            }
        }
        spans(buf, area.x, y, area.width, &row.spans, base, theme);
        if let Some(column) = text.ruler {
            let cell = &mut buf[(area.x + column as u16, y)];
            cell.set_style(cell.style().patch(theme.ruler));
        }
    }
    text.cursor
        .map(|(x, y)| Position::new(area.x + x as u16, area.y + y as u16))
}

fn splash(buf: &mut Buffer, area: Rect, lines: &[(String, &str)], theme: &Theme) {
    use unicode_width::UnicodeWidthStr;
    let height = lines.len() as u16 + 2;
    let keys = lines
        .iter()
        .map(|(key, _)| key.width())
        .max()
        .unwrap_or(0)
        .max(10) as u16;
    let docs = lines.iter().map(|(_, doc)| doc.width()).max().unwrap_or(0) as u16;
    let width = keys + 2 + docs;
    if area.height < height || area.width < width {
        return;
    }
    let y = area.y + (area.height - height) / 2;
    let x = area.x + (area.width - width) / 2;
    buf.set_string(x + (width - 4) / 2, y, "soda", theme.title);
    for (index, (key, doc)) in lines.iter().enumerate() {
        let y = y + 2 + index as u16;
        buf.set_string(x + keys - key.width() as u16, y, key, theme.key);
        buf.set_string(x + keys + 2, y, doc, theme.dim);
    }
}

/// A tab laid out on the row.
pub(super) struct TabItem {
    /// The document, or `None` for the splash.
    pub document: Option<crate::editor::DocumentId>,
    pub active: bool,
    pub dirty: bool,
    /// Its starting column.
    pub x: u16,
    pub label: String,
}

/// Tabs of `window`'s row, or the splash's, that fit in `width` cells,
/// with their documents, starting columns and labels; tabs drop from the
/// left until the active one fits.
pub(super) fn tab_items(runtime: &Runtime, window: Option<ViewId>, width: u16) -> Vec<TabItem> {
    let items: Vec<_> = content::tabs(runtime, window)
        .into_iter()
        .map(|tab| {
            let dirty = if tab.dirty { " ●" } else { "" };
            let label = format!(" {}{dirty} ", tab.label);
            TabItem {
                document: tab.document,
                active: tab.active,
                dirty: tab.dirty,
                x: 0,
                label: screen::plain(&label, 0, usize::from(width)),
            }
        })
        .collect();
    let widths: Vec<u16> = items
        .iter()
        .map(|item| Line::raw(item.label.as_str()).width() as u16)
        .collect();
    let index = items.iter().position(|item| item.active).unwrap_or(0);
    let mut first = 0;
    while first < index && widths[first..=index].iter().sum::<u16>() > width {
        first += 1;
    }
    let mut x = 0u16;
    let mut out = vec![];
    for (item, item_width) in items.into_iter().zip(widths).skip(first) {
        if x >= width {
            break;
        }
        out.push(TabItem { x, ..item });
        x = x.saturating_add(item_width);
    }
    out
}

/// A row of tabs; in a window other than the current one the active tab
/// is not bold, so the current window's stands out.
fn tabs(
    buf: &mut Buffer,
    area: Rect,
    runtime: &Runtime,
    window: Option<ViewId>,
    current: bool,
    theme: &Theme,
) {
    buf.set_style(area, theme.tabs);
    for item in tab_items(runtime, window, area.width) {
        let x = area.x + item.x;
        let style = match (item.active, current) {
            (true, true) => theme.tab_active,
            (true, false) => theme
                .tab_active
                .remove_modifier(ratatui::style::Modifier::BOLD),
            (false, _) => theme.tabs,
        };
        buf.set_stringn(x, area.y, &item.label, usize::from(area.right() - x), style);
        if item.dirty {
            let dot = x + Line::raw(item.label.as_str()).width() as u16 - 2;
            if dot < area.right() {
                buf[(dot, area.y)].set_style(theme.modified);
            }
        }
    }
}

fn status(
    buf: &mut Buffer,
    area: Rect,
    runtime: &Runtime,
    theme: &Theme,
    text: Option<&TextFrame>,
) {
    // The row may have been pushed up over text, and styling keeps symbols.
    Clear.render(area, buf);
    buf.set_style(area, theme.status);
    let status = content::status(runtime, text);
    let mut right: Vec<_> = status
        .segments
        .iter()
        .map(|(words, role)| Text::styled(format!("{words}  "), role_style(*role, theme)))
        .collect();
    if let Some((line, column, percent)) = status.place {
        right.push(Text::styled(
            format!("{line}:{column}"),
            theme.status_strong,
        ));
        right.push(Text::raw(format!("  {percent:>3}% ")));
    }
    let right = Line::from(right);
    let right_width = (right.width() as u16).min(area.width);
    let mut left = match status.mode {
        Some(mode) => vec![
            Text::styled(format!(" {} ", mode.label()), mode_style(mode, theme)),
            Text::raw(" "),
        ],
        None => vec![Text::raw(" ")],
    };
    if let Some(document) = status.document {
        let mut marks = vec![];
        if document.dirty {
            marks.push(Text::styled(" [+]", theme.modified));
        }
        if document.saving {
            marks.push(Text::raw(" saving…"));
        }
        // Long paths keep their file name and lose leading directories.
        let used = Line::from(left.clone()).width() + Line::from(marks.clone()).width();
        let room = usize::from(area.width).saturating_sub(usize::from(right_width) + used + 2);
        left.push(Text::styled(
            tail(&document.path, room),
            theme.status_strong,
        ));
        left.extend(marks);
    }
    buf.set_line(
        area.x,
        area.y,
        &Line::from(left),
        area.width.saturating_sub(right_width + 1),
    );
    buf.set_line(area.right() - right_width, area.y, &right, right_width);
}
fn mode_style(mode: content::Mode, theme: &Theme) -> Style {
    match mode {
        content::Mode::Normal => theme.mode_normal,
        content::Mode::Insert => theme.mode_insert,
        content::Mode::Beacon => theme.mode_visual,
        content::Mode::Prompt(_) => theme.mode_prompt,
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

/// The end of `text` within `width` cells, marked with `…` when cut.
fn tail(text: &str, width: usize) -> String {
    use unicode_width::UnicodeWidthChar;
    let total: usize = text.chars().map(|c| c.width().unwrap_or(0)).sum();
    if total <= width {
        return text.to_owned();
    }
    let mut kept = vec![];
    let mut used = 1;
    for ch in text.chars().rev() {
        let w = ch.width().unwrap_or(0);
        if used + w > width {
            break;
        }
        used += w;
        kept.push(ch);
    }
    std::iter::once('…').chain(kept.into_iter().rev()).collect()
}

/// The bottom row shows messages, or a prompt layer's input. Returns the
/// prompt cursor.
fn message(
    buf: &mut Buffer,
    area: Rect,
    runtime: &Runtime,
    theme: &Theme,
    text: Option<&TextFrame>,
) -> Option<Position> {
    let width = usize::from(area.width);
    match content::message(runtime, text) {
        Message::Prompt(presentation) => {
            let (row, cursor) = screen::prompt_row(&presentation, width);
            spans(buf, area.x, area.y, area.width, &row, theme.text, theme);
            cursor.map(|x| Position::new(area.x + x.min(width.saturating_sub(1)) as u16, area.y))
        }
        Message::Words(words, role) => {
            let style = match role {
                Role::Plain => theme.text,
                Role::Severity(severity) => theme.severity(severity),
                role => role_style(role, theme),
            };
            buf.set_stringn(area.x, area.y, screen::plain(words, 0, width), width, style);
            None
        }
    }
}

fn inset(area: Rect) -> Rect {
    Rect::new(
        area.x + 1,
        area.y + 1,
        area.width.saturating_sub(2),
        area.height.saturating_sub(2),
    )
}
/// The box everything floating over the text sits in.
fn float_box(buf: &mut Buffer, area: Rect, theme: &Theme) {
    Clear.render(area, buf);
    Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(theme.float_border)
        .style(theme.float)
        .render(area, buf);
}
fn popup(buf: &mut Buffer, area: Rect, title: &str, theme: &Theme) {
    Clear.render(area, buf);
    Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(theme.border)
        .style(theme.panel)
        .title(Text::styled(title.to_owned(), theme.title))
        .render(area, buf);
}

/// The command line panel sits above the status line: the input, then the
/// candidates of the slot under the cursor.
fn command_line(
    buf: &mut Buffer,
    area: Rect,
    line: &CommandLine,
    theme: &Theme,
) -> Option<Position> {
    let rows = line.rows();
    let list = line.list();
    Clear.render(area, buf);
    buf.set_style(area, theme.text);
    // What the line is for, right of the input, in at most half the row.
    let half = usize::from(area.width / 2);
    let info = content::command_info(line, theme, |whole| Line::from(whole).width() < half);
    let info: Vec<_> = info
        .into_iter()
        .enumerate()
        .flat_map(|(i, (text, style))| {
            (i > 0)
                .then(|| Text::styled(" · ", theme.dim))
                .into_iter()
                .chain([Text::styled(text, style)])
        })
        .collect();
    let info = Line::from(info);
    let info_width = (info.width() as u16 + 1).min(area.width / 2);
    let field = Rect::new(area.x, area.y, area.width - info_width, 1);
    let (input, column) = screen::prompt_row(&line.field(), usize::from(field.width));
    // Enter takes the input as typed: it shows selected, as vertico's
    // prompt does.
    let input_style = if line.input_selected() {
        buf.set_style(field, theme.candidate_selected);
        theme.text.patch(theme.candidate_selected)
    } else {
        theme.text
    };
    spans(
        buf,
        field.x,
        field.y,
        field.width,
        &input,
        input_style,
        theme,
    );
    info.right_aligned().render(
        Rect::new(field.right(), area.y, info_width.saturating_sub(1), 1),
        buf,
    );
    let selected = list.selected();
    for offset in 0..usize::from(area.height - 1) {
        let y = area.y + 1 + offset as u16;
        let Some(row) = rows.get(list.first_visible() + offset) else {
            break;
        };
        let base = if selected == Some(row.candidate.key) {
            let band = Rect::new(area.x, y, area.width, 1);
            buf.set_style(band, theme.candidate_selected);
            buf.set_string(area.x, y, "▌", theme.marker.patch(theme.candidate_selected));
            theme.text.patch(theme.candidate_selected)
        } else {
            theme.text
        };
        let width = area.width.saturating_sub(2);
        let label =
            screen::candidate_row(row, None, row.candidate.payload.detail, usize::from(width));
        spans(buf, area.x + 2, y, width, &label, base, theme);
    }
    column.map(|x| {
        Position::new(
            field.x + (x as u16).min(field.width.saturating_sub(1)),
            field.y,
        )
    })
}

/// Which keys continue a pending multi-key binding, in columns at the lower
/// right of the editing area.
fn key_hints(buf: &mut Buffer, areas: &Areas, runtime: &Runtime, theme: &Theme) {
    let mut entries = runtime.key_continuations();
    if entries.is_empty() {
        return;
    }
    entries.sort();
    let key_width = entries
        .iter()
        .map(|(k, _)| k.chars().count())
        .max()
        .unwrap_or(0);
    let column_width = (key_width
        + 2
        + entries
            .iter()
            .map(|(_, d)| d.chars().count())
            .max()
            .unwrap_or(0))
    .min(56);
    let max_rows = usize::from(areas.editor.height.saturating_sub(2)).clamp(1, 12);
    let columns = entries.len().div_ceil(max_rows);
    let rows = entries.len().div_ceil(columns);
    // Narrow columns cut their words rather than hide what the keys are.
    let room = usize::from(areas.editor.width).saturating_sub(2) / columns;
    let column_width = column_width.min(room.saturating_sub(2));
    if column_width <= key_width + 2 {
        return;
    }
    let width = (columns * (column_width + 2) + 2) as u16;
    let height = rows as u16 + 2;
    if width > areas.editor.width || height > areas.editor.height {
        return;
    }
    let area = Rect::new(
        areas.editor.right() - width,
        areas.editor.bottom() - height,
        width,
        height,
    );
    let title = format!(" {} ", runtime.pending_keys().unwrap_or_default());
    popup(buf, area, &title, theme);
    for (index, (key, doc)) in entries.iter().enumerate() {
        let x = area.x + 2 + ((index / rows) * (column_width + 2)) as u16;
        let y = area.y + 1 + (index % rows) as u16;
        buf.set_string(
            x,
            y,
            format!("{key:>key_width$}"),
            theme
                .key
                .patch(Style::new().bg(theme.panel.bg.unwrap_or_default())),
        );
        let doc = screen::plain(doc, 0, column_width - key_width - 2);
        buf.set_string(x + key_width as u16 + 2, y, doc, theme.panel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interaction::{Command, EditMode, KeyStroke, UserInput};

    /// A frame as a frontend draws it: measured, prepared, then rendered.
    fn draw(runtime: &mut Runtime, width: u16, height: u16) -> Buffer {
        let mut presenter = Presenter::new();
        presenter.measure(runtime, width, height);
        presenter.prepare(runtime, width, height).unwrap();
        let mut buffer = Buffer::empty(Rect::new(0, 0, width, height));
        presenter.render(runtime, &mut buffer).unwrap();
        buffer
    }
    fn screen(runtime: &mut Runtime, width: u16, height: u16) -> String {
        let buffer = draw(runtime, width, height);
        let mut out = String::new();
        for y in 0..height {
            for x in 0..width {
                out.push_str(buffer[(x, y)].symbol());
            }
            out.push('\n');
        }
        out
    }
    fn keys(runtime: &mut Runtime, notation: &str) {
        for key in KeyStroke::parse_sequence(notation).unwrap() {
            runtime.input(UserInput::Key(key));
        }
    }

    #[test]
    fn the_grab_and_beacon_selections_each_have_their_face() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "foo bar\nfoo qux\n".into(),
        )));
        r.command(Command::Edit(crate::editor::Command::SetSelection(
            crate::core::Selection::caret(0),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        // The backgrounds of the first line, and of the cell after it.
        let first_line = |r: &mut Runtime| {
            let buffer = draw(r, 30, 6);
            let row = (0..6u16)
                .find(|&y| {
                    (0..30u16)
                        .map(|x| buffer[(x, y)].symbol())
                        .collect::<String>()
                        .contains("foo bar")
                })
                .unwrap();
            let x = (0..30u16)
                .find(|&x| buffer[(x, row)].symbol() == "f")
                .unwrap();
            let cells: Vec<_> = (x..x + 9).map(|x| buffer[(x, row)].bg).collect();
            (cells, buffer[(29, row)].bg)
        };
        let theme = Theme::build("tokyonight", &Default::default());
        let (grab, cursor, beacon, selection) = (
            theme.secondary_selection.bg.unwrap(),
            theme.beacon_cursor.bg.unwrap(),
            theme.beacon_selection.bg.unwrap(),
            theme.selection.bg.unwrap(),
        );
        assert!(grab != cursor && grab != beacon && beacon != selection);
        // The main caret ends the second line; the other ends the first,
        // on the cell after the text. The grab covers the rest.
        keys(&mut r, "e e G");
        assert_eq!(r.beacons(), vec![7..7]);
        let (cells, plain) = first_line(&mut r);
        assert_eq!(cells[..7], [grab; 7]);
        assert_eq!(cells[7], cursor);
        assert_eq!(cells[8], plain);
        // A marked word: its other match is a selection of its own face.
        keys(&mut r, "C-a [");
        let (cells, _) = first_line(&mut r);
        assert_eq!(cells[..3], [beacon; 3]);
        assert_eq!(cells[3], grab);
        // Words: a caret at the end of each, on the cell after it.
        keys(&mut r, "ESC C-a w");
        let (cells, _) = first_line(&mut r);
        assert_eq!(cells[..3], [grab; 3]);
        assert_eq!(cells[3], cursor);
        // `G` without a selection lets the grab go, and Beacon with it.
        keys(&mut r, "G");
        assert_eq!(r.edit_mode(), EditMode::Normal);
        assert!(r.beacons().is_empty());
        let (cells, plain) = first_line(&mut r);
        assert_eq!(cells, vec![plain; 9]);
    }
    #[test]
    fn each_window_has_its_row_of_tabs_unless_the_option_is_off() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "first\n".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        // How many windows' tabs the top row shows, and the row of the text.
        let top = |r: &mut Runtime| -> (usize, usize) {
            let text = screen(r, 60, 14);
            let rows: Vec<_> = text.lines().collect();
            let first = rows.iter().position(|row| row.contains("first")).unwrap();
            (rows[0].matches("[untitled").count(), first)
        };
        assert_eq!(top(&mut r), (1, 1));
        // Split, each window has its own row, the same as one alone.
        r.command(Command::Named("vsplit".into()));
        assert_eq!(top(&mut r), (2, 1));
        r.command(Command::Named("set tab-bar off".into()));
        assert_eq!(top(&mut r), (0, 0));
        r.command(Command::Named("only".into()));
        assert_eq!(top(&mut r), (0, 0));
    }
    #[test]
    fn screens_compose_tabs_gutter_status_and_panels() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("src")).unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        assert!(screen(&mut r, 60, 14).contains("Find a project file"));
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "int main() {\n    return 0;\n}".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        let text = screen(&mut r, 60, 14);
        let rows: Vec<_> = text.lines().collect();
        // Document numbers are process-wide, so match around them.
        assert!(rows[0].starts_with(" [untitled ") && rows[0].contains("] ●"));
        assert!(rows[1].starts_with("   1 │ int main() {"));
        assert!(rows[12].starts_with(" NORMAL  [untitled "));
        assert!(rows[12].contains("] [+]"));
        assert!(rows[12].trim_end().ends_with("3:2  100%"));
        assert_eq!(
            rows[13].trim(),
            "",
            "the message row is empty without a message"
        );
        keys(&mut r, "SPC");
        assert!(screen(&mut r, 120, 14).contains("f  Open a project file"));
        keys(&mut r, "ESC");
        r.command(Command::Close(None));
        let text = screen(&mut r, 60, 14);
        let rows: Vec<_> = text.lines().collect();
        // The input sits under the status line it pushed up, the question
        // and count to its right, and candidates below; the 12-row editing
        // area keeps 10 candidate rows whether or not they are used.
        assert!(rows[2].starts_with(" COMMAND "), "{text}");
        assert!(rows[3].starts_with(":close "));
        assert!(rows[3].contains("unsaved [untitled ") && rows[3].trim_end().ends_with("· 1/2"));
        assert!(rows[4].starts_with("▌ save         [s]"));
        assert!(rows[5].starts_with("  discard      [d]"));
        keys(&mut r, "ESC M-x");
        r.input(UserInput::Paste("map normal ".into()));
        let text = screen(&mut r, 60, 14);
        let rows: Vec<_> = text.lines().collect();
        // Free text has no candidates, so the line stays at the bottom with
        // the command's slots beside it.
        assert!(rows[12].starts_with(" COMMAND "), "{text}");
        assert!(rows[13].starts_with(":map normal "));
        assert!(rows[13].trim_end().ends_with("map KEYMAP KEYS COMMAND"));
        keys(&mut r, "ESC");
        r.command(Command::Help);
        let text = screen(&mut r, 60, 14);
        // Over the windows, their rows of tabs too.
        assert!(
            text.lines()
                .next()
                .unwrap()
                .starts_with("╭ Help · Esc closes")
        );
        assert!(text.lines().nth(1).unwrap().starts_with("│ Editing"));
    }
    #[test]
    fn notes_underline_their_range_and_speak_at_the_caret() {
        use crate::application::{Event, NoteSpan, Severity};
        use ratatui::style::Modifier;
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "one two\nthree\n".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        let document = r
            .app()
            .view(r.app().active_view().unwrap())
            .unwrap()
            .document_id;
        r.dispatch(Event::Note {
            document,
            group: "test".into(),
            notes: vec![
                NoteSpan {
                    start: (0, 4),
                    end: (0, 7),
                    severity: Severity::Warning,
                    text: "second word\nmore".into(),
                },
                NoteSpan {
                    start: (1, 0),
                    end: (1, 5),
                    severity: Severity::Error,
                    text: "broken".into(),
                },
            ],
        });
        r.command(Command::Named("goto 1:1".into()));
        let text = screen(&mut r, 60, 10);
        let rows: Vec<_> = text.lines().collect();
        assert_eq!(rows[9].trim_end(), "second word", "{text}");
        assert!(rows[8].contains("E1") && rows[8].contains("W1"), "{text}");
        // Each line's worst note, its first line only, after the text.
        assert!(rows[1].contains("one two    second word"), "{text}");
        assert!(!rows[1].contains("more"), "{text}");
        assert!(rows[2].contains("three    broken"), "{text}");
        r.command(Command::Named("set inline-notes false".into()));
        let plain = screen(&mut r, 60, 10);
        assert!(!plain.lines().nth(2).unwrap().contains("broken"), "{plain}");
        r.command(Command::Named("set inline-notes true".into()));
        let theme = Theme::build(crate::application::themes::DEFAULT, &Default::default());
        let cells = &draw(&mut r, 60, 10);
        let first = rows[1].split("one").next().unwrap().chars().count() as u16;
        let underlined = |x| cells[(x, 1)].modifier.contains(Modifier::UNDERLINED);
        assert!(!underlined(first + 3) && underlined(first + 4) && underlined(first + 6));
        assert_eq!(
            cells[(first + 4, 1)].underline_color,
            theme.todo.fg.unwrap()
        );
    }

    #[test]
    fn wrapping_breaks_at_spaces_and_inside_long_words() {
        assert_eq!(screen::wrap("aaa bbb ccc", 7), ["aaa bbb", "ccc"]);
        assert_eq!(screen::wrap("a\n\nb", 7), ["a", "", "b"]);
        assert_eq!(
            screen::wrap("abcdefghij kl", 4),
            ["abcd", "efgh", "ij", "kl"]
        );
    }

    #[test]
    fn completions_sit_in_a_box_under_the_caret_line() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("a.txt"), "alpha alder\n\n").unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.start(Some(root.path().join("a.txt")));
        for _ in 0..500 {
            r.poll();
            if r.app().views().any(|v| {
                r.app()
                    .workspace()
                    .file(v.document_id)
                    .unwrap()
                    .path()
                    .is_some()
            }) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        r.command(Command::Named("goto 2".into()));
        r.command(Command::SetMode(EditMode::Insert));
        keys(&mut r, "al");
        for _ in 0..500 {
            r.poll();
            if r.completion_popup().is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let text = screen(&mut r, 40, 14);
        let rows: Vec<_> = text.lines().collect();
        let top = rows.iter().position(|row| row.contains("╭")).expect(&text);
        assert!(rows[top - 1].contains("al"), "{text}");
        assert!(rows[top + 1].contains("│ al"), "{text}");
        assert!(rows[top + 3].contains("╰"), "{text}");
    }

    #[test]
    fn the_selected_candidate_shows_its_documentation_beside_the_list() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.source_lua(
            "t",
            r#"soda.completion.register({ complete = function(context, sink)
              sink:add({ { label = "alpha", doc = "What alpha is" }, { label = "alder" } })
              sink:done()
            end })"#,
        )
        .unwrap();
        r.command(Command::SetMode(EditMode::Insert));
        keys(&mut r, "al");
        for _ in 0..500 {
            r.poll();
            if r.completion_popup().is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let text = screen(&mut r, 60, 12);
        assert!(
            !text.contains("What alpha is"),
            "only once selected: {text}"
        );
        keys(&mut r, "<down>");
        let text = screen(&mut r, 60, 12);
        let row = text
            .lines()
            .find(|row| row.contains("What alpha is"))
            .expect(&text);
        assert!(row.contains("alpha"), "beside the list: {text}");
    }

    #[test]
    fn places_of_a_snippet_left_to_fill_are_drawn_with_their_face() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::SetMode(EditMode::Insert));
        r.command(Command::Named("snippet ${1:aa} ${2:bb}".into()));
        let text = screen(&mut r, 40, 10);
        let row = text.lines().nth(1).unwrap();
        let start = row.split("aa").next().unwrap().chars().count() as u16;
        let cells = &draw(&mut r, 40, 10);
        let underlined = |x| {
            cells[(x, 1)]
                .modifier
                .contains(ratatui::style::Modifier::UNDERLINED)
        };
        // The place being filled is the selection; the next is marked.
        assert!(!underlined(start) && underlined(start + 3) && underlined(start + 4));
    }

    #[test]
    fn the_selected_candidate_shows_in_gray_at_the_caret_and_not_in_the_text() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            " end\n".into(),
        )));
        r.command(Command::Named("goto 1:1".into()));
        r.source_lua(
            "t",
            r#"soda.completion.register({ complete = function(context, sink)
              sink:add({ { label = "alpha" }, { label = "fn", filter = "alfa", snippet = "alfa(${1:x})$0" } })
              sink:done()
            end })"#,
        )
        .unwrap();
        r.command(Command::SetMode(EditMode::Insert));
        keys(&mut r, "al");
        for _ in 0..500 {
            r.poll();
            if r.completion_popup().is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let first_row = |r: &mut Runtime| screen(r, 40, 10).lines().nth(1).unwrap().to_owned();
        assert!(first_row(&mut r).contains("al end"), "nothing until chosen");
        keys(&mut r, "<down>");
        assert!(
            first_row(&mut r).contains("alpha end"),
            "{}",
            first_row(&mut r)
        );
        // A snippet shows as the text it would write.
        keys(&mut r, "<down>");
        assert!(
            first_row(&mut r).contains("alfa(x) end"),
            "{}",
            first_row(&mut r)
        );
        let view = r.app().view(r.app().active_view().unwrap()).unwrap();
        let editor = r.app().workspace().editor(view.document_id).unwrap();
        assert_eq!(editor.model().document().snapshot().text(), "al end\n");
        r.command(Command::Named("set completion-preview false".into()));
        assert!(first_row(&mut r).contains("al end"));
    }

    #[test]
    fn inlay_hints_shift_the_row_and_the_caret_and_not_the_text() {
        use crate::application::Event;
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "call(1, 2)\n".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        let document = r
            .app()
            .view(r.app().active_view().unwrap())
            .unwrap()
            .document_id;
        r.dispatch(Event::Inlays {
            document,
            hints: vec![(0, 5, "a: ".into()), (0, 8, "b: ".into())],
        });
        r.command(Command::Named("goto 1:9".into()));
        let text = screen(&mut r, 40, 8);
        assert!(text.contains("call(a: 1, b: 2)"), "{text}");
        // Past both hints: the caret stands on the 2 on screen.
        let areas = Areas::new(&r, 40, 8);
        let texts = frames(&r, &mut Highlighter::default(), &areas).unwrap();
        let (x, _) = texts[0].as_ref().unwrap().cursor.unwrap();
        assert_eq!(x, 14, "8 cells of text and 6 of hints");

        // A click goes by the text: on a hint, to the character after it.
        let width = areas.text(&r).width;
        assert_eq!(
            screen::offset_at(r.app(), &screen::Cells, width.into(), 0, 14),
            Some(8)
        );
        assert_eq!(
            screen::offset_at(r.app(), &screen::Cells, width.into(), 0, 6),
            Some(5)
        );
        assert_eq!(
            screen::offset_at(r.app(), &screen::Cells, width.into(), 0, 2),
            Some(2)
        );

        r.command(Command::Named("set inlay-hints false".into()));
        assert!(screen(&mut r, 40, 8).contains("call(1, 2)"));
        r.command(Command::Named("set inlay-hints true".into()));

        // Wrapped text keeps its columns, and the hints wait at the end.
        r.command(Command::Named("set wrap true".into()));
        let text = screen(&mut r, 40, 8);
        assert!(text.contains("call(1, 2) a:  b:"), "{text}");
    }

    #[test]
    fn an_indicator_stands_at_the_end_of_its_line_until_the_next_key() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "one\ntwo\n".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        r.command(Command::Lua(r#"soda.indicator(2, "[2/3]")"#.into()));
        let text = screen(&mut r, 40, 8);
        assert!(text.contains("two [2/3]"), "{text}");
        assert!(!text.contains("one ["), "{text}");
        keys(&mut r, "l");
        assert!(!screen(&mut r, 40, 8).contains("[2/3]"));
    }

    #[test]
    fn a_long_popup_scrolls_and_shows_its_place() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        let words: Vec<_> = (1..=30).map(|n| format!("line{n}")).collect();
        r.command(Command::Lua(format!(
            "soda.popup(\"{}\")",
            words.join("\\n")
        )));
        let first = screen(&mut r, 40, 14);
        assert!(
            first.contains("line1 ") && !first.contains("line30"),
            "{first}"
        );
        assert!(first.contains("/30 "), "{first}");
        r.scroll_popup(1000);
        let last = screen(&mut r, 40, 14);
        assert!(
            last.contains("line30") && !last.contains("line1 "),
            "{last}"
        );
        // Scrolling past the end is forgotten, so back up is immediate.
        r.scroll_popup(-1);
        assert!(screen(&mut r, 40, 14).contains("line29"));
        // Paging keeps it open and moves by what is in view; others close.
        r.scroll_popup(-1000);
        screen(&mut r, 40, 14);
        keys(&mut r, "<next>");
        let paged = screen(&mut r, 40, 14);
        assert!(
            !paged.contains("line1 ") && !paged.contains(" 1-"),
            "{paged}"
        );
        keys(&mut r, "M-v");
        assert!(screen(&mut r, 40, 14).contains("line1 "));
        keys(&mut r, "C-v");
        assert!(r.popup().is_some());
        keys(&mut r, "l");
        assert!(r.popup().is_none());
    }

    #[test]
    fn a_popup_wraps_in_a_box_by_the_caret() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Lua(
            r#"soda.popup("int value\n\nA long sentence that has to wrap")"#.into(),
        ));
        let text = screen(&mut r, 24, 12);
        let rows: Vec<_> = text.lines().collect();
        assert!(rows.iter().any(|row| row.contains("╭")), "{text}");
        assert!(rows.iter().any(|row| row.contains("int value")), "{text}");
        assert!(
            rows.iter().any(|row| row.contains("A long sentence")),
            "{text}"
        );
        assert!(rows.iter().any(|row| row.contains("to wrap")), "{text}");
    }

    #[test]
    fn a_status_line_pushed_up_hides_the_text_under_it() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            format!("{}\n", "x".repeat(50)).repeat(12),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        r.command(Command::Ex("open ".into()));
        let text = screen(&mut r, 60, 14);
        let status = text
            .lines()
            .find(|row| row.starts_with(" COMMAND "))
            .unwrap();
        assert!(!status.contains("xxx"), "{text}");
    }

    #[test]
    fn the_line_after_a_final_newline_shows_and_is_reachable() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "a\nb\n".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        let rows = |r: &mut Runtime| -> Vec<String> {
            screen(r, 40, 8).lines().map(str::to_owned).collect()
        };
        // As at the end of an Emacs buffer, the empty line after the final
        // newline is a line: shown wherever the caret is, and reached by
        // moving down, in Normal and in Insert.
        keys(&mut r, "M-<");
        let shown = rows(&mut r);
        assert!(shown[3].starts_with("   3 │"), "{shown:?}");
        assert!(!shown[4].contains('4'));
        keys(&mut r, "jjj");
        assert!(rows(&mut r)[6].trim_end().ends_with("3:1  100%"));
        keys(&mut r, "M-< i <down> <down> <down>");
        assert!(rows(&mut r)[6].contains("3:1"));
    }
    #[test]
    fn expand_digits_show_on_text_and_after_the_end_of_lines() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "ab\ncd ef gh\nij\n".into(),
        )));
        r.command(Command::Edit(crate::editor::Command::SetSelection(
            crate::core::Selection::caret(0),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        // A line selection extends to line ends, where no character is.
        keys(&mut r, "e");
        let shown = screen(&mut r, 30, 6);
        let rows: Vec<_> = shown.lines().collect();
        // The first row is the tab line.
        assert!(rows[2].contains("cd ef gh1"), "{shown}");
        assert!(rows[3].contains("ij2"), "{shown}");
        // A word selection's next end within the line covers the space there.
        keys(&mut r, "ESC C-n C-a w");
        let shown = screen(&mut r, 30, 6);
        assert!(
            shown.lines().nth(2).unwrap().contains("cd ef1gh2"),
            "{shown}"
        );
    }
    #[test]
    fn flags_take_the_first_gutter_cell() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "a\nb\nc".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        r.command(Command::Named("flag-lines git mark2 + 2".into()));
        let text = screen(&mut r, 40, 8);
        let rows: Vec<_> = text.lines().collect();
        assert!(rows[1].starts_with("   1 │ a"), "{text}");
        assert!(rows[2].starts_with("+  2 │ b"), "{text}");
        // Without numbers the flags keep a column of their own.
        r.command(Command::Named("set line-numbers off".into()));
        let text = screen(&mut r, 40, 8);
        let rows: Vec<_> = text.lines().collect();
        assert!(rows[1].starts_with("  a"), "{text}");
        assert!(rows[2].starts_with("+ b"), "{text}");
        r.command(Command::Named("unflag-lines".into()));
        assert!(
            screen(&mut r, 40, 8)
                .lines()
                .nth(2)
                .unwrap()
                .starts_with("b")
        );
    }
    #[test]
    fn line_numbers_follow_the_option() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.source_lua("modal", include_str!("../../tests/fixtures/modal.lua"))
            .unwrap();
        r.command(crate::interaction::Command::New);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "a\nb\nc\nd".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        keys(&mut r, "M-<");
        keys(&mut r, "j");
        r.command(Command::Named("set line-numbers relative".into()));
        let text = screen(&mut r, 40, 10);
        let rows: Vec<_> = text.lines().collect();
        assert!(rows[1].starts_with("   1 │ a"), "{text}");
        assert!(rows[2].starts_with("   2 │ b"));
        assert!(rows[4].starts_with("   2 │ d"));
        r.command(Command::Named("set line-numbers off".into()));
        let text = screen(&mut r, 40, 10);
        assert!(text.lines().nth(1).unwrap().starts_with("a "), "{text}");
    }
}
