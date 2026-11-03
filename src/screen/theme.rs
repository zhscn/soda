//! The built-in color theme. Colors are 24-bit; a frontend that cannot show
//! them converts them as it draws. The `theme` option picks the dark or
//! light variant; `auto` takes the one the frontend reports for its
//! background. Faces set with `face` go over it.
use crate::syntax::Category;
use ratatui::style::{Color, Modifier, Style};

pub(crate) struct Theme {
    pub text: Style,
    pub dim: Style,
    pub gutter: Style,
    pub gutter_current: Style,
    pub cursor_line: Style,
    pub selection: Style,
    pub status: Style,
    pub status_strong: Style,
    pub modified: Style,
    pub error: Style,
    pub mode_normal: Style,
    pub mode_insert: Style,
    pub mode_visual: Style,
    pub mode_prompt: Style,
    pub tabs: Style,
    pub tab_active: Style,
    pub border: Style,
    pub title: Style,
    pub panel: Style,
    /// What floats over the text: a box, so it stays apart from the caret
    /// line and from any text beneath it.
    pub float: Style,
    pub float_border: Style,
    pub candidate_selected: Style,
    pub marker: Style,
    /// Words shown in the text that are not part of it.
    pub inlay: Style,
    /// The symbol at the caret where else it stands, and where it is written.
    pub reference: Style,
    pub reference_write: Style,
    /// Places of a snippet left to fill in, and their copies.
    pub snippet: Style,
    pub unnecessary: Style,
    pub deprecated: Style,
    /// Notes after the text of their line, by severity from info up.
    pub notes: [Style; 3],
    pub status_error: Style,
    pub status_warning: Style,
    /// Notes that are neither errors nor warnings.
    pub info: Style,
    pub matched: Style,
    pub detail: Style,
    /// Tab and trailing space marks.
    pub whitespace: Style,
    pub ruler: Style,
    syntax: [Style; CATEGORIES],
    pub key: Style,
    /// Jump labels over the text.
    pub label: Style,
    pub todo: Style,
    pub marks: [Style; crate::application::MARKS as usize],
    /// Every face by its place in `faces::names`, for paints.
    named: Vec<Style>,
}

struct Palette {
    bg: u32,
    bg_dark: u32,
    bg_highlight: u32,
    selection: u32,
    fg: u32,
    fg_dark: u32,
    comment: u32,
    gutter: u32,
    gutter_current: u32,
    blue: u32,
    green: u32,
    magenta: u32,
    orange: u32,
    yellow: u32,
    red: u32,
    cyan: u32,
    teal: u32,
    on_accent: u32,
}
const DARK: Palette = Palette {
    bg: 0x1a1b26,
    bg_dark: 0x16161e,
    bg_highlight: 0x292e42,
    selection: 0x33467c,
    fg: 0xc0caf5,
    fg_dark: 0xa9b1d6,
    comment: 0x565f89,
    gutter: 0x3b4261,
    gutter_current: 0x737aa2,
    blue: 0x7aa2f7,
    green: 0x9ece6a,
    magenta: 0xbb9af7,
    orange: 0xff9e64,
    yellow: 0xe0af68,
    red: 0xf7768e,
    cyan: 0x7dcfff,
    teal: 0x73daca,
    on_accent: 0x15161e,
};
const LIGHT: Palette = Palette {
    bg: 0xe1e2e7,
    bg_dark: 0xd0d5e3,
    bg_highlight: 0xc4c8da,
    selection: 0xb7c1e3,
    fg: 0x3760bf,
    fg_dark: 0x6172b0,
    comment: 0x848cb5,
    gutter: 0xa8aecb,
    gutter_current: 0x6172b0,
    blue: 0x2e7de9,
    green: 0x587539,
    magenta: 0x9854f1,
    orange: 0xb15c00,
    yellow: 0x8c6c3e,
    red: 0xf52a65,
    cyan: 0x007197,
    teal: 0x387068,
    on_accent: 0xe1e2e7,
};

