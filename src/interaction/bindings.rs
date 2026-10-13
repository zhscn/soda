use super::{Command, Input, InputKey, InputMotion, Key, KeyStroke, picker::ListMotion};
use crate::application::ClipboardAction;
use crate::editor::{Command as EditCommand, Direction, Motion};

pub(crate) fn binding(key: KeyStroke) -> Option<Command> {
    if key.release {
        return None;
    }
    let control = key.control;
    let shift = key.shift;
    if key.unsupported_modifiers {
        return None;
    }
    if control {
        return match key.code {
            Key::Char('a') if !shift => Some(Command::Edit(EditCommand::SelectAll)),
            Key::Char('r') if !shift => Some(Command::Replace),
            Key::Char('g') if !shift => Some(Command::Goto),
            Key::Left | Key::Right => Some(Command::Edit(EditCommand::Move {
                motion: if key.code == Key::Left {
                    Motion::WordBackward
                } else {
                    Motion::WordForward
                },
                extend: shift,
            })),
            Key::Backspace | Key::Delete if !shift => Some(Command::Edit(EditCommand::DeleteWord(
                if key.code == Key::Backspace {
                    Direction::Backward
                } else {
                    Direction::Forward
                },
            ))),
            Key::Char('c') if !shift => Some(Command::Clipboard(ClipboardAction::Copy)),
            Key::Char('x') if !shift => Some(Command::Clipboard(ClipboardAction::Cut)),
            Key::Char('v') if !shift => Some(Command::Clipboard(ClipboardAction::Paste)),
            Key::Char('p') => Some(Command::PickFiles),
            Key::Char('f') => Some(Command::Search),
            Key::Char('o') => Some(Command::Open),
            Key::Char('n') => Some(Command::New),
            Key::Char('w') => Some(Command::Close),
            Key::Char('s' | 'S') => Some(Command::Save { choose_path: shift }),
            Key::Char('q') => Some(Command::Quit),
            Key::Char('z') => Some(Command::Edit(EditCommand::Undo)),
            Key::Char('y') => Some(Command::Edit(EditCommand::Redo)),
            Key::Tab => Some(Command::NextView),
            Key::Home => Some(Command::Edit(EditCommand::Move {
                motion: Motion::DocumentStart,
                extend: shift,
            })),
            Key::End => Some(Command::Edit(EditCommand::Move {
                motion: Motion::DocumentEnd,
                extend: shift,
            })),
            _ => None,
        };
    }
    if key.code == Key::F(1) && !shift {
        return Some(Command::Help);
    }
    if matches!(key.code, Key::PageUp | Key::PageDown) {
        return Some(Command::Page {
            backward: key.code == Key::PageUp,
            extend: shift,
        });
    }
    if key.code == Key::F(3) {
        return Some(Command::Edit(EditCommand::Find {
            backward: shift,
            wrap: true,
        }));
    }
    if key.code == Key::F(5) {
        return Some(Command::Reload);
    }
    if key.code == Key::F(6) {
        return Some(Command::NextView);
    }
    if key.code == Key::F(4) {
        return Some(Command::Save { choose_path: true });
    }
    let motion = match key.code {
        Key::Left => Some(Motion::Backward),
        Key::Right => Some(Motion::Forward),
        Key::Up => Some(Motion::Up),
        Key::Down => Some(Motion::Down),
        Key::Home => Some(Motion::LineStart),
        Key::End => Some(Motion::LineEnd),
        _ => None,
    };
    if let Some(motion) = motion {
        return Some(Command::Edit(EditCommand::Move {
            motion,
            extend: shift,
        }));
    }
    let command = match key.code {
        Key::Char(ch) => EditCommand::TypeChar(ch),
        Key::Enter => EditCommand::Enter,
        Key::Backspace => EditCommand::Delete {
            direction: Direction::Backward,
            smart: true,
        },
        Key::Delete => EditCommand::Delete {
            direction: Direction::Forward,
            smart: false,
        },
        Key::Tab => EditCommand::InsertTab,
        Key::BackTab => EditCommand::IndentSelection { outdent: true },
        _ => return None,
    };
    Some(Command::Edit(command))
}

