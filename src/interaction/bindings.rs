//! Fixed bindings. Readline editing is shared by fields and the document;
//! Normal overrides plain keys. Prefixes match literal chords, never rewrites.
use super::{Command, EditMode, Input, InputKey, InputMotion, Key, KeyStroke, picker::ListMotion};
use crate::{
    application::ClipboardAction,
    editor::{Command as Edit, Direction, Motion},
};

pub(super) fn field_key(key: KeyStroke) -> Option<InputKey> {
    if key.release || key.unsupported_modifiers || (key.control && key.alt) {
        return None;
    }
    let motion = if key.alt {
        match key.code {
            Key::Char('b') => Some(InputMotion::WordLeft),
            Key::Char('f') => Some(InputMotion::WordRight),
            _ => None,
        }
    } else if key.control {
        match key.code {
            Key::Char('b') => Some(InputMotion::Left),
            Key::Char('f') => Some(InputMotion::Right),
            Key::Char('a') => Some(InputMotion::Start),
            Key::Char('e') => Some(InputMotion::End),
            Key::Left => Some(InputMotion::WordLeft),
            Key::Right => Some(InputMotion::WordRight),
            _ => None,
        }
    } else {
        match key.code {
            Key::Left => Some(InputMotion::Left),
            Key::Right => Some(InputMotion::Right),
            Key::Home => Some(InputMotion::Start),
            Key::End => Some(InputMotion::End),
            _ => None,
        }
    };
    if let Some(motion) = motion {
        return Some(InputKey::Move {
            motion,
            extend: key.shift,
        });
    }
    if key.shift && (key.control || key.alt) {
        return None;
    }
    match (key.control, key.alt, key.code) {
        (true, false, Key::Char('h')) | (false, false, Key::Backspace) => Some(InputKey::Delete {
            backward: true,
            word: false,
        }),
        (true, false, Key::Char('d')) | (false, false, Key::Delete) => Some(InputKey::Delete {
            backward: false,
            word: false,
        }),
        (true, false, Key::Backspace)
        | (true, false, Key::Char('w'))
        | (false, true, Key::Backspace) => Some(InputKey::Kill(InputMotion::WordLeft)),
        (true, false, Key::Delete) | (false, true, Key::Char('d')) => {
            Some(InputKey::Kill(InputMotion::WordRight))
        }
        (true, false, Key::Char('k')) => Some(InputKey::Kill(InputMotion::End)),
        (true, false, Key::Char('u')) => Some(InputKey::Kill(InputMotion::Start)),
        (true, false, Key::Char('y')) => Some(InputKey::Yank),
        (false, true, Key::Char('a')) => Some(InputKey::SelectAll),
        (false, false, Key::Char(ch)) => Some(InputKey::Char(ch)),
        _ => None,
    }
}
fn edit_key(key: InputKey) -> Command {
    Command::Edit(match key {
        InputKey::Char(ch) => Edit::TypeChar(ch),
        InputKey::Move { motion, extend } => {
            return Command::Edit(Edit::Move {
                motion: document_motion(motion),
                extend,
            });
        }
        InputKey::Delete {
            backward,
            word: true,
        } => Edit::DeleteWord(if backward {
            Direction::Backward
        } else {
            Direction::Forward
        }),
        InputKey::Delete {
            backward,
            word: false,
        } => Edit::Delete {
            direction: if backward {
                Direction::Backward
            } else {
                Direction::Forward
            },
            smart: backward,
        },
        InputKey::SelectAll => Edit::SelectAll,
        InputKey::Kill(motion) => {
            return Command::Clipboard(ClipboardAction::Kill {
                backward: matches!(
                    motion,
                    InputMotion::Start | InputMotion::WordLeft | InputMotion::Left
                ),
                word: matches!(motion, InputMotion::WordLeft | InputMotion::WordRight),
            });
        }
        InputKey::Yank => return Command::Clipboard(ClipboardAction::Paste),
    })
}
fn document_motion(motion: InputMotion) -> Motion {
    match motion {
        InputMotion::Left => Motion::Backward,
        InputMotion::Right => Motion::Forward,
        InputMotion::WordLeft => Motion::WordBackward,
        InputMotion::WordRight => Motion::WordForward,
        InputMotion::Start => Motion::LineStart,
        InputMotion::End => Motion::LineEnd,
    }
}
pub(crate) fn binding(key: KeyStroke, mode: EditMode) -> Option<Command> {
    if key.release || key.unsupported_modifiers || (key.control && key.alt) {
        return None;
    }
    if key.code == Key::Esc && !key.control && !key.alt && !key.shift {
        return Some(Command::SetMode(EditMode::Normal));
    }
    if key.control && !key.alt && matches!(key.code, Key::Home | Key::End) {
        return Some(Command::Edit(Edit::Move {
            motion: if key.code == Key::Home {
                Motion::DocumentStart
            } else {
                Motion::DocumentEnd
            },
            extend: key.shift,
        }));
    }
    if key.control && !key.alt && !key.shift {
        let command = match key.code {
            Key::Char('s') => Some(Command::Search),
            Key::Char('_' | '/') => Some(Command::Edit(Edit::Undo)),
            Key::Char('n') => Some(Command::Edit(Edit::Move {
                motion: Motion::Down,
                extend: false,
            })),
            Key::Char('p') => Some(Command::Edit(Edit::Move {
                motion: Motion::Up,
                extend: false,
            })),
            Key::Char('v') => Some(Command::Page {
                backward: false,
                extend: false,
            }),
            Key::Tab => Some(Command::NextView),
            _ => None,
        };
        if command.is_some() {
            return command;
        }
    }
    if key.alt && !key.control {
        match key.code {
            Key::Char('w') if !key.shift => return Some(Command::Clipboard(ClipboardAction::Copy)),
            Key::Char('_') => return Some(Command::Edit(Edit::Redo)),
            Key::Char('%') => return Some(Command::Replace),
            Key::Char('v') if !key.shift => {
                return Some(Command::Page {
                    backward: true,
                    extend: false,
                });
            }
            Key::Char('<' | '>') => {
                return Some(Command::Edit(Edit::Move {
                    motion: if key.code == Key::Char('<') {
                        Motion::DocumentStart
                    } else {
                        Motion::DocumentEnd
                    },
                    extend: false,
                }));
            }
            _ => {}
        }
    }
    if !key.control && !key.alt {
        if mode == EditMode::Normal
            && let Key::Char(ch) = key.code
        {
            let motion = match ch.to_ascii_lowercase() {
                'h' => Some(Motion::Backward),
                'j' => Some(Motion::Down),
                'k' => Some(Motion::Up),
                'l' => Some(Motion::Forward),
                'b' => Some(Motion::WordBackward),
                'w' => Some(Motion::WordForward),
                _ => None,
            };
            if let Some(motion) = motion {
                return Some(Command::Edit(Edit::Move {
                    motion,
                    extend: ch.is_ascii_uppercase(),
                }));
            }
            return match ch {
                'i' => Some(Command::SetMode(EditMode::Insert)),
                'a' => Some(Command::Append),
                's' => Some(Command::Change),
                'd' => Some(Command::Edit(Edit::Delete {
                    direction: Direction::Forward,
                    smart: false,
                })),
                'r' => Some(Command::Clipboard(ClipboardAction::Cut)),
                'y' => Some(Command::Clipboard(ClipboardAction::Copy)),
                'p' => Some(Command::Clipboard(ClipboardAction::Paste)),
                'u' => Some(Command::Edit(Edit::Undo)),
                '/' => Some(Command::Open),
                '0' => Some(Command::Edit(Edit::Move {
                    motion: Motion::LineStart,
                    extend: false,
                })),
                '$' => Some(Command::Edit(Edit::Move {
                    motion: Motion::LineEnd,
                    extend: false,
                })),
                _ => None,
            };
        }
        match key.code {
            Key::F(1) if !key.shift => return Some(Command::Help),
            Key::F(3) => {
                return Some(Command::Edit(Edit::Find {
                    backward: key.shift,
                    wrap: true,
                }));
            }
            Key::F(4) if !key.shift => return Some(Command::Save { choose_path: true }),
            Key::F(5) if !key.shift => return Some(Command::Reload),
            Key::F(6) if !key.shift => return Some(Command::NextView),
            Key::PageUp | Key::PageDown => {
                return Some(Command::Page {
                    backward: key.code == Key::PageUp,
                    extend: key.shift,
                });
            }
            Key::Up | Key::Down => {
                return Some(Command::Edit(Edit::Move {
                    motion: if key.code == Key::Up {
                        Motion::Up
                    } else {
                        Motion::Down
                    },
                    extend: key.shift,
                }));
            }
            Key::Enter if mode == EditMode::Insert => return Some(Command::Edit(Edit::Enter)),
            Key::Tab if mode == EditMode::Insert => return Some(Command::Edit(Edit::InsertTab)),
            Key::BackTab if mode == EditMode::Insert => {
                return Some(Command::Edit(Edit::IndentSelection { outdent: true }));
            }
            _ => {}
        }
    }
    field_key(key).map(edit_key)
}

