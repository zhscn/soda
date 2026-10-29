//! Screen composition: buffer tabs, the editing area with its line number
//! gutter, the status line and the message row, with the command line panel,
//! key hints and help drawn over the editing area. Everything here reads
//! state; viewport changes happen before drawing.
use super::{
    layout::{self, Span},
    theme::Theme,
};
use crate::{
    application::{Area, ViewId},
    interaction::{CommandLine, EditMode, Layer, help::HINT},
    runtime::Runtime,
};
use ratatui::{
    Frame,
    buffer::Buffer,
    layout::{Position, Rect},
    style::Style,
    text::{Line, Span as Text},
    widgets::{Block, BorderType, Clear, Widget},
};

/// One window: an optional title row when several are shown, then the
/// line number gutter and the text.
pub(super) struct Window {
    pub view: ViewId,
    pub area: Rect,
    pub header: Option<Rect>,
    pub gutter: u16,
    pub text: Rect,
}
/// Screen regions for one terminal size.
pub(super) struct Areas {
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
        let tabs = (height >= 4).then(|| Rect::new(0, 0, width, 1));
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
        let several = layout.len() > 1;
        let windows = layout
            .into_iter()
            .map(|(view, area)| {
                let area = Rect::new(area.x, area.y, area.width, area.height);
                let header = (several && area.height >= 2).then_some(Rect { height: 1, ..area });
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
                let gutter = if numbers && body.width >= gutter + 16 {
                    gutter
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
    /// Rows the command line may use for candidates.
    pub fn list_rows(&self) -> usize {
        usize::from(self.editor.height.saturating_sub(4)).min(10)
    }
}

pub(super) fn render(
    frame: &mut Frame,
    runtime: &Runtime,
    theme: &Theme,
    areas: &Areas,
    texts: &[Option<layout::Frame>],
) {
    let screen = frame.area();
    let buf = frame.buffer_mut();
    buf.set_style(screen, theme.text);
    if let Some(area) = areas.tabs {
        tabs(buf, area, runtime, theme);
    }
    let active = runtime.app().active_view();
    let mut cursor = None;
    if areas.windows.is_empty() {
        splash(buf, areas.editor, theme);
    } else {
        separators(buf, areas, theme);
    }
    for (window, text) in areas.windows.iter().zip(texts) {
        let current = Some(window.view) == active;
        if let Some(header) = window.header {
            window_header(buf, header, runtime, window.view, current, theme);
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
    let text = areas
        .windows
        .iter()
        .zip(texts)
        .find(|(window, _)| Some(window.view) == active)
        .and_then(|(_, text)| text.as_ref());
    if let Some(area) = areas.status {
        status(buf, area, runtime, theme, text);
    }
    let prompt = message(buf, areas.message, runtime, theme);
    match runtime.layer() {
        Some(Layer::CommandLine(line)) => {
            cursor = command_line(buf, areas, line, theme);
        }
        Some(Layer::Help(session)) => {
            cursor = None;
            popup(buf, areas.editor, " Help · Esc closes ", theme);
            let inner = inset(inset(areas.editor));
            let inner = Rect::new(inner.x, inner.y - 1, inner.width, inner.height + 2);
            for (y, line) in session.lines().enumerate().take(inner.height.into()) {
                let line = layout::plain(line, 0, inner.width.into());
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
    if let Some(position) = cursor {
        frame.set_cursor_position(position);
    }
}

fn spans(buf: &mut Buffer, x: u16, y: u16, width: u16, spans: &[Span], base: Style, theme: &Theme) {
    let mut x = x;
    let right = x.saturating_add(width);
    for span in spans {
        let mut style = base;
        if span.selected {
            style = style.patch(theme.selection);
        }
        if let Some(category) = span.category {
            style = style.patch(theme.category(category));
        }
        if span.detail {
            style = style.patch(theme.detail);
        }
        if span.matched {
            style = style.patch(theme.matched);
        }
        if x >= right {
            break;
        }
        x = buf
            .set_stringn(x, y, &span.text, usize::from(right - x), style)
            .0;
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
fn window_header(
    buf: &mut Buffer,
    area: Rect,
    runtime: &Runtime,
    view: ViewId,
    current: bool,
    theme: &Theme,
) {
    buf.set_style(area, theme.tabs);
    let Some(document) = runtime.app().view(view).map(|view| view.document_id) else {
        return;
    };
    let dirty = runtime.app().workspace().is_dirty(document);
    let label = format!(
        " {}{} ",
        file_label(runtime, document, true),
        if dirty { " ●" } else { "" }
    );
    let label = tail(&label, area.width.into());
    let style = if current {
        theme.tab_active
    } else {
        theme.tabs
    };
    buf.set_stringn(area.x, area.y, label, area.width.into(), style);
}
fn editor(
    buf: &mut Buffer,
    window: &Window,
    text: &layout::Frame,
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
            let number = format!(" {shown:>digits$} │ ");
            buf.set_stringn(left, y, &number, window.gutter.into(), style);
        }
        spans(buf, area.x, y, area.width, &row.spans, base, theme);
    }
    text.cursor
        .map(|(x, y)| Position::new(area.x + x, area.y + y))
}

fn splash(buf: &mut Buffer, area: Rect, theme: &Theme) {
    let lines: [(&str, &str); 5] = [
        (":open", "Open a file"),
        ("<space>f", "Find a project file"),
        (":enew", "New document"),
        (":", "Run any command"),
        ("F1", "Help"),
    ];
    let height = lines.len() as u16 + 2;
    if area.height < height || area.width < 32 {
        return;
    }
    let y = area.y + (area.height - height) / 2;
    let x = area.x + (area.width - 32) / 2;
    buf.set_string(x + 13, y, "soda", theme.title);
    for (index, (key, doc)) in lines.iter().enumerate() {
        let y = y + 2 + index as u16;
        buf.set_string(x, y, format!("{key:>10}"), theme.key);
        buf.set_string(x + 12, y, doc, theme.dim);
    }
}

fn file_label(runtime: &Runtime, document: crate::editor::DocumentId, full: bool) -> String {
    let app = runtime.app();
    if let Some(name) = app
        .workspace()
        .file(document)
        .and_then(|file| file.scratch())
    {
        return name.to_owned();
    }
    match app.workspace().file(document).and_then(|file| file.path()) {
        Some(path) if full => path
            .strip_prefix(runtime.file_root())
            .unwrap_or(path)
            .display()
            .to_string(),
        Some(path) => path.file_name().map_or_else(
            || path.display().to_string(),
            |n| n.to_string_lossy().into(),
        ),
        None => format!("[untitled {}]", document.number()),
    }
}

/// Tabs that fit in `width` cells, with their documents, starting columns
/// and labels; tabs drop from the left until the active one fits.
pub(super) fn tab_items(
    runtime: &Runtime,
    width: u16,
) -> Vec<(crate::editor::DocumentId, u16, String)> {
    let app = runtime.app();
    let active = app
        .active_view()
        .and_then(|id| app.view(id))
        .map(|view| view.document_id);
    let items: Vec<_> = app
        .workspace()
        .documents()
        .map(|id| {
            let dirty = if app.workspace().is_dirty(id) {
                " ●"
            } else {
                ""
            };
            let label = format!(" {}{dirty} ", file_label(runtime, id, false));
            (id, layout::plain(&label, 0, usize::from(width)))
        })
        .collect();
    let widths: Vec<u16> = items
        .iter()
        .map(|(_, label)| Line::raw(label.as_str()).width() as u16)
        .collect();
    let index = items
        .iter()
        .position(|(id, _)| Some(*id) == active)
        .unwrap_or(0);
    let mut first = 0;
    while first < index && widths[first..=index].iter().sum::<u16>() > width {
        first += 1;
    }
    let mut x = 0u16;
    let mut out = vec![];
    for ((id, label), item_width) in items.into_iter().zip(widths).skip(first) {
        if x >= width {
            break;
        }
        out.push((id, x, label));
        x = x.saturating_add(item_width);
    }
    out
}

fn tabs(buf: &mut Buffer, area: Rect, runtime: &Runtime, theme: &Theme) {
    buf.set_style(area, theme.tabs);
    let app = runtime.app();
    let active = app
        .active_view()
        .and_then(|id| app.view(id))
        .map(|view| view.document_id);
    for (id, offset, label) in tab_items(runtime, area.width) {
        let x = area.x + offset;
        let style = if Some(id) == active {
            theme.tab_active
        } else {
            theme.tabs
        };
        buf.set_stringn(x, area.y, &label, usize::from(area.right() - x), style);
        if app.workspace().is_dirty(id) {
            let dot = x + Line::raw(label.as_str()).width() as u16 - 2;
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
    text: Option<&layout::Frame>,
) {
    buf.set_style(area, theme.status);
    let (badge, style) = match runtime.layer() {
        Some(Layer::CommandLine(_)) => ("COMMAND", theme.mode_prompt),
        Some(Layer::Search { .. }) => ("SEARCH", theme.mode_prompt),
        Some(Layer::Replace(_)) => ("REPLACE", theme.mode_prompt),
        Some(Layer::Saving(_)) => ("SAVING", theme.mode_prompt),
        Some(Layer::Help(_)) => ("HELP", theme.mode_prompt),
        None => match runtime.edit_mode() {
            EditMode::Normal => ("NORMAL", theme.mode_normal),
            EditMode::Insert => ("INSERT", theme.mode_insert),
            EditMode::Visual => ("VISUAL", theme.mode_visual),
            EditMode::VisualLine => ("V-LINE", theme.mode_visual),
        },
    };
    let app = runtime.app();
    let view = app.active_view().and_then(|id| app.view(id));
    let mut right = vec![];
    if let Some(register) = runtime.recording() {
        right.push(Text::styled(
            format!("recording @{register}  "),
            theme.modified,
        ));
    }
    if let Some(pending) = runtime.pending_keys() {
        right.push(Text::styled(format!("{pending}  "), theme.key));
    }
    if runtime.grep_running() {
        right.push(Text::raw("searching…  "));
    }
    if runtime.shell_running() {
        right.push(Text::raw("running…  "));
    }
    if let Some(text) = text.filter(|_| view.is_some()) {
        right.push(Text::raw(format!("{}  ", text.language)));
        let (line, column) = text.caret;
        let percent = (line + 1) * 100 / text.line_count.max(1);
        right.push(Text::styled(
            format!("{}:{}", line + 1, column + 1),
            theme.status_strong,
        ));
        right.push(Text::raw(format!("  {percent:>3}% ")));
    }
    let right = Line::from(right);
    let right_width = (right.width() as u16).min(area.width);
    let mut left = vec![Text::styled(format!(" {badge} "), style), Text::raw(" ")];
    if let Some(view) = view {
        let document = view.document_id;
        let mut marks = vec![];
        if app.workspace().is_dirty(document) {
            marks.push(Text::styled(" [+]", theme.modified));
        }
        if app.workspace().is_saving(document) {
            marks.push(Text::raw(" saving…"));
        }
        // Long paths keep their file name and lose leading directories.
        let used = Line::from(left.clone()).width() + Line::from(marks.clone()).width();
        let room = usize::from(area.width).saturating_sub(usize::from(right_width) + used + 2);
        let path = file_label(runtime, document, true);
        left.push(Text::styled(tail(&path, room), theme.status_strong));
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
fn message(buf: &mut Buffer, area: Rect, runtime: &Runtime, theme: &Theme) -> Option<Position> {
    let width = usize::from(area.width);
    match runtime.layer() {
        Some(Layer::Search { .. } | Layer::Replace(_) | Layer::Saving(_)) => {
            let presentation = runtime.layer().unwrap().presentation();
            let (row, cursor) = layout::prompt_row(&presentation, width);
            spans(buf, area.x, area.y, area.width, &row, theme.text, theme);
            cursor.map(|x| Position::new(area.x + x.min(width.saturating_sub(1)) as u16, area.y))
        }
        _ => {
            let (text, style) = if runtime.message().is_empty() {
                // Key hints only while editing; panels explain themselves.
                (if runtime.layer().is_none() { HINT } else { "" }, theme.dim)
            } else {
                (runtime.message(), theme.text)
            };
            buf.set_stringn(area.x, area.y, layout::plain(text, 0, width), width, style);
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
    areas: &Areas,
    line: &CommandLine,
    theme: &Theme,
) -> Option<Position> {
    let rows = line.rows();
    let list = line.list();
    // A fixed height keeps the panel from jumping as candidates come and
    // go; unused candidate rows stay blank.
    let shown = areas.list_rows();
    let height = if shown > 0 { 4 + shown as u16 } else { 3 };
    let bottom = areas.editor.bottom();
    let height = height.min(areas.editor.height);
    if height < 3 || areas.editor.width < 8 {
        return None;
    }
    let area = Rect::new(areas.editor.x, bottom - height, areas.editor.width, height);
    let mut title = vec![Text::styled(
        format!(" {} ", line.heading().unwrap_or_else(|| "command".into())),
        theme.title,
    )];
    if let Some(note) = line.note() {
        title.push(Text::styled(format!("· {note} "), theme.modified));
    }
    let mut block = Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(theme.border)
        .style(theme.panel)
        .title(Line::from(title));
    if let Some(error) = line.error() {
        block = block.title_bottom(Text::styled(format!(" {error} "), theme.error));
    } else if line.loading() {
        block = block.title_bottom(Text::styled(" loading… ", theme.dim));
    }
    if let Some(index) = list.index(rows) {
        block = block.title_bottom(
            Line::styled(format!(" {}/{} ", index + 1, rows.len()), theme.dim).right_aligned(),
        );
    }
    Clear.render(area, buf);
    block.render(area, buf);
    let inner = inset(area);
    // One column of padding on each side of the input.
    let field = Rect::new(inner.x + 1, inner.y, inner.width.saturating_sub(2), 1);
    let (input, column) = layout::prompt_row(&line.field(), usize::from(field.width));
    spans(
        buf,
        field.x,
        field.y,
        field.width,
        &input,
        theme.panel,
        theme,
    );
    if shown > 0 && inner.height >= 2 {
        let y = inner.y + 1;
        buf[(area.x, y)].set_symbol("├");
        for x in inner.x..inner.right() {
            buf[(x, y)].set_symbol("─");
        }
        buf[(area.right() - 1, y)].set_symbol("┤");
        let selected = list.selected();
        for offset in 0..shown {
            let y = inner.y + 2 + offset as u16;
            if y >= inner.bottom() {
                break;
            }
            let Some(row) = rows.get(list.first_visible() + offset) else {
                break;
            };
            let base = if selected == Some(row.candidate.key) {
                buf.set_style(
                    Rect::new(inner.x, y, inner.width, 1),
                    theme.candidate_selected,
                );
                buf.set_string(
                    inner.x,
                    y,
                    "▌",
                    theme.marker.patch(theme.candidate_selected),
                );
                theme.panel.patch(theme.candidate_selected)
            } else {
                theme.panel
            };
            let width = inner.width.saturating_sub(3);
            let label =
                layout::candidate_row(row, None, row.candidate.payload.detail, usize::from(width));
            spans(buf, inner.x + 2, y, width, &label, base, theme);
        }
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
        let doc = layout::plain(doc, 0, column_width - key_width - 2);
        buf.set_string(x + key_width as u16 + 2, y, doc, theme.panel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interaction::{Command, KeyStroke, UserInput};
    use ratatui::{Terminal, backend::TestBackend};

    fn screen(runtime: &mut Runtime, width: u16, height: u16) -> String {
        let theme = Theme::detect();
        let areas = Areas::new(runtime, width, height);
        runtime.resize(areas.editor.height.into(), areas.list_rows());
        runtime.set_page_rows(areas.text(runtime).height.into());
        super::super::follow(runtime, &areas).unwrap();
        let areas = Areas::new(runtime, width, height);
        let texts =
            super::super::frames(runtime, &mut crate::syntax::Highlighter::default(), &areas)
                .unwrap();
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal
            .draw(|f| render(f, runtime, &theme, &areas, &texts))
            .unwrap();
        let buffer = terminal.backend().buffer();
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
    fn screens_compose_tabs_gutter_status_and_panels() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("src")).unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        assert!(screen(&mut r, 60, 14).contains("Find a project file"));
        r.start(None);
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
        assert!(rows[12].trim_end().ends_with("3:1  100%"));
        assert!(rows[13].starts_with("i Insert"));
        keys(&mut r, "<space>");
        assert!(screen(&mut r, 60, 14).contains("f  Open a project file"));
        keys(&mut r, "<esc>");
        r.command(Command::Close(None));
        let text = screen(&mut r, 60, 14);
        let rows: Vec<_> = text.lines().collect();
        assert!(
            rows.iter()
                .any(|row| row.starts_with("╭ close [DECISION] [PATH] · unsaved"))
        );
        assert!(rows.iter().any(|row| row.starts_with("│ :close ")));
        assert!(
            rows.iter()
                .any(|row| row.starts_with("│▌ save         [s]"))
        );
        assert!(rows[12].starts_with(" COMMAND "));
        // With two candidates the panel still takes its full height: an
        // 11-row editing area leaves 7 candidate rows, 11 rows in all.
        let top = rows
            .iter()
            .position(|row| row.starts_with("╭ close"))
            .unwrap();
        assert_eq!(top, 1);
        assert!(rows[13].trim().is_empty());
        // The terminal cursor sits in the panel input after `:close `.
        keys(&mut r, "<esc>");
        r.command(Command::Help);
        let text = screen(&mut r, 60, 14);
        assert!(
            text.lines()
                .nth(1)
                .unwrap()
                .starts_with("╭ Help · Esc closes")
        );
        assert!(text.lines().nth(2).unwrap().starts_with("│ Vim editing"));
    }
    #[test]
    fn line_numbers_follow_the_option() {
        let root = tempfile::tempdir().unwrap();
        let mut r = Runtime::new(root.path().to_owned()).unwrap();
        r.start(None);
        r.command(Command::Edit(crate::editor::Command::InsertText(
            "a\nb\nc\nd".into(),
        )));
        r.command(Command::SetMode(EditMode::Normal));
        keys(&mut r, "gg");
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
