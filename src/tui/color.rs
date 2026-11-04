//! Terminal colors. The theme is 24-bit; terminals that do not announce
//! truecolor get the nearest xterm 256-color index instead.
use ratatui::{buffer::Buffer, style::Color};

/// Whether `COLORTERM` announces 24-bit color.
pub(super) fn truecolor() -> bool {
    std::env::var("COLORTERM").is_ok_and(|value| matches!(value.as_str(), "truecolor" | "24bit"))
}
/// Replaces the 24-bit colors of a frame with xterm 256-color indices.
pub(super) fn downgrade(buffer: &mut Buffer) {
    let index = |color: &mut Color| {
        if let Color::Rgb(r, g, b) = *color {
            *color = Color::Indexed(xterm256(r, g, b));
        }
    };
    for cell in &mut buffer.content {
        index(&mut cell.fg);
        index(&mut cell.bg);
        index(&mut cell.underline_color);
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
