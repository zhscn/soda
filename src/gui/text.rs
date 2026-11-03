//! Fonts of the graphical frontend: shaping runs of text, measuring them
//! for the layout, and rasterizing glyphs into the atlas.
//!
//! The text font is monospace and laid out on a grid, as in a terminal or
//! Emacs: a cluster is as many columns wide as the core counts, and glyphs
//! of fallback fonts are fitted to whole columns, wide ones centered in
//! theirs. Hints use a smaller font and are as wide as their glyphs.
//!
//! Fonts are the ones fontconfig picks, as for the rest of the desktop: the
//! `monospace` family, and for Chinese, Japanese and Korean the monospace
//! font of the language. Without fontconfig, as on macOS, the platform's
//! defaults stand.
use super::render::{Atlas, COLOR, Instance, MASK};
use crate::screen::{Cells, Font, Measure};
use cosmic_text::{
    Attrs, Buffer, CacheKey, Fallback, Family, FontSystem, LayoutGlyph, Metrics, PlatformFallback,
    Shaping, Style, SwashCache, SwashContent, Weight,
};
use std::{collections::HashMap, rc::Rc};
use unicode_script::Script;

/// Measured units in a pixel; the layout counts in fractions of a pixel.
pub const UNIT: f32 = 64.0;

/// A font of the frontend: text or hints, plain, bold or italic.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct Face {
    pub hint: bool,
    pub bold: bool,
    pub italic: bool,
}
impl Face {
    pub const TEXT: Self = Self {
        hint: false,
        bold: false,
        italic: false,
    };
    pub const HINT: Self = Self {
        hint: true,
        bold: false,
        italic: false,
    };
}

/// Where a glyph image went in the atlas, and how it sits on the pen.
#[derive(Clone, Copy)]
struct Placed {
    uv: [f32; 4],
    left: f32,
    top: f32,
    width: f32,
    height: f32,
    color: bool,
}