impl Theme {
    /// The theme a `theme` option value names, with the faces over it;
    /// `auto` is light when the frontend's background is.
    pub fn build(choice: &str, faces: &crate::application::faces::Faces, light: bool) -> Self {
        let light = match choice {
            "light" => true,
            "dark" => false,
            _ => light,
        };
        let mut theme = Self::new(if light { &LIGHT } else { &DARK });
        for (name, spec) in faces.iter() {
            if let Some(style) = theme.slot(name) {
                *style = apply(*style, spec);
            }
        }
        theme.named = crate::application::faces::names()
            .map(|name| theme.slot(&name).copied().unwrap_or_default())
            .collect();
        theme
    }
    /// The style of a span of laid out text over `base`.
    pub fn span(&self, span: &super::Span, base: Style) -> Style {
        let mut style = base;
        if span.selected {
            style = style.patch(self.selection);
        }
        if let Some(category) = span.category {
            style = style.patch(self.category(category));
        }
        if span.detail {
            style = style.patch(self.detail);
        }
        if span.matched {
            style = style.patch(self.matched);
        }
        if span.whitespace {
            style = style.patch(self.whitespace);
        }
        if let Some(face) = span.face {
            style = style.patch(self.face(face));
        }
        if span.inlay {
            style = style.patch(self.inlay);
        }
        style
    }
    /// The style a face name stands for.
    fn slot(&mut self, name: &str) -> Option<&mut Style> {
        if let Some(category) = name.strip_prefix("syntax.") {
            let index = CATEGORY_ORDER.iter().position(|c| c.name() == category)?;
            return Some(&mut self.syntax[index]);
        }
        if let Some(n) = name.strip_prefix("mark") {
            let n: usize = n.parse().ok()?;
            return self.marks.get_mut(n.checked_sub(1)?);
        }
        Some(match name {
            "text" => &mut self.text,
            "dim" => &mut self.dim,
            "gutter" => &mut self.gutter,
            "gutter-current" => &mut self.gutter_current,
            "cursor-line" => &mut self.cursor_line,
            "selection" => &mut self.selection,
            "status" => &mut self.status,
            "status-strong" => &mut self.status_strong,
            "modified" => &mut self.modified,
            "error" => &mut self.error,
            "mode-normal" => &mut self.mode_normal,
            "mode-insert" => &mut self.mode_insert,
            "mode-beacon" => &mut self.mode_visual,
            "mode-prompt" => &mut self.mode_prompt,
            "tabs" => &mut self.tabs,
            "tab-active" => &mut self.tab_active,
            "border" => &mut self.border,
            "title" => &mut self.title,
            "panel" => &mut self.panel,
            "float" => &mut self.float,
            "float-border" => &mut self.float_border,
            "candidate-selected" => &mut self.candidate_selected,
            "marker" => &mut self.marker,
            "inlay" => &mut self.inlay,
            "reference" => &mut self.reference,
            "reference-write" => &mut self.reference_write,
            "snippet" => &mut self.snippet,
            "unnecessary" => &mut self.unnecessary,
            "deprecated" => &mut self.deprecated,
            "note-info" => &mut self.notes[0],
            "note-warning" => &mut self.notes[1],
            "note-error" => &mut self.notes[2],
            "status-error" => &mut self.status_error,
            "status-warning" => &mut self.status_warning,
            "info" => &mut self.info,
            "matched" => &mut self.matched,
            "detail" => &mut self.detail,
            "whitespace" => &mut self.whitespace,
            "ruler" => &mut self.ruler,
            "key" => &mut self.key,
            "label" => &mut self.label,
            "todo" => &mut self.todo,
            _ => return None,
        })
    }
    fn new(p: &Palette) -> Self {
        let c = color;
        let on = |fg: u32, bg: u32| Style::new().fg(c(fg)).bg(c(bg));
        let badge = |bg: u32| on(p.on_accent, bg).add_modifier(Modifier::BOLD);
        Self {
            text: on(p.fg, p.bg),
            dim: on(p.comment, p.bg),
            gutter: on(p.gutter, p.bg),
            gutter_current: on(p.gutter_current, p.bg_highlight),
            cursor_line: Style::new().bg(c(p.bg_highlight)),
            selection: Style::new().bg(c(p.selection)),
            status: on(p.fg_dark, p.bg_dark),
            status_strong: on(p.fg, p.bg_dark).add_modifier(Modifier::BOLD),
            modified: Style::new().fg(c(p.yellow)),
            error: Style::new().fg(c(p.red)),
            mode_normal: badge(p.blue),
            mode_insert: badge(p.green),
            mode_visual: badge(p.magenta),
            mode_prompt: badge(p.orange),
            tabs: on(p.comment, p.bg_dark),
            tab_active: on(p.fg, p.bg).add_modifier(Modifier::BOLD),
            border: on(p.gutter, p.bg),
            title: on(p.blue, p.bg).add_modifier(Modifier::BOLD),
            panel: on(p.fg, p.bg),
            float: on(p.fg, p.bg_dark),
            float_border: on(p.comment, p.bg_dark),
            candidate_selected: Style::new().bg(c(p.bg_highlight)),
            marker: Style::new().fg(c(p.blue)),
            inlay: Style::new().fg(c(p.comment)).add_modifier(Modifier::ITALIC),
            reference: Style::new().bg(c(p.gutter)),
            reference_write: Style::new()
                .bg(c(p.gutter))
                .add_modifier(Modifier::UNDERLINED),
            snippet: Style::new()
                .bg(c(p.bg_highlight))
                .add_modifier(Modifier::UNDERLINED),
            unnecessary: Style::new().fg(c(p.comment)),
            deprecated: Style::new().add_modifier(Modifier::CROSSED_OUT),
            notes: [p.blue, p.yellow, p.red]
                .map(|fg| Style::new().fg(c(fg)).add_modifier(Modifier::ITALIC)),
            status_error: on(p.red, p.bg_dark).add_modifier(Modifier::BOLD),
            status_warning: on(p.yellow, p.bg_dark).add_modifier(Modifier::BOLD),
            info: Style::new().fg(c(p.blue)),
            matched: Style::new().fg(c(p.orange)).add_modifier(Modifier::BOLD),
            detail: Style::new().fg(c(p.comment)),
            whitespace: Style::new().fg(c(p.gutter)),
            // Darker than the text and the caret line, so it shows on both.
            ruler: Style::new().bg(c(p.bg_dark)),
            syntax: {
                let fg = |rgb: u32| Style::new().fg(c(rgb));
                let italic = Modifier::ITALIC;
                CATEGORY_ORDER.map(|category| match category {
                    Category::Comment => fg(p.comment).add_modifier(italic),
                    Category::String => fg(p.green),
                    Category::Escape => fg(p.magenta),
                    Category::Number | Category::Constant => fg(p.orange),
                    Category::Keyword => fg(p.magenta),
                    Category::Operator => fg(p.cyan),
                    Category::Type => fg(p.teal),
                    Category::Function => fg(p.blue),
                    Category::Parameter => fg(p.yellow),
                    Category::Namespace => fg(p.cyan),
                    Category::Macro => fg(p.cyan),
                    Category::Tag => fg(p.red),
                    Category::Attribute => fg(p.yellow),
                    Category::Heading => fg(p.blue).add_modifier(Modifier::BOLD),
                    Category::Emphasis => Style::new().add_modifier(italic),
                    Category::Strong => Style::new().add_modifier(Modifier::BOLD),
                    Category::Link => fg(p.cyan).add_modifier(Modifier::UNDERLINED),
                    Category::Inserted => fg(p.green),
                    Category::Deleted => fg(p.red),
                    Category::Changed => fg(p.yellow),
                    Category::Invalid => fg(p.red).add_modifier(Modifier::UNDERLINED),
                    Category::Match => fg(p.red).add_modifier(Modifier::BOLD),
                })
            },
            key: Style::new().fg(c(p.magenta)).add_modifier(Modifier::BOLD),
            label: badge(p.magenta),
            todo: Style::new().fg(c(p.yellow)).add_modifier(Modifier::BOLD),
            marks: [
                p.yellow, p.green, p.blue, p.magenta, p.orange, p.cyan, p.red, p.comment,
            ]
            .map(|bg| Style::new().fg(c(p.bg)).bg(c(bg))),
            named: vec![],
        }
    }
}

