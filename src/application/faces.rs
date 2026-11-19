//! Face overrides: the colors and attributes configuration gives a named
//! part of the screen, over the built-in theme. `face NAME SPEC` and
//! `soda.face` set them; the frontend lays them over its theme.
//!
//! A spec is words: `fg:#rrggbb`, `bg:#rrggbb` (or `default`, the
//! terminal's own), and attributes `bold`, `italic`, `underline`, `dim`,
//! `reverse`, `strikethrough`. Colors left out keep the theme's; attributes, once any is
//! given, replace the theme's, and `plain` gives none.
//!
//! Themes are named too: the built-in ones of `themes`, and those
//! `soda.theme` defines over one of them with palette colors and faces.
//! The `theme` option picks one; faces set with `face` go over it.
use super::themes;
use std::collections::BTreeMap;
/// Colors of a built-in theme's palette, which the faces are made from.
pub const PALETTE: &[&str] = &[
    "bg",
    "bg-dark",
    "bg-highlight",
    "selection",
    "fg",
    "fg-dark",
    "comment",
    "gutter",
    "gutter-current",
    "blue",
    "green",
    "magenta",
    "orange",
    "yellow",
    "red",
    "cyan",
    "teal",
    "on-accent",
];

// A built-in role declares its name, theme slot, and help together.
macro_rules! ui_faces {
    ($emit:ident $(, $theme:ident)?) => {
        $emit! {
            $($theme;)?
            ("text", text, "Text, and the background of the editing area"),
            ("dim", dim, "Text that matters less, such as the empty-buffer page"),
            ("gutter", gutter, "Line numbers"),
            ("gutter-current", gutter_current, "The caret line's number"),
            ("cursor-line", cursor_line, "The caret line"),
            ("selection", selection, "Selected text"),
            ("secondary-selection", secondary_selection, "The grab, as Emacs's secondary selection"),
            ("beacon-selection", beacon_selection, "Beacon's other selections; unset, a mix of selection and secondary-selection"),
            ("beacon-cursor", beacon_cursor, "Beacon's other carets; unset, a mix of mode-beacon and secondary-selection"),
            ("status", status, "The status line"),
            ("status-strong", status_strong, "The path on the status line"),
            ("modified", modified, "Unsaved markers"),
            ("error", error, "Errors"),
            ("mode-normal", mode_normal, "The NORMAL badge"),
            ("mode-insert", mode_insert, "The INSERT badge"),
            ("mode-beacon", mode_visual, "The BEACON badge"),
            ("mode-prompt", mode_prompt, "Badges of prompts and other layers"),
            ("tabs", tabs, "The tab row"),
            ("tab-active", tab_active, "The current document's tab"),
            ("border", border, "Separators between windows"),
            ("paren-match", paren_match, "The bracket at the caret and the one that matches it, as show-paren-mode"),
            ("inactive-window", inactive_window, "Windows other than the focused one; their background, bg:default to leave them as it"),
            ("title", title, "Window titles"),
            ("panel", panel, "Help and lists"),
            ("float", float, "Floating boxes such as hover"),
            ("float-border", float_border, "Their borders"),
            ("candidate-selected", candidate_selected, "The selected candidate"),
            ("marker", marker, "Line markers in the gutter"),
            ("inlay", inlay, "Inlay hints"),
            ("reference", reference, "Other places of the symbol at the caret"),
            ("reference-write", reference_write, "Places where the symbol at the caret is written"),
            ("snippet", snippet, "Other places of the snippet being filled in, and copies"),
            ("unnecessary", unnecessary, "Code a language server finds unused"),
            ("deprecated", deprecated, "Uses of what a language server finds deprecated"),
            ("note-error", notes[2], "Error notes after the text of their line"),
            ("note-warning", notes[1], "Warning notes after the text of their line"),
            ("note-info", notes[0], "Other notes after the text of their line"),
            ("status-error", status_error, "Error counts on the status line"),
            ("status-warning", status_warning, "Warning counts on the status line"),
            ("info", info, "Information"),
            ("matched", matched, "Matched characters of candidates"),
            ("detail", detail, "Candidate details"),
            ("whitespace", whitespace, "Tab and trailing space marks"),
            ("ruler", ruler, "The ruler column"),
            ("scrollbar", scrollbar, "The scroll bar of the graphical frontend; its background colors the thumb"),
            ("key", key, "Keys in hints"),
            ("label", label, "Jump labels"),
            ("flash-match", flash_match, "What flash's search matches"),
            ("flash-current", flash_current, "The match RET goes to in flash's search"),
            ("flash-backdrop", flash_backdrop, "Text of the windows flash searches, while it does; see the flash-backdrop option"),
            ("todo", todo, "The todo highlight"),
            ("expand-digit", digit, "Digits that extend the selection"),
            ("mark1", marks[0], "First mark background"),
            ("mark2", marks[1], "Second mark background"),
            ("mark3", marks[2], "Third mark background"),
            ("mark4", marks[3], "Fourth mark background"),
            ("mark5", marks[4], "Fifth mark background"),
            ("mark6", marks[5], "Sixth mark background"),
            ("mark7", marks[6], "Seventh mark background"),
            ("mark8", marks[7], "Eighth mark background"),
        }
    };
}
pub(crate) use ui_faces;