/// Resolve normalized keys for all modal layers. Modified submit/cancel keys
/// are blocked unless a binding explicitly accepts that combination.
pub(crate) fn modal_key(key: KeyStroke) -> Input {
    if key.release || key.unsupported_modifiers {
        return Input::Unrecognized;
    }
    let control = key.control;
    let shift = key.shift;
    if !control && !shift {
        match key.code {
            Key::Enter => return Input::Confirm,
            Key::Esc => return Input::Cancel,
            _ => {}
        }
    }
    if key.code == Key::F(1) && !control && !shift {
        return Input::Help;
    }
    if key.code == Key::F(4) && !control && !shift {
        return Input::ReplaceAll;
    }
    if key.code == Key::Enter && control && !shift {
        return Input::ReplaceAll;
    }
    if key.code == Key::F(3) && !control {
        return Input::Navigate { backward: shift };
    }
    if control && !shift {
        let motion = match key.code {
            Key::Up => Some(ListMotion::First),
            Key::Down => Some(ListMotion::Last),
            _ => None,
        };
        if let Some(motion) = motion {
            return Input::Candidate {
                motion,
                wrap: false,
            };
        }
    }
    if !control && !shift {
        let motion = match key.code {
            Key::Up => Some(ListMotion::Previous),
            Key::Down => Some(ListMotion::Next),
            Key::PageUp => Some(ListMotion::PagePrevious),
            Key::PageDown => Some(ListMotion::PageNext),
            _ => None,
        };
        if let Some(motion) = motion {
            return Input::Candidate {
                motion,
                wrap: false,
            };
        }
    }
    let motion = match key.code {
        Key::Left => Some(if control {
            InputMotion::WordLeft
        } else {
            InputMotion::Left
        }),
        Key::Right => Some(if control {
            InputMotion::WordRight
        } else {
            InputMotion::Right
        }),
        Key::Home => Some(InputMotion::Start),
        Key::End => Some(InputMotion::End),
        _ => None,
    };
    if let Some(motion) = motion {
        return Input::Text(InputKey::Move {
            motion,
            extend: shift,
        });
    }
    match key.code {
        Key::Char('a' | 'A') if control && !shift => Input::Text(InputKey::SelectAll),
        Key::Char(ch) if !control => Input::Text(InputKey::Char(ch)),
        Key::Backspace if !shift => Input::Text(InputKey::Delete {
            backward: true,
            word: control,
        }),
        Key::Delete if !shift => Input::Text(InputKey::Delete {
            backward: false,
            word: control,
        }),
        _ => Input::Unrecognized,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interaction::{Key, KeyStroke};
    struct KeyModifiers;
    impl KeyModifiers {
        const NONE: u8 = 0;
        const CONTROL: u8 = 1;
        const SHIFT: u8 = 2;
        const ALT: u8 = 4;
        const SUPER: u8 = 8;
        const META: u8 = 16;
        const HYPER: u8 = 32;
    }
    fn modified(code: Key, modifiers: u8) -> KeyStroke {
        KeyStroke {
            control: modifiers & KeyModifiers::CONTROL != 0,
            shift: modifiers & KeyModifiers::SHIFT != 0,
            unsupported_modifiers: modifiers & !3 != 0,
            ..KeyStroke::plain(code)
        }
    }
    fn key(code: Key) -> KeyStroke {
        modified(code, KeyModifiers::NONE)
    }
    #[test]
    fn bindings_preserve_selection_intent_and_ignore_releases() {
        assert!(matches!(
            binding(modified(Key::Left, KeyModifiers::SHIFT)),
            Some(Command::Edit(EditCommand::Move {
                motion: Motion::Backward,
                extend: true
            }))
        ));
        let mut release = key(Key::Char('a'));
        release.release = true;
        assert!(binding(release).is_none());
        assert!(binding(modified(Key::Char('a'), KeyModifiers::ALT)).is_none());
        assert!(matches!(
            binding(key(Key::Tab)),
            Some(Command::Edit(EditCommand::InsertTab))
        ));
        assert!(matches!(
            binding(key(Key::F(4))),
            Some(Command::Save { choose_path: true })
        ));
    }
    #[test]
    fn modal_submit_cancel_and_navigation_validate_modifiers_and_release() {
        for code in [Key::Enter, Key::Esc, Key::F(3)] {
            for modifiers in [
                KeyModifiers::CONTROL,
                KeyModifiers::ALT,
                KeyModifiers::SUPER,
                KeyModifiers::META,
                KeyModifiers::HYPER,
            ] {
                if code == Key::Enter && modifiers == KeyModifiers::CONTROL {
                    continue;
                }
                assert!(matches!(
                    modal_key(modified(code, modifiers)),
                    Input::Unrecognized
                ));
            }
            let mut release = key(code);
            release.release = true;
            assert!(matches!(modal_key(release), Input::Unrecognized));
        }
        assert!(matches!(
            modal_key(modified(Key::Enter, KeyModifiers::CONTROL)),
            Input::ReplaceAll
        ));
        assert!(matches!(modal_key(key(Key::Enter)), Input::Confirm));
        assert!(matches!(modal_key(key(Key::Esc)), Input::Cancel));
        assert!(matches!(
            modal_key(modified(Key::F(3), KeyModifiers::SHIFT)),
            Input::Navigate { backward: true }
        ));
        assert!(matches!(
            modal_key(modified(Key::Enter, KeyModifiers::SHIFT)),
            Input::Unrecognized
        ));
    }
    #[test]
    fn text_shortcuts_normalize_to_widget_operations() {
        assert!(matches!(
            modal_key(modified(
                Key::Left,
                KeyModifiers::CONTROL | KeyModifiers::SHIFT
            )),
            Input::Text(InputKey::Move {
                motion: InputMotion::WordLeft,
                extend: true
            })
        ));
        assert!(matches!(
            modal_key(modified(Key::Backspace, KeyModifiers::CONTROL)),
            Input::Text(InputKey::Delete {
                backward: true,
                word: true
            })
        ));
        assert!(matches!(
            modal_key(modified(Key::Char('a'), KeyModifiers::CONTROL)),
            Input::Text(InputKey::SelectAll)
        ));
        assert!(matches!(
            modal_key(modified(Key::Char('X'), KeyModifiers::SHIFT)),
            Input::Text(InputKey::Char('X'))
        ));
        assert!(matches!(
            modal_key(modified(Key::Char('z'), KeyModifiers::CONTROL)),
            Input::Unrecognized
        ));
    }
    #[test]
    fn picker_navigation_does_not_steal_text_input_home_end() {
        assert!(matches!(
            binding(modified(Key::Char('p'), KeyModifiers::CONTROL)),
            Some(Command::PickFiles)
        ));
        assert!(matches!(
            modal_key(key(Key::Down)),
            Input::Candidate {
                motion: ListMotion::Next,
                wrap: false
            }
        ));
        assert!(matches!(
            modal_key(key(Key::PageUp)),
            Input::Candidate {
                motion: ListMotion::PagePrevious,
                ..
            }
        ));
        assert!(matches!(
            modal_key(modified(Key::Down, KeyModifiers::CONTROL)),
            Input::Candidate {
                motion: ListMotion::Last,
                ..
            }
        ));
        assert!(matches!(
            modal_key(key(Key::Home)),
            Input::Text(InputKey::Move {
                motion: InputMotion::Start,
                ..
            })
        ));
        assert!(matches!(
            modal_key(key(Key::End)),
            Input::Text(InputKey::Move {
                motion: InputMotion::End,
                ..
            })
        ));
    }
}
