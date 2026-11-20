//! Face attributes shared by the screen and its renderers.

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum Color {
    #[default]
    Reset,
    Rgb(u8, u8, u8),
}

bitflags::bitflags! {
    #[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
    pub(crate) struct Modifier: u8 {
        const BOLD = 1 << 0;
        const DIM = 1 << 1;
        const ITALIC = 1 << 2;
        const UNDERLINED = 1 << 3;
        const REVERSED = 1 << 4;
        const CROSSED_OUT = 1 << 5;
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct Style {
    pub fg: Option<Color>,
    pub bg: Option<Color>,
    pub underline_color: Option<Color>,
    pub add_modifier: Modifier,
    pub sub_modifier: Modifier,
}

impl Style {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn fg(mut self, color: Color) -> Self {
        self.fg = Some(color);
        self
    }

    pub fn bg(mut self, color: Color) -> Self {
        self.bg = Some(color);
        self
    }

    pub fn underline_color(mut self, color: Color) -> Self {
        self.underline_color = Some(color);
        self
    }

    pub fn add_modifier(mut self, modifier: Modifier) -> Self {
        self.sub_modifier.remove(modifier);
        self.add_modifier.insert(modifier);
        self
    }

    pub fn remove_modifier(mut self, modifier: Modifier) -> Self {
        self.add_modifier.remove(modifier);
        self.sub_modifier.insert(modifier);
        self
    }

    /// Applies the fields and attribute changes specified by the overlay.
    pub fn patch(self, overlay: Self) -> Self {
        Self {
            fg: overlay.fg.or(self.fg),
            bg: overlay.bg.or(self.bg),
            underline_color: overlay.underline_color.or(self.underline_color),
            add_modifier: (self.add_modifier - overlay.sub_modifier) | overlay.add_modifier,
            sub_modifier: (self.sub_modifier - overlay.add_modifier) | overlay.sub_modifier,
        }
    }
}
