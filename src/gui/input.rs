//! Converts window system keys to the frontend-independent vocabulary, the
//! same strokes the terminal reports: a shifted character with Shift set,
//! and Shift-Tab as BackTab.
use crate::interaction::{Key, KeyStroke};
use winit::{
    event::{ElementState, KeyEvent},
    keyboard::{Key as Logical, ModifiersState, NamedKey},
    platform::modifier_supplement::KeyEventExtModifierSupplement,
};

/// The stroke a key press stands for; none for releases, lone modifiers
/// and dead keys.
pub fn stroke(event: &KeyEvent, modifiers: ModifiersState) -> Option<KeyStroke> {
    if event.state == ElementState::Released {
        return None;
    }
    let (control, alt, shift) = (
        modifiers.control_key(),
        modifiers.alt_key(),
        modifiers.shift_key(),
    );
    let code = match &event.logical_key {
        Logical::Named(named) => match named {
            NamedKey::Enter => Key::Enter,
            NamedKey::Escape => Key::Esc,
            NamedKey::Backspace => Key::Backspace,
            NamedKey::Delete => Key::Delete,
            NamedKey::Tab if shift => Key::BackTab,
            NamedKey::Tab => Key::Tab,
            NamedKey::ArrowLeft => Key::Left,
            NamedKey::ArrowRight => Key::Right,
            NamedKey::ArrowUp => Key::Up,
            NamedKey::ArrowDown => Key::Down,
            NamedKey::Home => Key::Home,
            NamedKey::End => Key::End,
            NamedKey::PageUp => Key::PageUp,
            NamedKey::PageDown => Key::PageDown,
            NamedKey::Space => Key::Char(' '),
            named => Key::F(function(*named)?),
        },
        Logical::Character(_) => {
            // With Control or Alt the layout may give a control character
            // or, on macOS, what Option types; the key itself is meant.
            let key = if control || alt {
                event.key_without_modifiers()
            } else {
                event.logical_key.clone()
            };
            let Logical::Character(text) = key else {
                return None;
            };
            let ch = text.chars().next()?;
            Key::Char(if shift && (control || alt) {
                crate::tui::input::shifted(ch)
            } else {
                ch
            })
        }
        _ => return None,
    };
    Some(KeyStroke {
        code,
        control,
        alt,
        shift,
        unsupported_modifiers: modifiers.super_key(),
        release: false,
    })
}
fn function(key: NamedKey) -> Option<u8> {
    use NamedKey::*;
    let keys = [F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12];
    keys.iter()
        .position(|f| *f == key)
        .map(|index| index as u8 + 1)
}

/// What a Command key chord stands for on macOS, where it is the Edit
/// menu's, not the editor's: a command, or pasting.
pub enum Menu {
    Command(&'static str),
    Paste,
}
/// The macOS shortcut a key press is; none elsewhere, where Super belongs
/// to the desktop.
pub fn menu(event: &KeyEvent, modifiers: ModifiersState) -> Option<Menu> {
    if !cfg!(target_os = "macos")
        || event.state == ElementState::Released
        || !modifiers.super_key()
        || modifiers.control_key()
        || modifiers.alt_key()
    {
        return None;
    }
    let Logical::Character(text) = event.key_without_modifiers() else {
        return None;
    };
    let shift = modifiers.shift_key();
    Some(match (text.to_lowercase().as_str(), shift) {
        ("c", false) => Menu::Command("copy"),
        ("x", false) => Menu::Command("cut"),
        ("v", false) => Menu::Paste,
        ("z", false) => Menu::Command("undo"),
        ("z", true) => Menu::Command("redo"),
        ("a", false) => Menu::Command("select-all"),
        ("s", false) => Menu::Command("write"),
        ("q", false) => Menu::Command("quit"),
        _ => return None,
    })
}
