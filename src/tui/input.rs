use crate::editor::{Command, Direction, Motion};
use crate::interaction::{Input, InputKey, InputMotion, picker::ListMotion};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

pub(super) enum Action {
    Edit(Command),
    Open,
    New,
    Close,
    Save { choose_path: bool },
    Quit,
    NextView,
    Search,
    PickFiles,
}
pub(super) fn binding(key: KeyEvent) -> Option<Action> {
    if key.kind == KeyEventKind::Release {
        return None;
    }
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    let shift = key.modifiers.contains(KeyModifiers::SHIFT);
    if key.modifiers.intersects(
        KeyModifiers::ALT | KeyModifiers::SUPER | KeyModifiers::HYPER | KeyModifiers::META,
    ) {
        return None;
    }
    if control {
        return match key.code {
            KeyCode::Char('p') => Some(Action::PickFiles),
            KeyCode::Char('f') => Some(Action::Search),
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
    if key.code == KeyCode::F(3) {
        return Some(Action::Edit(Command::Find {
            backward: shift,
            wrap: true,
        }));
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

/// Normalize modifiers once for all modal layers. Modified submit/cancel keys
/// are blocked unless a binding explicitly accepts that combination.
pub(super) fn modal_key(key: KeyEvent) -> Input {
    if key.kind == KeyEventKind::Release
        || key.modifiers.intersects(
            KeyModifiers::ALT | KeyModifiers::SUPER | KeyModifiers::HYPER | KeyModifiers::META,
        )
    {
        return Input::Unrecognized;
    }
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    let shift = key.modifiers.contains(KeyModifiers::SHIFT);
    if key.modifiers.is_empty() {
        match key.code {
            KeyCode::Enter => return Input::Confirm,
            KeyCode::Esc => return Input::Cancel,
            _ => {}
        }
    }
    if key.code == KeyCode::F(3) && !control {
        return Input::Navigate { backward: shift };
    }
    if control && !shift {
        let motion = match key.code {
            KeyCode::Up => Some(ListMotion::First),
            KeyCode::Down => Some(ListMotion::Last),
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
            KeyCode::Up => Some(ListMotion::Previous),
            KeyCode::Down => Some(ListMotion::Next),
            KeyCode::PageUp => Some(ListMotion::PagePrevious),
            KeyCode::PageDown => Some(ListMotion::PageNext),
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
        KeyCode::Left => Some(if control {
            InputMotion::WordLeft
        } else {
            InputMotion::Left
        }),
        KeyCode::Right => Some(if control {
            InputMotion::WordRight
        } else {
            InputMotion::Right
        }),
        KeyCode::Home => Some(InputMotion::Start),
        KeyCode::End => Some(InputMotion::End),
        _ => None,
    };
    if let Some(motion) = motion {
        return Input::Text(InputKey::Move {
            motion,
            extend: shift,
        });
    }
    match key.code {
        KeyCode::Char('a' | 'A') if control && !shift => Input::Text(InputKey::SelectAll),
        KeyCode::Char(ch) if !control => Input::Text(InputKey::Char(ch)),
        KeyCode::Backspace if !shift => Input::Text(InputKey::Delete {
            backward: true,
            word: control,
        }),
        KeyCode::Delete if !shift => Input::Text(InputKey::Delete {
            backward: false,
            word: control,
        }),
        _ => Input::Unrecognized,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
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
    #[test]
    fn modal_submit_cancel_and_navigation_validate_modifiers_and_release() {
        for code in [KeyCode::Enter, KeyCode::Esc, KeyCode::F(3)] {
            for modifiers in [
                KeyModifiers::CONTROL,
                KeyModifiers::ALT,
                KeyModifiers::SUPER,
                KeyModifiers::META,
                KeyModifiers::HYPER,
            ] {
                assert!(matches!(
                    modal_key(KeyEvent::new(code, modifiers)),
                    Input::Unrecognized
                ));
            }
            let mut release = key(code);
            release.kind = KeyEventKind::Release;
            assert!(matches!(modal_key(release), Input::Unrecognized));
        }
        assert!(matches!(modal_key(key(KeyCode::Enter)), Input::Confirm));
        assert!(matches!(modal_key(key(KeyCode::Esc)), Input::Cancel));
        assert!(matches!(
            modal_key(KeyEvent::new(KeyCode::F(3), KeyModifiers::SHIFT)),
            Input::Navigate { backward: true }
        ));
        assert!(matches!(
            modal_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::SHIFT)),
            Input::Unrecognized
        ));
    }
    #[test]
    fn text_shortcuts_normalize_to_widget_operations() {
        assert!(matches!(
            modal_key(KeyEvent::new(
                KeyCode::Left,
                KeyModifiers::CONTROL | KeyModifiers::SHIFT
            )),
            Input::Text(InputKey::Move {
                motion: InputMotion::WordLeft,
                extend: true
            })
        ));
        assert!(matches!(
            modal_key(KeyEvent::new(KeyCode::Backspace, KeyModifiers::CONTROL)),
            Input::Text(InputKey::Delete {
                backward: true,
                word: true
            })
        ));
        assert!(matches!(
            modal_key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::CONTROL)),
            Input::Text(InputKey::SelectAll)
        ));
        assert!(matches!(
            modal_key(KeyEvent::new(KeyCode::Char('X'), KeyModifiers::SHIFT)),
            Input::Text(InputKey::Char('X'))
        ));
        assert!(matches!(
            modal_key(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::CONTROL)),
            Input::Unrecognized
        ));
    }
    #[test]
    fn picker_navigation_does_not_steal_text_input_home_end() {
        assert!(matches!(
            binding(KeyEvent::new(KeyCode::Char('p'), KeyModifiers::CONTROL)),
            Some(Action::PickFiles)
        ));
        assert!(matches!(
            modal_key(key(KeyCode::Down)),
            Input::Candidate {
                motion: ListMotion::Next,
                wrap: false
            }
        ));
        assert!(matches!(
            modal_key(key(KeyCode::PageUp)),
            Input::Candidate {
                motion: ListMotion::PagePrevious,
                ..
            }
        ));
        assert!(matches!(
            modal_key(KeyEvent::new(KeyCode::Down, KeyModifiers::CONTROL)),
            Input::Candidate {
                motion: ListMotion::Last,
                ..
            }
        ));
        assert!(matches!(
            modal_key(key(KeyCode::Home)),
            Input::Text(InputKey::Move {
                motion: InputMotion::Start,
                ..
            })
        ));
        assert!(matches!(
            modal_key(key(KeyCode::End)),
            Input::Text(InputKey::Move {
                motion: InputMotion::End,
                ..
            })
        ));
    }
}
