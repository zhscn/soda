//! Fixed Vim defaults. Custom mode bindings are resolved before these defaults.
use super::{
    Command, EditMode, Input, InputKey, InputMotion, Key, KeyStroke,
    picker::ListMotion,
    vim::{Insert, VimCommand},
};
use crate::editor::{Command as Edit, Direction, Motion};
pub(super) fn field_key(key: KeyStroke) -> Option<InputKey> {
    if key.release || key.unsupported_modifiers || key.alt || (key.shift && key.control) {
        return None;
    }
    if key.control {
        return match key.code {
            Key::Char('b') => Some(InputKey::Move {
                motion: InputMotion::Start,
                extend: false,
            }),
            Key::Char('e') => Some(InputKey::Move {
                motion: InputMotion::End,
                extend: false,
            }),
            Key::Char('h') | Key::Backspace => Some(InputKey::Delete {
                backward: true,
                word: false,
            }),
            Key::Char('w') => Some(InputKey::Kill(InputMotion::WordLeft)),
            Key::Char('u') => Some(InputKey::Kill(InputMotion::Start)),
            Key::Left => Some(InputKey::Move {
                motion: InputMotion::WordLeft,
                extend: false,
            }),
            Key::Right => Some(InputKey::Move {
                motion: InputMotion::WordRight,
                extend: false,
            }),
            _ => None,
        };
    }
    let motion = match key.code {
        Key::Left => Some(InputMotion::Left),
        Key::Right => Some(InputMotion::Right),
        Key::Home => Some(InputMotion::Start),
        Key::End => Some(InputMotion::End),
        _ => None,
    };
    if let Some(motion) = motion {
        return Some(InputKey::Move {
            motion,
            extend: key.shift,
        });
    }
    match key.code {
        Key::Char(ch) => Some(InputKey::Char(ch)),
        Key::Backspace => Some(InputKey::Delete {
            backward: true,
            word: false,
        }),
        Key::Delete => Some(InputKey::Delete {
            backward: false,
            word: false,
        }),
        _ => None,
    }
}
pub(crate) fn binding(key: KeyStroke, mode: EditMode) -> Option<Command> {
    if key.release || key.unsupported_modifiers || key.alt {
        return None;
    }
    if key.control && !key.shift && matches!(key.code, Key::Char('[' | 'c')) {
        return Some(Command::Vim(VimCommand::Insert(Insert::Leave)));
    }
    if key.code == Key::Esc && !key.control && !key.shift {
        return Some(Command::Vim(VimCommand::Insert(Insert::Leave)));
    }
    if mode != EditMode::Insert {
        if key.control && !key.shift {
            return match key.code {
                Key::Char('r') => Some(Command::Vim(VimCommand::Undo {
                    redo: true,
                    count: 1,
                })),
                Key::Char('f') => Some(Command::Page {
                    backward: false,
                    extend: false,
                }),
                Key::Char('b') => Some(Command::Page {
                    backward: true,
                    extend: false,
                }),
                _ => None,
            };
        }
        return match key.code {
            Key::Left => Some(Command::Vim(VimCommand::Move(super::vim::Motion::Left, 1))),
            Key::Right => Some(Command::Vim(VimCommand::Move(super::vim::Motion::Right, 1))),
            Key::Up => Some(Command::Vim(VimCommand::Move(super::vim::Motion::Up, 1))),
            Key::Down => Some(Command::Vim(VimCommand::Move(super::vim::Motion::Down, 1))),
            Key::F(1) => Some(Command::Help),
            _ => None,
        };
    }
    if key.control && (!key.shift || matches!(key.code, Key::Left | Key::Right)) {
        return match key.code {
            Key::Left | Key::Right => Some(Command::Edit(Edit::Move {
                motion: if key.code == Key::Left {
                    Motion::WordBackward
                } else {
                    Motion::WordForward
                },
                extend: key.shift,
            })),
            Key::Delete => Some(Command::Edit(Edit::DeleteWord(Direction::Forward))),
            Key::Char('h') => Some(Command::Edit(Edit::Delete {
                direction: Direction::Backward,
                smart: true,
            })),
            Key::Char('w') | Key::Backspace => Some(Command::Vim(VimCommand::EraseWord)),
            Key::Char('u') => Some(Command::Vim(VimCommand::EraseLineStart)),
            _ => None,
        };
    }
    if key.control {
        return None;
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
        return Some(Command::Edit(Edit::Move {
            motion,
            extend: key.shift,
        }));
    }
    Some(match key.code {
        Key::Char(ch) => Command::Edit(Edit::TypeChar(ch)),
        Key::Enter => Command::Edit(Edit::Enter),
        Key::Backspace => Command::Edit(Edit::Delete {
            direction: Direction::Backward,
            smart: true,
        }),
        Key::Delete => Command::Edit(Edit::Delete {
            direction: Direction::Forward,
            smart: false,
        }),
        Key::Tab => Command::Edit(Edit::InsertTab),
        Key::BackTab => Command::Edit(Edit::IndentSelection { outdent: true }),
        Key::F(1) => Command::Help,
        _ => return None,
    })
}
pub(crate) fn modal_key(key: KeyStroke) -> Input {
    if key.release || key.unsupported_modifiers || key.alt {
        return Input::Unrecognized;
    }
    if key.control && !key.shift {
        match key.code {
            Key::Char('c') => return Input::Cancel,
            Key::Char('n') => {
                return Input::Candidate {
                    motion: ListMotion::Next,
                    wrap: false,
                };
            }
            Key::Char('p') => {
                return Input::Candidate {
                    motion: ListMotion::Previous,
                    wrap: false,
                };
            }
            Key::Enter => return Input::ReplaceAll,
            Key::Up => {
                return Input::Candidate {
                    motion: ListMotion::First,
                    wrap: false,
                };
            }
            Key::Down => {
                return Input::Candidate {
                    motion: ListMotion::Last,
                    wrap: false,
                };
            }
            _ => {}
        }
    }
    if !key.control {
        match key.code {
            Key::Esc if !key.shift => return Input::Cancel,
            Key::Enter if !key.shift => return Input::Confirm,
            Key::Tab | Key::BackTab => {
                return Input::Complete {
                    backward: key.shift || key.code == Key::BackTab,
                };
            }
            Key::Up => {
                return Input::Candidate {
                    motion: ListMotion::Previous,
                    wrap: false,
                };
            }
            Key::Down => {
                return Input::Candidate {
                    motion: ListMotion::Next,
                    wrap: false,
                };
            }
            Key::PageUp => {
                return Input::Candidate {
                    motion: ListMotion::PagePrevious,
                    wrap: false,
                };
            }
            Key::PageDown => {
                return Input::Candidate {
                    motion: ListMotion::PageNext,
                    wrap: false,
                };
            }
            Key::F(1) => return Input::Help,
            Key::F(3) => {
                return Input::Navigate {
                    backward: key.shift,
                };
            }
            Key::F(4) => return Input::ReplaceAll,
            _ => {}
        }
    }
    field_key(key).map_or(Input::Unrecognized, Input::Text)
}