pub(crate) fn modal_key(key: KeyStroke) -> Input {
    if key.release || key.unsupported_modifiers {
        return Input::Unrecognized;
    }
    if !key.alt && !key.shift && key.control {
        match key.code {
            Key::Char('g') => return Input::Cancel,
            Key::Char('s') => return Input::Navigate { backward: false },
            Key::Char('r') => return Input::Navigate { backward: true },
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
            Key::Enter => return Input::ReplaceAll,
            _ => {}
        }
    }
    if !key.control && !key.alt {
        let motion = match key.code {
            Key::Up => Some(ListMotion::Previous),
            Key::Down => Some(ListMotion::Next),
            Key::PageUp => Some(ListMotion::PagePrevious),
            Key::PageDown => Some(ListMotion::PageNext),
            _ => None,
        };
        if !key.shift
            && let Some(motion) = motion
        {
            return Input::Candidate {
                motion,
                wrap: false,
            };
        }
        match key.code {
            Key::Enter if !key.shift => return Input::Confirm,
            Key::Esc if !key.shift => return Input::Cancel,
            Key::Tab | Key::BackTab => {
                return Input::Complete {
                    backward: key.shift || key.code == Key::BackTab,
                };
            }
            Key::F(1) if !key.shift => return Input::Help,
            Key::F(4) if !key.shift => return Input::ReplaceAll,
            Key::F(3) => {
                return Input::Navigate {
                    backward: key.shift,
                };
            }
            _ => {}
        }
    }
    field_key(key).map_or(Input::Unrecognized, Input::Text)
}
