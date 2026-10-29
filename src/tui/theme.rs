//! The built-in color theme. Colors are 24-bit; terminals that do not
//! announce truecolor get the nearest xterm 256-color index instead. A light
//! variant is chosen when `COLORFGBG` reports a light background.
use ratatui::style::{Color, Modifier, Style};

pub(super) struct Theme {
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
    pub candidate_selected: Style,
    pub marker: Style,
    pub matched: Style,
    pub detail: Style,
    pub key: Style,
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
    on_accent: 0xe1e2e7,
};

impl Theme {
    pub fn detect() -> Self {
        let light = std::env::var("COLORFGBG")
            .ok()
            .and_then(|value| value.rsplit(';').next()?.parse::<u8>().ok())
            .is_some_and(|bg| bg == 7 || bg >= 9);
        let truecolor = std::env::var("COLORTERM")
            .is_ok_and(|value| matches!(value.as_str(), "truecolor" | "24bit"));
        Self::new(if light { &LIGHT } else { &DARK }, truecolor)
    }
    fn new(p: &Palette, truecolor: bool) -> Self {
        let c = |rgb: u32| color(rgb, truecolor);
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
            candidate_selected: Style::new().bg(c(p.bg_highlight)),
            marker: Style::new().fg(c(p.blue)),
            matched: Style::new().fg(c(p.orange)).add_modifier(Modifier::BOLD),
            detail: Style::new().fg(c(p.comment)),
            key: Style::new().fg(c(p.magenta)).add_modifier(Modifier::BOLD),
        }
    }
}

fn color(rgb: u32, truecolor: bool) -> Color {
    let (r, g, b) = ((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8);
    if truecolor {
        Color::Rgb(r, g, b)
    } else {
        Color::Indexed(xterm256(r, g, b))
    }
}
/// The nearest entry of the 6×6×6 cube or the gray ramp.
fn xterm256(r: u8, g: u8, b: u8) -> u8 {
    const LEVELS: [u8; 6] = [0, 95, 135, 175, 215, 255];
    let level = |v: u8| {
        (0..6)
            .min_by_key(|&i| (i32::from(LEVELS[i]) - i32::from(v)).abs())
            .unwrap()
    };
    let (ri, gi, bi) = (level(r), level(g), level(b));
    let cube = 16 + 36 * ri + 6 * gi + bi;
    let distance = |x: (u8, u8, u8)| {
        let d = |a: u8, b: u8| (i32::from(a) - i32::from(b)).pow(2);
        d(x.0, r) + d(x.1, g) + d(x.2, b)
    };
    let gray_index = ((i32::from(r) + i32::from(g) + i32::from(b)) / 3 - 8).clamp(0, 230) / 10;
    let gray = (8 + gray_index * 10) as u8;
    if distance((gray, gray, gray)) < distance((LEVELS[ri], LEVELS[gi], LEVELS[bi])) {
        232 + gray_index as u8
    } else {
        cube as u8
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn xterm256_picks_cube_and_gray_entries() {
        assert_eq!(super::xterm256(0, 0, 0), 16);
        assert_eq!(super::xterm256(255, 255, 255), 231);
        assert_eq!(super::xterm256(0x80, 0x80, 0x80), 244);
        assert_eq!(super::xterm256(0xff, 0, 0), 196);
    }
}
