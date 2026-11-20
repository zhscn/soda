//! Converts shared face attributes at the terminal drawing boundary.
use crate::screen::{Color, Modifier, Style};
use ratatui::style as terminal;

impl From<Color> for terminal::Color {
    fn from(color: Color) -> Self {
        match color {
            Color::Reset => Self::Reset,
            Color::Rgb(r, g, b) => Self::Rgb(r, g, b),
        }
    }
}

impl From<Modifier> for terminal::Modifier {
    fn from(modifier: Modifier) -> Self {
        let mut result = Self::empty();
        for (face, terminal) in [
            (Modifier::BOLD, Self::BOLD),
            (Modifier::DIM, Self::DIM),
            (Modifier::ITALIC, Self::ITALIC),
            (Modifier::UNDERLINED, Self::UNDERLINED),
            (Modifier::REVERSED, Self::REVERSED),
            (Modifier::CROSSED_OUT, Self::CROSSED_OUT),
        ] {
            result.set(terminal, modifier.contains(face));
        }
        result
    }
}

impl From<Style> for terminal::Style {
    fn from(style: Style) -> Self {
        Self {
            fg: style.fg.map(Into::into),
            bg: style.bg.map(Into::into),
            underline_color: style.underline_color.map(Into::into),
            add_modifier: style.add_modifier.into(),
            sub_modifier: style.sub_modifier.into(),
        }
    }
}
