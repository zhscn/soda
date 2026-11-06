//! The color theme. Colors are 24-bit; a frontend that cannot show them
//! converts them as it draws. The `theme` option names a built-in theme
//! or one `soda.theme` defined over a built-in one. Faces set with `face`
//! go over the theme.
use crate::syntax::Category;
use ratatui::style::{Color, Modifier, Style};

pub(crate) struct Theme {
    pub text: Style,
    pub dim: Style,
    pub gutter: Style,
    pub gutter_current: Style,
    pub cursor_line: Style,
    pub selection: Style,
    /// The grab, as Emacs's `secondary-selection`.
    pub secondary_selection: Style,
    /// Beacon's other selections and carets. Unless set, their background
    /// mixes the grab's with the selection's or the Beacon caret's, as
    /// meow's `meow-beacon-fake-selection` and `meow-beacon-fake-cursor`.
    pub beacon_selection: Style,
    pub beacon_cursor: Style,
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
    /// A bracket at the caret and its match.
    pub paren_match: Style,
    /// The background of windows other than the focused one, as Emacs's
    /// `auto-dim-other-buffers` gives them.
    pub inactive_window: Style,
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
    /// The thumb of a window's scroll bar, where one is drawn.
    pub scrollbar: Style,
    syntax: [Style; CATEGORIES],
    pub key: Style,
    /// Jump labels over the text.
    pub label: Style,
    /// What flash's search matches, the match Enter goes to, and the text
    /// around them while it searches.
    pub flash_match: Style,
    pub flash_current: Style,
    pub flash_backdrop: Style,
    pub todo: Style,
    /// Digits that extend the selection.
    pub digit: Style,
    pub marks: [Style; crate::application::MARKS as usize],
    /// Every face by its place in `faces::names`, for paints.
    named: Vec<Style>,
}

#[derive(Clone, Default)]
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
impl Palette {
    /// A built-in theme's colors, given in `faces::PALETTE` order.
    fn of(theme: &crate::application::themes::Builtin) -> Self {
        let mut palette = Self::default();
        for (name, rgb) in crate::application::faces::PALETTE.iter().zip(theme.palette) {
            *palette.slot(name).unwrap() = rgb;
        }
        palette
    }
    /// A color by its name in `faces::PALETTE`.
    fn slot(&mut self, name: &str) -> Option<&mut u32> {
        Some(match name {
            "bg" => &mut self.bg,
            "bg-dark" => &mut self.bg_dark,
            "bg-highlight" => &mut self.bg_highlight,
            "selection" => &mut self.selection,
            "fg" => &mut self.fg,
            "fg-dark" => &mut self.fg_dark,
            "comment" => &mut self.comment,
            "gutter" => &mut self.gutter,
            "gutter-current" => &mut self.gutter_current,
            "blue" => &mut self.blue,
            "green" => &mut self.green,
            "magenta" => &mut self.magenta,
            "orange" => &mut self.orange,
            "yellow" => &mut self.yellow,
            "red" => &mut self.red,
            "cyan" => &mut self.cyan,
            "teal" => &mut self.teal,
            "on-accent" => &mut self.on_accent,
            _ => return None,
        })
    }
}

