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

/// Faces of the screen, besides `syntax.CATEGORY` for each syntax category.
pub const UI_FACES: &[(&str, &str)] = &[
    ("text", "Text, and the background of the editing area"),
    (
        "dim",
        "Text that matters less, such as the empty-buffer page",
    ),
    ("gutter", "Line numbers"),
    ("gutter-current", "The caret line's number"),
    ("cursor-line", "The caret line"),
    ("selection", "Selected text"),
    ("status", "The status line"),
    ("status-strong", "The path on the status line"),
    ("modified", "Unsaved markers"),
    ("error", "Errors"),
    ("mode-normal", "The NORMAL badge"),
    ("mode-insert", "The INSERT badge"),
    ("mode-beacon", "The BEACON badge"),
    ("mode-prompt", "Badges of prompts and other layers"),
    ("tabs", "The tab row"),
    ("tab-active", "The current document's tab"),
    ("border", "Separators between windows"),
    ("title", "Window titles"),
    ("panel", "Help and lists"),
    ("float", "Floating boxes such as hover"),
    ("float-border", "Their borders"),
    ("candidate-selected", "The selected candidate"),
    ("marker", "Line markers in the gutter"),
    ("inlay", "Inlay hints"),
    ("reference", "Other places of the symbol at the caret"),
    (
        "reference-write",
        "Places where the symbol at the caret is written",
    ),
    (
        "snippet",
        "Other places of the snippet being filled in, and copies",
    ),
    ("unnecessary", "Code a language server finds unused"),
    (
        "deprecated",
        "Uses of what a language server finds deprecated",
    ),
    ("note-error", "Error notes after the text of their line"),
    ("note-warning", "Warning notes after the text of their line"),
    ("note-info", "Other notes after the text of their line"),
    ("status-error", "Error counts on the status line"),
    ("status-warning", "Warning counts on the status line"),
    ("info", "Information"),
    ("matched", "Matched characters of candidates"),
    ("detail", "Candidate details"),
    ("whitespace", "Tab and trailing space marks"),
    ("ruler", "The ruler column"),
    (
        "scrollbar",
        "The scroll bar of the graphical frontend; its background colors the thumb",
    ),
    ("key", "Keys in hints"),
    ("label", "Jump labels"),
    ("todo", "The todo highlight"),
    ("mark1", "First mark background"),
    ("mark2", "Second mark background"),
    ("mark3", "Third mark background"),
    ("mark4", "Fourth mark background"),
    ("mark5", "Fifth mark background"),
    ("mark6", "Sixth mark background"),
    ("mark7", "Seventh mark background"),
    ("mark8", "Eighth mark background"),
];

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
/// A face's place among `names`, which `Face::Named` holds.
pub fn index(name: &str) -> Option<u16> {
    names().position(|known| known == name).map(|i| i as u16)
}
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
            base: "dark".into(),
            palette: BTreeMap::new(),
            faces: BTreeMap::new(),
        }
    }
}
impl ThemeSpec {
    /// Checks its base and the names of its palette colors and faces.
    pub fn check(&self) -> Result<(), String> {
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
        if let Some(name) = self.faces.keys().find(|name| !known(name)) {
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
    themes: BTreeMap<String, ThemeSpec>,
    revision: u64,
}
impl Faces {
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
        if name == themes::AUTO || themes::builtin(name).is_some() {
            return Err(format!("{name} is a built-in theme"));
        }
        spec.check()?;
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
        name == themes::AUTO || themes::builtin(name).is_some() || self.themes.contains_key(name)
    }
    /// Every theme name, the built-in ones first.
    pub fn theme_names(&self) -> impl Iterator<Item = &str> {
        std::iter::once(themes::AUTO)
            .chain(themes::BUILTINS.iter().map(|theme| theme.name))
            .chain(self.themes.keys().map(String::as_str))
    }
    /// Sets a face, or with `None` gives it back to the theme.
    pub fn set(&mut self, name: &str, spec: Option<FaceSpec>) -> Result<(), String> {
        if !known(name) {
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
        assert!(faces.has_theme("mine") && faces.has_theme("auto") && !faces.has_theme("x"));
        assert!(faces.has_theme("gruvbox-dark"));
        assert!(faces.define_theme("dark", spec.clone()).is_err());
        assert!(faces.define_theme("nord", spec.clone()).is_err());
        assert!(faces.define_theme("a b", spec.clone()).is_err());
        spec.palette.insert("purple".into(), 0);
        assert!(faces.define_theme("other", spec).is_err());
        let names: Vec<_> = faces.theme_names().collect();
        assert_eq!(names[..3], ["auto", "dark", "light"]);
        assert_eq!(names.last(), Some(&"mine"));
        let based = ThemeSpec {
            base: "nope".into(),
            ..Default::default()
        };
        assert!(faces.define_theme("based", based).is_err());
    }
}
