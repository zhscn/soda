//! Converts terminal events to the frontend-independent input vocabulary.
use crate::interaction::{Key, KeyStroke, UserInput};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

fn normalize_key(key: KeyEvent) -> KeyStroke {
    let code = match key.code {
        KeyCode::Char(ch) => Key::Char(ch),
        KeyCode::Enter => Key::Enter,
        KeyCode::Esc => Key::Esc,
        KeyCode::Backspace => Key::Backspace,
        KeyCode::Delete => Key::Delete,
        KeyCode::Tab => Key::Tab,
        KeyCode::BackTab => Key::BackTab,
        KeyCode::Left => Key::Left,
        KeyCode::Right => Key::Right,
        KeyCode::Up => Key::Up,
        KeyCode::Down => Key::Down,
        KeyCode::Home => Key::Home,
        KeyCode::End => Key::End,
        KeyCode::PageUp => Key::PageUp,
        KeyCode::PageDown => Key::PageDown,
        KeyCode::F(number) => Key::F(number),
        _ => Key::Unrecognized,
    };
    KeyStroke {
        code,
        control: key.modifiers.contains(KeyModifiers::CONTROL),
        shift: key.modifiers.contains(KeyModifiers::SHIFT),
        unsupported_modifiers: key.modifiers.intersects(
            KeyModifiers::ALT | KeyModifiers::SUPER | KeyModifiers::HYPER | KeyModifiers::META,
        ),
        release: key.kind == KeyEventKind::Release,
    }
}

pub(super) fn normalize(event: Event) -> UserInput {
    match event {
        Event::Key(key) => UserInput::Key(normalize_key(key)),
        Event::Paste(text) => UserInput::Paste(text),
        _ => UserInput::Unrecognized,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn terminal_keys_preserve_modifiers_release_and_repeat() {
        let mut key = KeyEvent::new(KeyCode::Left, KeyModifiers::CONTROL | KeyModifiers::SHIFT);
        let normalized = normalize_key(key);
        assert_eq!(normalized.code, Key::Left);
        assert!(normalized.control && normalized.shift);
        assert!(!normalized.release && !normalized.unsupported_modifiers);
        key.kind = KeyEventKind::Repeat;
        assert_eq!(normalize_key(key), normalized);
        key.kind = KeyEventKind::Release;
        assert!(normalize_key(key).release);
        key.modifiers |= KeyModifiers::ALT;
        assert!(normalize_key(key).unsupported_modifiers);
    }
    #[test]
    fn adapter_preserves_paste_and_does_not_assign_focus_behavior() {
        let UserInput::Paste(text) = normalize(Event::Paste("中\r\n".into())) else {
            panic!()
        };
        assert_eq!(text, "中\r\n");
        assert!(matches!(
            normalize(Event::FocusLost),
            UserInput::Unrecognized
        ));
        assert_eq!(
            normalize_key(KeyEvent::new(KeyCode::Null, KeyModifiers::NONE)).code,
            Key::Unrecognized
        );
    }
}
