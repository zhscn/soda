//! Converts terminal events to the frontend-independent input vocabulary.
use crate::interaction::{Key, KeyStroke, UserInput};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

/// The character Shift gives on a US keyboard. With Control or Alt the
/// kitty protocol reports the unshifted key: `,` and Shift for `<`.
pub(crate) fn shifted(ch: char) -> char {
    const PAIRS: [(char, char); 21] = [
        ('1', '!'),
        ('2', '@'),
        ('3', '#'),
        ('4', '$'),
        ('5', '%'),
        ('6', '^'),
        ('7', '&'),
        ('8', '*'),
        ('9', '('),
        ('0', ')'),
        ('-', '_'),
        ('=', '+'),
        ('[', '{'),
        (']', '}'),
        ('\\', '|'),
        (';', ':'),
        ('\'', '"'),
        ('`', '~'),
        (',', '<'),
        ('.', '>'),
        ('/', '?'),
    ];
    match PAIRS.iter().find(|(plain, _)| *plain == ch) {
        Some((_, shifted)) => *shifted,
        None => ch.to_ascii_uppercase(),
    }
}

fn normalize_key(key: KeyEvent) -> KeyStroke {
    let code = match key.code {
        // The kitty protocol reports Shift with the unshifted letter; legacy
        // encodings send the shifted one.
        KeyCode::Char(ch) if key.modifiers.contains(KeyModifiers::SHIFT) => Key::Char(shifted(ch)),
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
        alt: key.modifiers.contains(KeyModifiers::ALT),
        shift: key.modifiers.contains(KeyModifiers::SHIFT),
        unsupported_modifiers: key
            .modifiers
            .intersects(KeyModifiers::SUPER | KeyModifiers::HYPER | KeyModifiers::META),
        release: key.kind == KeyEventKind::Release,
    }
}

pub(super) fn normalize(event: Event) -> UserInput {
    match event {
        Event::Key(key) => UserInput::Key(normalize_key(key)),
        Event::FocusLost => UserInput::FocusLost,
        Event::FocusGained => UserInput::FocusGained,
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
        assert!(normalize_key(key).alt);
        key.modifiers |= KeyModifiers::SUPER;
        assert!(normalize_key(key).unsupported_modifiers);
    }
    #[test]
    fn shifted_letters_read_the_same_in_both_encodings() {
        let kitty = normalize_key(KeyEvent::new(
            KeyCode::Char('a'),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT,
        ));
        let legacy = normalize_key(KeyEvent::new(
            KeyCode::Char('A'),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT,
        ));
        assert_eq!(kitty, legacy);
        assert_eq!(kitty.code, Key::Char('A'));
        let enter = normalize_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::CONTROL));
        assert_eq!(enter.code, Key::Enter);
        assert!(enter.control);
    }
    #[test]
    fn adapter_preserves_paste_and_does_not_assign_focus_behavior() {
        let UserInput::Paste(text) = normalize(Event::Paste("中\r\n".into())) else {
            panic!()
        };
        assert_eq!(text, "中\r\n");
        assert!(matches!(normalize(Event::FocusLost), UserInput::FocusLost));
        assert_eq!(
            normalize_key(KeyEvent::new(KeyCode::Null, KeyModifiers::NONE)).code,
            Key::Unrecognized
        );
    }
}