macro_rules! face_names {
    ($(($name:literal, $slot:ident $([$index:literal])?, $doc:literal),)*) => {
        /// Faces of the screen, besides the syntax categories.
        pub const UI_FACES: &[(&str, &str)] = &[$(($name, $doc)),*];
    };
}
ui_faces!(face_names);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Color {
    Rgb(u32),
    /// The terminal's own color.
    Default,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Attributes {
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub dim: bool,
    pub reverse: bool,
    pub strikethrough: bool,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct FaceSpec {
    pub fg: Option<Color>,
    pub bg: Option<Color>,
    /// None keeps the theme's attributes.
    pub attributes: Option<Attributes>,
}

/// Whether a face of this name exists.
pub fn known(name: &str) -> bool {
    UI_FACES.iter().any(|(face, _)| *face == name)
        || name.strip_prefix("syntax.").is_some_and(|category| {
            crate::syntax::Category::ALL
                .iter()
                .any(|c| c.name() == category)
        })
}
/// Every face name, the screen's first.
pub fn names() -> impl Iterator<Item = String> {
    UI_FACES.iter().map(|(name, _)| (*name).to_owned()).chain(
        crate::syntax::Category::ALL
            .iter()
            .map(|c| format!("syntax.{}", c.name())),
    )
}
/// A built-in face's place among `names`.
pub fn index(name: &str) -> Option<u16> {
    if let Some(category) = name.strip_prefix("syntax.") {
        return crate::syntax::Category::ALL
            .iter()
            .position(|known| known.name() == category)
            .map(|index| (UI_FACES.len() + index) as u16);
    }
    UI_FACES
        .iter()
        .position(|(known, _)| *known == name)
        .map(|index| index as u16)
}
const BUILTIN_COUNT: usize = UI_FACES.len() + crate::syntax::Category::ALL.len();
/// A theme an extension defines: a built-in theme under it, palette
/// colors that replace that theme's, and faces over what they make.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThemeSpec {
    /// The name of a built-in theme.
    pub base: String,
    pub palette: BTreeMap<String, u32>,
    pub faces: BTreeMap<String, FaceSpec>,
}
impl Default for ThemeSpec {
    fn default() -> Self {
        Self {
            base: themes::DEFAULT.into(),
            palette: BTreeMap::new(),
            faces: BTreeMap::new(),
        }
    }
}
impl ThemeSpec {
    /// Checks its base and the names of its palette colors and faces.
    fn check(&self, faces: &Faces) -> Result<(), String> {
        if themes::builtin(&self.base).is_none() {
            return Err(format!("base {} is not a built-in theme", self.base));
        }
        if let Some(name) = self
            .palette
            .keys()
            .find(|name| !PALETTE.contains(&name.as_str()))
        {
            return Err(format!(
                "unknown palette color {name}; use {}",
                PALETTE.join(", ")
            ));
        }
        if let Some(name) = self.faces.keys().find(|name| faces.index(name).is_none()) {
            return Err(format!("unknown face {name}"));
        }
        Ok(())
    }
}
/// A palette color: `#rrggbb`.
pub fn rgb(text: &str) -> Result<u32, String> {
    match color(text)? {
        Color::Rgb(rgb) => Ok(rgb),
        Color::Default => Err("a palette color is #rrggbb".into()),
    }
}
fn color(text: &str) -> Result<Color, String> {
    if text == "default" {
        return Ok(Color::Default);
    }
    text.strip_prefix('#')
        .filter(|hex| hex.len() == 6)
        .and_then(|hex| u32::from_str_radix(hex, 16).ok())
        .map(Color::Rgb)
        .ok_or_else(|| format!("{text} is not a color; use #rrggbb or default"))
}
impl FaceSpec {
    pub fn parse(spec: &str) -> Result<Self, String> {
        let mut face = Self::default();
        for word in spec.split_whitespace() {
            if let Some(fg) = word.strip_prefix("fg:") {
                face.fg = Some(color(fg)?);
                continue;
            }
            if let Some(bg) = word.strip_prefix("bg:") {
                face.bg = Some(color(bg)?);
                continue;
            }
            let attributes = face.attributes.get_or_insert_default();
            match word {
                "bold" => attributes.bold = true,
                "italic" => attributes.italic = true,
                "underline" => attributes.underline = true,
                "dim" => attributes.dim = true,
                "reverse" => attributes.reverse = true,
                "strikethrough" => attributes.strikethrough = true,
                "plain" => {}
                word => return Err(format!("unknown face attribute {word}")),
            }
        }
        if face == Self::default() {
            return Err("a face needs a color or an attribute".into());
        }
        Ok(face)
    }
}

/// The overrides in force, the themes defined, and a revision that
/// changes with either.
#[derive(Debug, Default)]
pub struct Faces {
    specs: BTreeMap<String, FaceSpec>,
    custom: Vec<(String, FaceSpec)>,
    themes: BTreeMap<String, ThemeSpec>,
    revision: u64,
}
impl Faces {
    /// Defines an extension face. Redefinition preserves its ID and overrides.
    pub fn define(&mut self, name: String, spec: FaceSpec) -> Result<(), String> {
        if !name.contains('.')
            || name.starts_with("syntax.")
            || known(&name)
            || name.split('.').any(|part| {
                part.is_empty()
                    || !part
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            })
        {
            return Err(format!(
                "invalid extension face name {name}: use a qualified name such as plugin.label"
            ));
        }
        if let Some((_, default)) = self.custom.iter_mut().find(|(key, _)| key == &name) {
            *default = spec;
        } else {
            if u16::try_from(BUILTIN_COUNT + self.custom.len()).is_err() {
                return Err("too many named faces".into());
            }
            self.custom.push((name, spec));
        }
        self.revision += 1;
        Ok(())
    }
    pub fn index(&self, name: &str) -> Option<u16> {
        index(name).or_else(|| {
            self.custom
                .iter()
                .position(|(key, _)| key == name)
                .map(|i| (BUILTIN_COUNT + i) as u16)
        })
    }
    pub fn resolve(&self, name: &str) -> Option<super::Face> {
        super::Face::legacy(name).or_else(|| self.index(name).map(super::Face::Named))
    }
    pub fn names(&self) -> impl Iterator<Item = String> + '_ {
        names().chain(self.custom.iter().map(|(name, _)| name.clone()))
    }
    pub fn custom(&self) -> impl Iterator<Item = (&str, &FaceSpec)> {
        self.custom.iter().map(|(name, spec)| (name.as_str(), spec))
    }

    /// Defines a theme, or replaces one defined before; the built-in
    /// names cannot be taken.
    pub fn define_theme(&mut self, name: &str, spec: ThemeSpec) -> Result<(), String> {
        if name.is_empty()
            || !name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            return Err(format!(
                "{name:?} is not a theme name: use letters, digits, - and _"
            ));
        }
        if themes::builtin(name).is_some() {
            return Err(format!("{name} is a built-in theme"));
        }
        spec.check(self)?;
        self.themes.insert(name.to_owned(), spec);
        self.revision += 1;
        Ok(())
    }
    /// A theme an extension defined.
    pub fn theme(&self, name: &str) -> Option<&ThemeSpec> {
        self.themes.get(name)
    }
    /// Whether the `theme` option may name this.
    pub fn has_theme(&self, name: &str) -> bool {
        themes::builtin(name).is_some() || self.themes.contains_key(name)
    }
    /// Every theme name, the built-in ones first.
    pub fn theme_names(&self) -> impl Iterator<Item = &str> {
        (themes::BUILTINS.iter().map(|theme| theme.name))
            .chain(self.themes.keys().map(String::as_str))
    }
    /// Sets a face, or with `None` gives it back to the theme.
    pub fn set(&mut self, name: &str, spec: Option<FaceSpec>) -> Result<(), String> {
        if self.index(name).is_none() {
            return Err(format!("unknown face {name}"));
        }
        match spec {
            Some(spec) => self.specs.insert(name.to_owned(), spec),
            None => self.specs.remove(name),
        };
        self.revision += 1;
        Ok(())
    }
    pub fn get(&self, name: &str) -> Option<&FaceSpec> {
        self.specs.get(name)
    }
    pub fn iter(&self) -> impl Iterator<Item = (&str, &FaceSpec)> {
        self.specs.iter().map(|(name, spec)| (name.as_str(), spec))
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn specs_read_colors_and_attributes() {
        let spec = FaceSpec::parse("fg:#c0caf5 bg:default bold italic").unwrap();
        assert_eq!(spec.fg, Some(Color::Rgb(0xc0caf5)));
        assert_eq!(spec.bg, Some(Color::Default));
        let attributes = spec.attributes.unwrap();
        assert!(attributes.bold && attributes.italic && !attributes.underline);
        assert_eq!(
            FaceSpec::parse("plain").unwrap().attributes,
            Some(Attributes::default())
        );
        assert!(FaceSpec::parse("fg:red").is_err());
        assert!(FaceSpec::parse("").is_err());
        assert!(known("syntax.keyword") && known("mode-normal") && !known("syntax.nope"));
    }
    #[test]
    fn themes_take_known_names_only() {
        let mut faces = Faces::default();
        let mut spec = ThemeSpec::default();
        spec.palette.insert("bg".into(), 0x282828);
        spec.faces
            .insert("syntax.keyword".into(), FaceSpec::parse("bold").unwrap());
        faces.define_theme("mine", spec.clone()).unwrap();
        assert!(faces.has_theme("mine") && !faces.has_theme("auto") && !faces.has_theme("x"));
        assert!(faces.has_theme("gruvbox-dark"));
        assert!(faces.define_theme("tokyonight", spec.clone()).is_err());
        assert!(faces.define_theme("nord", spec.clone()).is_err());
        assert!(faces.define_theme("a b", spec.clone()).is_err());
        spec.palette.insert("purple".into(), 0);
        assert!(faces.define_theme("other", spec).is_err());
        let names: Vec<_> = faces.theme_names().collect();
        assert_eq!(names[..2], ["tokyonight", "tokyonight-day"]);
        assert_eq!(names.last(), Some(&"mine"));
        let based = ThemeSpec {
            base: "nope".into(),
            ..Default::default()
        };
        assert!(faces.define_theme("based", based).is_err());
    }
}
