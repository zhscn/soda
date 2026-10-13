use crate::editor::{Command, Direction, Motion};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use unicode_segmentation::UnicodeSegmentation;

pub(super) enum Action {
    Edit(Command),
    Open,
    New,
    Close,
    Save { choose_path: bool },
    Quit,
    NextView,
}
pub(super) fn binding(key: KeyEvent) -> Option<Action> {
    if key.kind == KeyEventKind::Release {
        return None;
    }
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    let shift = key.modifiers.contains(KeyModifiers::SHIFT);
    if key
        .modifiers
        .intersects(KeyModifiers::ALT | KeyModifiers::SUPER)
    {
        return None;
    }
    if control {
        return match key.code {
            KeyCode::Char('o') => Some(Action::Open),
            KeyCode::Char('n') => Some(Action::New),
            KeyCode::Char('w') => Some(Action::Close),
            KeyCode::Char('s' | 'S') => Some(Action::Save { choose_path: shift }),
            KeyCode::Char('q') => Some(Action::Quit),
            KeyCode::Char('z') => Some(Action::Edit(Command::Undo)),
            KeyCode::Char('y') => Some(Action::Edit(Command::Redo)),
            KeyCode::Tab => Some(Action::NextView),
            KeyCode::Home => Some(Action::Edit(Command::Move {
                motion: Motion::DocumentStart,
                extend: shift,
            })),
            KeyCode::End => Some(Action::Edit(Command::Move {
                motion: Motion::DocumentEnd,
                extend: shift,
            })),
            _ => None,
        };
    }
    if key.code == KeyCode::F(6) {
        return Some(Action::NextView);
    }
    if key.code == KeyCode::F(4) {
        return Some(Action::Save { choose_path: true });
    }
    let motion = match key.code {
        KeyCode::Left => Some(Motion::Backward),
        KeyCode::Right => Some(Motion::Forward),
        KeyCode::Up => Some(Motion::Up),
        KeyCode::Down => Some(Motion::Down),
        KeyCode::Home => Some(Motion::LineStart),
        KeyCode::End => Some(Motion::LineEnd),
        _ => None,
    };
    if let Some(motion) = motion {
        return Some(Action::Edit(Command::Move {
            motion,
            extend: shift,
        }));
    }
    let command = match key.code {
        KeyCode::Char(ch) => Command::TypeChar(ch),
        KeyCode::Enter => Command::Enter,
        KeyCode::Backspace => Command::Delete {
            direction: Direction::Backward,
            smart: true,
        },
        KeyCode::Delete => Command::Delete {
            direction: Direction::Forward,
            smart: false,
        },
        KeyCode::Tab => Command::InsertTab,
        KeyCode::BackTab => Command::IndentSelection { outdent: true },
        _ => return None,
    };
    Some(Action::Edit(command))
}

/// A single-line input buffer with grapheme navigation. It owns input state;
/// submitting/cancelling and file operations belong to the host.
#[derive(Default)]
pub(super) struct InputField {
    pub text: String,
    pub cursor: usize,
}
impl InputField {
    pub fn insert(&mut self, text: &str) {
        let text: String = text.chars().filter(|ch| !ch.is_control()).collect();
        self.text.insert_str(self.cursor, &text);
        self.cursor += text.len();
        // Insertions may merge adjacent graphemes. Keep the caret at a boundary.
        self.clip_cursor();
    }
    fn clip_cursor(&mut self) {
        self.cursor = self
            .text
            .grapheme_indices(true)
            .map(|(i, _)| i)
            .chain(std::iter::once(self.text.len()))
            .find(|i| *i >= self.cursor)
            .unwrap();
    }
    pub fn key(&mut self, key: KeyEvent) {
        if key.kind == KeyEventKind::Release
            || key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER)
        {
            return;
        }
        let previous = self.text[..self.cursor]
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(i, _)| i);
        let next = self.text[self.cursor..]
            .graphemes(true)
            .next()
            .map_or(self.cursor, |g| self.cursor + g.len());
        match key.code {
            KeyCode::Char(ch) => self.insert(&ch.to_string()),
            KeyCode::Left => self.cursor = previous,
            KeyCode::Right => self.cursor = next,
            KeyCode::Home => self.cursor = 0,
            KeyCode::End => self.cursor = self.text.len(),
            KeyCode::Backspace => {
                self.text.replace_range(previous..self.cursor, "");
                self.cursor = previous;
            }
            KeyCode::Delete => {
                self.text.replace_range(self.cursor..next, "");
            }
            _ => {}
        }
        self.clip_cursor();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }
    #[test]
    fn input_navigates_and_deletes_whole_graphemes() {
        let mut field = InputField::default();
        field.insert("中e\u{301}🦀");
        field.key(key(KeyCode::Left));
        field.key(key(KeyCode::Backspace));
        assert_eq!(field.text, "中🦀");
        assert_eq!(field.cursor, "中".len());
        field.key(key(KeyCode::Delete));
        assert_eq!(field.text, "中");
        field.key(key(KeyCode::Home));
        field.insert("x\n\x1b\t");
        assert_eq!(field.text, "x中");
    }
    #[test]
    fn inserted_joiners_do_not_leave_cursor_inside_merged_cluster() {
        let mut field = InputField {
            text: "👩👩".into(),
            cursor: "👩".len(),
        };
        field.insert("\u{200d}");
        assert_eq!(field.cursor, field.text.len());
        field.key(key(KeyCode::Backspace));
        assert!(field.text.is_empty());
    }
    #[test]
    fn bindings_preserve_selection_intent_and_ignore_releases() {
        assert!(matches!(
            binding(KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT)),
            Some(Action::Edit(Command::Move {
                motion: Motion::Backward,
                extend: true
            }))
        ));
        let mut release = key(KeyCode::Char('a'));
        release.kind = KeyEventKind::Release;
        assert!(binding(release).is_none());
        assert!(binding(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::ALT)).is_none());
        assert!(matches!(
            binding(key(KeyCode::Tab)),
            Some(Action::Edit(Command::InsertTab))
        ));
        assert!(matches!(
            binding(key(KeyCode::F(4))),
            Some(Action::Save { choose_path: true })
        ));
    }
}
