//! Face overrides: the colors and attributes configuration gives a named
//! part of the screen, over the built-in theme. `face NAME SPEC` and
//! `soda.face` set them; the frontend lays them over its theme.
//!
//! A spec is words: `fg:#rrggbb`, `bg:#rrggbb` (or `default`, the
//! terminal's own), and attributes `bold`, `italic`, `underline`, `dim`,
//! `reverse`. Colors left out keep the theme's; attributes, once any is
//! given, replace the theme's, and `plain` gives none.
use std::collections::BTreeMap;

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
    ("status-error", "Error counts on the status line"),
    ("status-warning", "Warning counts on the status line"),
    ("info", "Information"),
    ("matched", "Matched characters of candidates"),
    ("detail", "Candidate details"),
    ("whitespace", "Tab and trailing space marks"),
    ("ruler", "The ruler column"),
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

/// The overrides in force, and a revision that changes with them.
#[derive(Debug, Default)]
pub struct Faces {
    specs: BTreeMap<String, FaceSpec>,
    revision: u64,
}
impl Faces {
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
}