/// The first family fontconfig matches a pattern with.
fn fontconfig(pattern: &str) -> Option<String> {
    let output = std::process::Command::new("fc-match")
        .args([pattern, "family"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    let families = String::from_utf8(output.stdout).ok()?;
    let family = families.lines().next()?.split(',').next()?.trim();
    (!family.is_empty()).then(|| family.to_owned())
}
/// The language of the environment, as `en-US`.
fn locale() -> String {
    ["LC_ALL", "LC_CTYPE", "LANG"]
        .iter()
        .filter_map(|name| std::env::var(name).ok())
        .find(|value| !value.is_empty())
        .map(|value| {
            value
                .split(['.', '@'])
                .next()
                .unwrap_or("")
                .replace('_', "-")
        })
        .filter(|value| !value.is_empty() && value != "C" && value != "POSIX")
        .unwrap_or_else(|| "en-US".into())
}
/// The platform's fallback fonts, with fontconfig's choice first for Han
/// and the scripts that share its punctuation. Japanese and Korean text
/// asks for their own; otherwise Chinese of the environment's language,
/// simplified when it is not Chinese.
struct Fallbacks {
    han: Vec<&'static str>,
    kana: Vec<&'static str>,
    hangul: Vec<&'static str>,
}
impl Fallbacks {
    fn new(locale: &str) -> Self {
        let platform = PlatformFallback;
        let chinese = match locale {
            "zh-TW" | "zh-HK" | "zh-MO" => locale.to_lowercase(),
            _ => "zh-cn".into(),
        };
        let list = |lang: &str, script: Script, locale: &str| {
            let mut fonts: Vec<&'static str> = vec![];
            if let Some(family) = fontconfig(&format!("monospace:lang={lang}")) {
                fonts.push(Box::leak(family.into_boxed_str()));
            }
            fonts.extend(platform.script_fallback(script, locale));
            fonts
        };
        Self {
            han: list(&chinese, Script::Han, locale),
            kana: list("ja", Script::Hiragana, locale),
            hangul: list("ko", Script::Hangul, locale),
        }
    }
}
impl Fallback for Fallbacks {
    fn common_fallback(&self) -> &[&'static str] {
        PlatformFallback.common_fallback()
    }
    fn forbidden_fallback(&self) -> &[&'static str] {
        PlatformFallback.forbidden_fallback()
    }
    fn script_fallback(&self, script: Script, locale: &str) -> &[&'static str] {
        match script {
            Script::Han | Script::Bopomofo => &self.han,
            Script::Hiragana | Script::Katakana => &self.kana,
            Script::Hangul => &self.hangul,
            _ => PlatformFallback.script_fallback(script, locale),
        }
    }
}

pub struct Fonts {
    system: FontSystem,
    /// The text font; the generic family would let any monospace font with
    /// a character stand in for it, not the one fontconfig prefers.
    family: Option<String>,
    swash: SwashCache,
    /// The text font's size and a column's width, in pixels.
    pub size: f32,
    pub cell: f32,
    /// A row's height, and its baseline from the row's top.
    pub line: f32,
    pub baseline: f32,
    hint_size: f32,
    shaped: HashMap<(String, Face), Rc<[LayoutGlyph]>>,
    placed: HashMap<CacheKey, Option<Placed>>,
}
impl Fonts {
    pub fn new(size: f32) -> Self {
        let locale = locale();
        let mut db = cosmic_text::fontdb::Database::new();
        db.load_system_fonts();
        db.set_monospace_family("Noto Sans Mono");
        let fallbacks = Fallbacks::new(&locale);
        let mut fonts = Self {
            system: FontSystem::new_with_locale_and_db_and_fallback(locale, db, fallbacks),
            family: fontconfig("monospace"),
            swash: SwashCache::new(),
            size: 0.0,
            cell: 0.0,
            line: 0.0,
            baseline: 0.0,
            hint_size: 0.0,
            shaped: HashMap::new(),
            placed: HashMap::new(),
        };
        fonts.resize(size);
        fonts
    }
    /// Sets the text size in pixels, and measures the grid again.
    pub fn resize(&mut self, size: f32) {
        if size == self.size {
            return;
        }
        self.size = size;
        self.hint_size = (size * 0.86).round();
        self.line = (size * 1.35).round();
        self.shaped.clear();
        self.placed.clear();
        self.cell = 0.0;
        // A column is as wide as a digit of the text font.
        self.cell = self
            .shape("0", Face::TEXT)
            .first()
            .map_or(size * 0.6, |glyph| glyph.w);
        self.shaped.clear();
        let mut buffer = Buffer::new(&mut self.system, Metrics::new(size, self.line));
        let attrs = Attrs::new().family(self.family());
        buffer.set_text("0", &attrs, Shaping::Advanced, None);
        buffer.shape_until_scroll(&mut self.system, false);
        self.baseline = buffer
            .layout_runs()
            .next()
            .map_or(size, |run| run.line_y)
            .round();
    }
    fn family(&self) -> Family<'_> {
        match &self.family {
            Some(name) => Family::Name(name),
            None => Family::Monospace,
        }
    }
    /// A column's width in measured units.
    pub fn column(&self) -> usize {
        (self.cell * UNIT).round() as usize
    }
    /// The glyphs of a run of text in a face, from the run's start.
    pub fn shape(&mut self, text: &str, face: Face) -> Rc<[LayoutGlyph]> {
        if let Some(glyphs) = self.shaped.get(&(text.to_owned(), face)) {
            return glyphs.clone();
        }
        let size = if face.hint { self.hint_size } else { self.size };
        let mut buffer = Buffer::new(&mut self.system, Metrics::new(size, self.line));
        buffer.set_size(None, None);
        if !face.hint && self.cell > 0.0 {
            buffer.set_monospace_width(Some(self.cell));
        }
        let attrs = Attrs::new()
            .family(self.family())
            .weight(if face.bold {
                Weight::BOLD
            } else {
                Weight::NORMAL
            })
            .style(if face.italic {
                Style::Italic
            } else {
                Style::Normal
            });
        buffer.set_text(text, &attrs, Shaping::Advanced, None);
        buffer.shape_until_scroll(&mut self.system, false);
        let glyphs: Rc<[LayoutGlyph]> = buffer
            .layout_runs()
            .flat_map(|run| run.glyphs.iter().cloned())
            .collect();
        // Text drawn on screen repeats from frame to frame; a cache that
        // grows past what a screen shows starts again.
        if self.shaped.len() > 20_000 {
            self.shaped.clear();
        }
        self.shaped.insert((text.to_owned(), face), glyphs.clone());
        glyphs
    }
    /// How wide a run is in pixels: whole columns for text, its glyphs for
    /// hints.
    pub fn width(&mut self, text: &str, face: Face) -> f32 {
        if face.hint {
            self.shape(text, face).iter().map(|glyph| glyph.w).sum()
        } else {
            Cells.width(text, Font::Text) as f32 * self.cell
        }
    }
    /// Draws a run of text with its pen starting at `x` on the baseline
    /// `y`. Text glyphs go to their columns; hint glyphs where they shape.
    #[allow(clippy::too_many_arguments)]
    pub fn draw(
        &mut self,
        atlas: &mut Atlas,
        out: &mut Vec<Instance>,
        x: f32,
        y: f32,
        text: &str,
        face: Face,
        color: [f32; 4],
    ) {
        let glyphs = self.shape(text, face);
        // The column each cluster starts at, and where its first glyph
        // shaped, so that glyphs keep their offsets within a cluster.
        let mut cluster = (usize::MAX, 0.0, 0.0);
        for (index, glyph) in glyphs.iter().enumerate() {
            if glyph.start != cluster.0 {
                let column = if face.hint {
                    glyph.x
                } else {
                    // A glyph narrower than its columns, as a Chinese
                    // character is in two, is centered in them.
                    let cells = Cells.width(&text[glyph.start..glyph.end], Font::Text);
                    let room = cells as f32 * self.cell;
                    let inked: f32 = glyphs[index..]
                        .iter()
                        .take_while(|g| g.start == glyph.start)
                        .map(|g| g.w)
                        .sum();
                    let inset = if cells > 1 && inked < room {
                        ((room - inked) / 2.0).round()
                    } else {
                        0.0
                    };
                    Cells.width(&text[..glyph.start], Font::Text) as f32 * self.cell + inset
                };
                cluster = (glyph.start, column, glyph.x);
            }
            // `physical` adds the glyph's own place in the run, so the pen
            // goes back by where its cluster shaped.
            let physical = glyph.physical((x + cluster.1 - cluster.2, y), 1.0);
            let Some(placed) = self.place(atlas, physical.cache_key) else {
                continue;
            };
            out.push(Instance {
                rect: [
                    physical.x as f32 + placed.left,
                    physical.y as f32 - placed.top,
                    placed.width,
                    placed.height,
                ],
                uv: placed.uv,
                color,
                params: [if placed.color { COLOR } else { MASK }, 0.0, 0.0, 0.0],
            });
        }
    }
    /// The glyph's image in the atlas, rasterized the first time; none for
    /// glyphs without ink.
    fn place(&mut self, atlas: &mut Atlas, key: CacheKey) -> Option<Placed> {
        if let Some(placed) = self.placed.get(&key) {
            return *placed;
        }
        let image = self.swash.get_image_uncached(&mut self.system, key)?;
        let (width, height) = (image.placement.width, image.placement.height);
        let placed = if width == 0 || height == 0 {
            None
        } else {
            let (rgba, color) = match image.content {
                SwashContent::Mask => (
                    image
                        .data
                        .iter()
                        .flat_map(|a| [255, 255, 255, *a])
                        .collect(),
                    false,
                ),
                SwashContent::SubpixelMask => (
                    image
                        .data
                        .chunks(4)
                        .flat_map(|p| [255, 255, 255, p[0].max(p[1]).max(p[2])])
                        .collect(),
                    false,
                ),
                SwashContent::Color => (image.data.clone(), true),
            };
            let at = match atlas.place(width, height, rgba.clone()) {
                Some(at) => at,
                None => {
                    // Full: start again. Glyphs of this frame placed before
                    // may show wrong until the next, which `cleared` asks for.
                    atlas.clear();
                    self.placed.clear();
                    atlas.place(width, height, rgba)?
                }
            };
            let size = atlas.size as f32;
            Some(Placed {
                uv: [
                    at[0] as f32 / size,
                    at[1] as f32 / size,
                    (at[0] + width) as f32 / size,
                    (at[1] + height) as f32 / size,
                ],
                left: image.placement.left as f32,
                top: image.placement.top as f32,
                width: width as f32,
                height: height as f32,
                color,
            })
        };
        self.placed.insert(key, placed);
        placed
    }
}

/// The layout's measure: whole columns for text, glyph widths for hints.
pub struct Measured<'a> {
    pub fonts: std::cell::RefCell<&'a mut Fonts>,
    pub column: usize,
}
impl<'a> Measured<'a> {
    pub fn new(fonts: &'a mut Fonts) -> Self {
        let column = fonts.column();
        Self {
            fonts: std::cell::RefCell::new(fonts),
            column,
        }
    }
}
impl Measure for Measured<'_> {
    fn width(&self, cluster: &str, font: Font) -> usize {
        match font {
            Font::Text => Cells.width(cluster, font) * self.column,
            Font::Hint => {
                let width = self.fonts.borrow_mut().width(cluster, Face::HINT);
                (width * UNIT).round() as usize
            }
        }
    }
    fn column(&self) -> usize {
        self.column
    }
    fn ascii(&self) -> Option<usize> {
        Some(self.column)
    }
}