impl Theme {
    /// The theme a `theme` option value names, with the faces over it; a
    /// name no longer defined gives the default theme.
    ///
    /// The layers, each over the one before: a built-in theme's palette,
    /// the palette colors of a defined theme over it, the faces the
    /// palette makes, the built-in theme's faces, the defined theme's
    /// faces, and those set with `face`.
    pub fn build(choice: &str, faces: &crate::application::faces::Faces) -> Self {
        use crate::application::{faces::FaceSpec, themes};
        let defined = faces.theme(choice);
        let base = defined.map_or(choice, |defined| defined.base.as_str());
        let builtin = themes::builtin(base)
            .or_else(|| themes::builtin(themes::DEFAULT))
            .expect("the default theme is built in");
        let mut palette = Palette::of(builtin);
        for (name, rgb) in defined.iter().flat_map(|defined| &defined.palette) {
            if let Some(slot) = palette.slot(name) {
                *slot = *rgb;
            }
        }
        let mut theme = Self::new(&palette);
        let builtin_faces: Vec<_> = builtin
            .faces
            .iter()
            .filter_map(|(name, spec)| Some((*name, FaceSpec::parse(spec).ok()?)))
            .collect();
        let builtin_faces = builtin_faces.iter().map(|(name, spec)| (*name, spec));
        let defined_faces = defined.iter().flat_map(|defined| &defined.faces);
        let defined_faces = defined_faces.map(|(name, spec)| (name.as_str(), spec));
        // A refined syntax category starts from its parent's final style,
        // so its specs wait until every parent has all of its own.
        let mut refined: Vec<Vec<&FaceSpec>> = vec![vec![]; CATEGORIES];
        for (name, spec) in builtin_faces.chain(defined_faces).chain(faces.iter()) {
            let category = name.strip_prefix("syntax.").and_then(Category::named);
            match category {
                Some(category) if category.parent().is_some() => {
                    refined[index_of(category)].push(spec);
                }
                _ => {
                    if let Some(style) = theme.slot(name) {
                        *style = apply(*style, spec);
                    }
                }
            }
        }
        for (index, category) in CATEGORY_ORDER.iter().enumerate() {
            if let Some(parent) = category.parent() {
                let inherited = theme.syntax[index_of(parent)];
                theme.syntax[index] = refined[index]
                    .iter()
                    .fold(inherited, |style, spec| apply(style, spec));
            }
        }
        let secondary = theme.secondary_selection.bg;
        if theme.beacon_selection.bg.is_none() {
            theme.beacon_selection.bg = mixed(theme.selection.bg, secondary);
        }
        if theme.beacon_cursor.bg.is_none() {
            theme.beacon_cursor.bg = mixed(theme.mode_visual.bg, secondary);
        }
        theme.named = crate::application::faces::names()
            .map(|name| theme.slot(&name).copied().unwrap_or_default())
            .collect();
        theme
    }
    /// The style of a span of laid out text over `base`.
    pub fn span(&self, span: &super::Span, base: Style) -> Style {
        let mut style = base;
        style = style.patch(match span.mark {
            super::Mark::None => Style::new(),
            super::Mark::Grab => self.secondary_selection,
            super::Mark::BeaconSelection => self.beacon_selection,
            super::Mark::BeaconCursor => self.beacon_cursor,
        });
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
            return Some(&mut self.syntax[index_of(Category::named(category)?)]);
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
            "secondary-selection" => &mut self.secondary_selection,
            "beacon-selection" => &mut self.beacon_selection,
            "beacon-cursor" => &mut self.beacon_cursor,
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
            "paren-match" => &mut self.paren_match,
            "inactive-window" => &mut self.inactive_window,
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
            "scrollbar" => &mut self.scrollbar,
            "key" => &mut self.key,
            "label" => &mut self.label,
            "flash-match" => &mut self.flash_match,
            "flash-current" => &mut self.flash_current,
            "flash-backdrop" => &mut self.flash_backdrop,
            "todo" => &mut self.todo,
            "expand-digit" => &mut self.digit,
            _ => return None,
        })
    }
    fn new(p: &Palette) -> Self {
        let c = color;
        let on = |fg: u32, bg: u32| Style::new().fg(c(fg)).bg(c(bg));
        let badge = |bg: u32| on(p.on_accent, bg).add_modifier(Modifier::BOLD);
        // What frames the text stands apart from it in steps toward the
        // text's color, so lighter in a dark theme and darker in a light
        // one, as Zed's themes do: the tab bar and window titles a step
        // off, the status line two, and the lines between them and the
        // text further. `bg-dark` is too near the text to tell.
        let surface = mix(p.bg, p.fg, 0.06);
        let bar = mix(p.bg, p.fg, 0.13);
        let line = mix(p.bg, p.fg, 0.2);
        Self {
            text: on(p.fg, p.bg),
            dim: on(p.comment, p.bg),
            gutter: on(p.gutter, p.bg),
            gutter_current: on(p.gutter_current, p.bg_highlight),
            cursor_line: Style::new().bg(c(p.bg_highlight)),
            selection: Style::new().bg(c(p.selection)),
            secondary_selection: Style::new().bg(c(mix(p.bg, p.yellow, 0.3))),
            beacon_selection: Style::new(),
            beacon_cursor: Style::new(),
            status: on(p.fg_dark, bar),
            status_strong: on(p.fg, bar).add_modifier(Modifier::BOLD),
            modified: Style::new().fg(c(p.yellow)),
            error: Style::new().fg(c(p.red)),
            mode_normal: badge(p.blue),
            mode_insert: badge(p.green),
            mode_visual: badge(p.magenta),
            mode_prompt: badge(p.orange),
            tabs: on(p.comment, surface),
            tab_active: on(p.fg, p.bg).add_modifier(Modifier::BOLD),
            border: on(line, p.bg),
            inactive_window: Style::new().bg(c(p.bg_dark)),
            paren_match: Style::new()
                .bg(c(mix(p.bg, p.blue, 0.3)))
                .add_modifier(Modifier::BOLD),
            title: on(p.blue, p.bg).add_modifier(Modifier::BOLD),
            panel: on(p.fg, p.bg),
            float: on(p.fg, p.bg_dark),
            float_border: on(p.comment, p.bg_dark),
            // The list's ground is `bg-dark`, which `bg-highlight` may
            // match or be lighter than, so the selected row is worked out
            // from the ground itself.
            candidate_selected: Style::new().bg(c(apart(p.bg_dark, p.selection, p.blue))),
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
            status_error: on(p.red, bar).add_modifier(Modifier::BOLD),
            status_warning: on(p.yellow, bar).add_modifier(Modifier::BOLD),
            info: Style::new().fg(c(p.blue)),
            matched: Style::new().fg(c(p.orange)).add_modifier(Modifier::BOLD),
            detail: Style::new().fg(c(p.comment)),
            whitespace: Style::new().fg(c(p.gutter)),
            // Darker than the text and the caret line, so it shows on both.
            ruler: Style::new().bg(c(p.bg_dark)),
            scrollbar: Style::new().bg(c(p.comment)),
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
                    // Plain until a theme colors them.
                    Category::Variable | Category::Property | Category::Punctuation => Style::new(),
                    // Inherited from the parent when the theme is built.
                    Category::CommentDoc
                    | Category::ConstantBuiltin
                    | Category::PunctuationBracket
                    | Category::PunctuationDelimiter
                    | Category::TypeBuiltin
                    | Category::FunctionDefinition
                    | Category::FunctionCall
                    | Category::FunctionBuiltin
                    | Category::VariableDefinition
                    | Category::PropertyDefinition => Style::new(),
                })
            },
            key: Style::new().fg(c(p.magenta)).add_modifier(Modifier::BOLD),
            label: badge(p.magenta),
            // As flash.nvim's links: Search, IncSearch and Comment.
            flash_match: Style::new().bg(c(mix(p.bg, p.blue, 0.35))),
            flash_current: on(p.on_accent, p.orange),
            flash_backdrop: Style::new().fg(c(p.comment)),
            todo: Style::new().fg(c(p.yellow)).add_modifier(Modifier::BOLD),
            // As meow's: the background's color on the cursor's, so a digit
            // stands apart from the text it covers.
            digit: on(p.bg, p.blue).add_modifier(Modifier::BOLD),
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
            crate::application::Face::Digit => self.digit,
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
        self.syntax[index_of(category)]
    }
}
fn index_of(category: Category) -> usize {
    CATEGORY_ORDER.iter().position(|c| *c == category).unwrap()
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
/// `a` with `amount` of `b` in it.
/// How much the selected candidate's row stands from its list, as WCAG's
/// contrast ratio: enough to find at a glance, little enough that the
/// text on it reads.
const SELECTED_CONTRAST: f32 = 1.5;
/// A color for a row picked out of a list on `ground`: from the ground
/// toward the theme's selection until it stands apart, and when even the
/// selection is too near the ground, on toward the accent.
fn apart(ground: u32, selection: u32, accent: u32) -> u32 {
    let steps = (1..=40).map(|step| step as f32 / 40.0);
    steps
        .clone()
        .map(|amount| mix(ground, selection, amount))
        .chain(steps.map(|amount| mix(selection, accent, amount)))
        .find(|color| contrast(*color, ground) >= SELECTED_CONTRAST)
        .unwrap_or(accent)
}
/// WCAG's contrast ratio of two colors, from 1 to 21.
fn contrast(a: u32, b: u32) -> f32 {
    let luminance = |rgb: u32| {
        let channel = |shift: u32| {
            let value = ((rgb >> shift) & 0xff) as f32 / 255.0;
            if value <= 0.039_28 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    };
    let (a, b) = (luminance(a), luminance(b));
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}
fn mix(a: u32, b: u32, amount: f32) -> u32 {
    let channel = |shift: u32| {
        let (a, b) = (((a >> shift) & 0xff) as f32, ((b >> shift) & 0xff) as f32);
        ((a + (b - a) * amount).round() as u32) << shift
    };
    channel(16) | channel(8) | channel(0)
}
/// Two colors half and half, when both are known.
fn mixed(a: Option<Color>, b: Option<Color>) -> Option<Color> {
    match (a?, b?) {
        (Color::Rgb(r1, g1, b1), Color::Rgb(r2, g2, b2)) => {
            let rgb =
                |r: u8, g: u8, b: u8| (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b);
            Some(color(mix(rgb(r1, g1, b1), rgb(r2, g2, b2), 0.5)))
        }
        (a, _) => Some(a),
    }
}
fn color(rgb: u32) -> Color {
    Color::Rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::faces::{FaceSpec, Faces, PALETTE, ThemeSpec};
    #[test]
    fn the_selected_candidate_stands_from_its_list_in_every_theme() {
        let rgb = |color: Option<Color>| match color {
            Some(Color::Rgb(r, g, b)) => (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b),
            other => panic!("{other:?}"),
        };
        for builtin in crate::application::themes::BUILTINS {
            let theme = Theme::build(builtin.name, &Faces::default());
            let (row, list) = (rgb(theme.candidate_selected.bg), rgb(theme.float.bg));
            let apart = contrast(row, list);
            assert!(apart >= SELECTED_CONTRAST, "{}: {apart}", builtin.name);
        }
    }
    #[test]
    fn every_palette_name_has_a_color() {
        let mut palette = Palette::default();
        for name in PALETTE {
            assert!(palette.slot(name).is_some(), "{name}");
        }
    }
    #[test]
    fn a_defined_theme_goes_over_its_variant_and_under_faces() {
        let mut faces = Faces::default();
        let mut spec = ThemeSpec {
            base: "gruvbox-light".into(),
            ..Default::default()
        };
        spec.palette.insert("bg".into(), 0x101010);
        spec.faces
            .insert("title".into(), FaceSpec::parse("fg:#202020").unwrap());
        spec.faces
            .insert("key".into(), FaceSpec::parse("fg:#303030").unwrap());
        faces.define_theme("mine", spec).unwrap();
        faces
            .set("key", Some(FaceSpec::parse("fg:#404040").unwrap()))
            .unwrap();
        let theme = Theme::build("mine", &faces);
        assert_eq!(theme.text.bg, Some(color(0x101010)));
        assert_eq!(theme.text.fg, Some(color(0x3c3836)));
        // Gruvbox's own keyword color stays under the defined theme.
        assert_eq!(theme.category(Category::Keyword).fg, Some(color(0x9d0006)));
        assert_eq!(theme.title.fg, Some(color(0x202020)));
        assert_eq!(theme.key.fg, Some(color(0x404040)));
        // A theme no longer named gives the default.
        let theme = Theme::build("gone", &faces);
        assert_eq!(theme.text.bg, Some(color(0x1a1b26)));
    }
    #[test]
    fn refined_categories_inherit_their_parent_as_emacs_faces_do() {
        let mut faces = Faces::default();
        faces
            .set(
                "syntax.function",
                Some(FaceSpec::parse("fg:#111111").unwrap()),
            )
            .unwrap();
        faces
            .set(
                "syntax.function.definition",
                Some(FaceSpec::parse("bold").unwrap()),
            )
            .unwrap();
        let theme = Theme::build("tokyonight", &faces);
        let call = theme.category(Category::FunctionCall);
        let definition = theme.category(Category::FunctionDefinition);
        assert_eq!(call, theme.category(Category::Function));
        assert_eq!(definition.fg, Some(color(0x111111)));
        assert!(definition.add_modifier.contains(Modifier::BOLD));
        faces
            .set(
                "syntax.property",
                Some(FaceSpec::parse("fg:#222222").unwrap()),
            )
            .unwrap();
        let theme = Theme::build("tokyonight", &faces);
        assert_eq!(
            theme.category(Category::PropertyDefinition).fg,
            Some(color(0x222222))
        );
        // Variables stay plain by default.
        let theme = Theme::build("tokyonight", &Faces::default());
        assert_eq!(theme.category(Category::Variable), Style::new());
        assert_eq!(
            theme.category(Category::CommentDoc),
            theme.category(Category::Comment)
        );
    }
}