impl Theme {
    pub fn face(&self, face: crate::application::Face) -> Style {
        match face {
            crate::application::Face::Todo => self.todo,
            crate::application::Face::Error => self.error,
            crate::application::Face::Info => self.info,
            crate::application::Face::Mark(n) => self.marks[usize::from(n)],
            crate::application::Face::Named(n) => {
                self.named.get(usize::from(n)).copied().unwrap_or_default()
            }
            crate::application::Face::Note(severity) => {
                let colour = self.severity(severity).fg.unwrap_or_default();
                Style::new()
                    .underline_color(colour)
                    .add_modifier(Modifier::UNDERLINED)
            }
        }
    }
    /// A note's colour.
    pub fn severity(&self, severity: crate::application::Severity) -> Style {
        match severity {
            crate::application::Severity::Error => self.error,
            crate::application::Severity::Warning => {
                Style::new().fg(self.todo.fg.unwrap_or_default())
            }
            crate::application::Severity::Info => self.info,
        }
    }
    /// A flag's sign: the face's colour on the gutter's background.
    pub fn sign(&self, face: crate::application::Face) -> Style {
        let colour = match face {
            crate::application::Face::Mark(n) => self.marks[usize::from(n)].bg,
            face => self.face(face).fg,
        };
        Style::new()
            .fg(colour.unwrap_or_default())
            .add_modifier(Modifier::BOLD)
    }
    pub fn category(&self, category: Category) -> Style {
        self.syntax[CATEGORY_ORDER.iter().position(|c| *c == category).unwrap()]
    }
}
const CATEGORIES: usize = Category::ALL.len();
const CATEGORY_ORDER: [Category; CATEGORIES] = Category::ALL;

/// A face's colors and attributes over a theme style.
fn apply(mut style: Style, spec: &crate::application::faces::FaceSpec) -> Style {
    use crate::application::faces::Color as Face;
    let pick = |c: Face| match c {
        Face::Rgb(rgb) => color(rgb),
        Face::Default => Color::Reset,
    };
    if let Some(fg) = spec.fg {
        style.fg = Some(pick(fg));
    }
    if let Some(bg) = spec.bg {
        style.bg = Some(pick(bg));
    }
    if let Some(a) = spec.attributes {
        let mut modifier = Modifier::empty();
        for (on, m) in [
            (a.bold, Modifier::BOLD),
            (a.italic, Modifier::ITALIC),
            (a.underline, Modifier::UNDERLINED),
            (a.dim, Modifier::DIM),
            (a.reverse, Modifier::REVERSED),
            (a.strikethrough, Modifier::CROSSED_OUT),
        ] {
            if on {
                modifier |= m;
            }
        }
        style.add_modifier = modifier;
        style.sub_modifier = Modifier::empty();
    }
    style
}
fn color(rgb: u32) -> Color {
    Color::Rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8)
}
