//! Counts and operator-pending parsing, independent of document storage.
use super::{Insert, Motion, Operator, VimCommand};
use crate::interaction::Command;
#[derive(Default)]
pub(in crate::interaction) struct State {
    pub(super) count: usize,
    pub(super) replace: Option<usize>,
    pub(super) operator: Option<(Operator, usize, bool)>,
    pub(super) g: bool,
    pub(super) goal: Option<crate::core::LogicalColumn>,
    pub(super) visual: Option<(usize, usize)>,
    pub search_backward: bool,
    pub last_search: Option<crate::editor::search::SearchQuery>,
    pub insert_view: Option<crate::application::ViewId>,
}
impl State {
    pub fn caret(&self) -> Option<usize> {
        self.visual.map(|(_, head)| head)
    }
    pub fn clear(&mut self) {
        self.count = 0;
        self.replace = None;
        self.operator = None;
        self.g = false;
    }
    pub fn active(&self) -> bool {
        self.count != 0 || self.operator.is_some() || self.g || self.replace.is_some()
    }
    pub fn hint(&self) -> String {
        let mut keys = String::new();
        if let Some((op, count, specified)) = self.operator {
            if specified {
                keys.push_str(&count.to_string());
            }
            keys.push(match op {
                Operator::Delete => 'd',
                Operator::Change => 'c',
                Operator::Yank => 'y',
            });
        }
        if let Some(count) = self.replace {
            if count > 1 {
                keys.push_str(&count.to_string());
            }
            keys.push('r');
        }
        if self.count > 0 {
            keys.push_str(&self.count.to_string());
        }
        if self.g {
            keys.push('g');
        }
        format!("{keys} …  (Esc cancels)")
    }
    pub fn reset(&mut self) {
        self.clear();
        self.goal = None;
        self.visual = None;
    }
    pub fn key(&mut self, ch: char, visual: bool) -> Result<Option<Command>, &'static str> {
        if let Some(count) = self.replace.take() {
            return Ok(Some(Command::Vim(VimCommand::ReplaceChar(ch, count))));
        }
        if self.g && ch.is_ascii_digit() {
            self.clear();
            return Err("Invalid g sequence");
        }
        if ch.is_ascii_digit() && (ch != '0' || self.count != 0) {
            let next = self.count * 10 + ch.to_digit(10).unwrap() as usize;
            if next > 10000 {
                self.clear();
                return Err("Count exceeds 10000");
            }
            self.count = next;
            return Ok(None);
        }
        let specified = self.count != 0;
        let count = self.count.max(1);
        self.count = 0;
        if self.g {
            self.g = false;
            if ch == 'g' {
                return Ok(Some(self.motion(Motion::Top, count)));
            }
            self.clear();
            return Err("Unsupported g command");
        }
        if ch == 'g' {
            self.g = true;
            self.count = if specified { count } else { 0 };
            return Ok(None);
        }
        let motion = match ch {
            'h' => Some(Motion::Left),
            'l' => Some(Motion::Right),
            'j' => Some(Motion::Down),
            'k' => Some(Motion::Up),
            '0' => Some(Motion::Start),
            '^' => Some(Motion::First),
            '$' => Some(Motion::End),
            'w' => Some(Motion::Word),
            'b' => Some(Motion::BackWord),
            'e' => Some(Motion::EndWord),
            'G' => Some(Motion::Bottom),
            _ => None,
        };
        if let Some(motion) = motion {
            return Ok(Some(self.motion(
                motion,
                if ch == 'G' && !specified {
                    usize::MAX
                } else {
                    count
                },
            )));
        }
        let op = match ch {
            'd' => Some(Operator::Delete),
            'c' => Some(Operator::Change),
            'y' => Some(Operator::Yank),
            _ => None,
        };
        if let Some(op) = op {
            if visual {
                self.clear();
                return Ok(Some(Command::Vim(VimCommand::Operate(op, None, count))));
            }
            if let Some((pending, before, _)) = self.operator.take() {
                if pending == op {
                    return Ok(Some(Command::Vim(VimCommand::Operate(
                        op,
                        None,
                        (before * count).min(10000),
                    ))));
                }
                return Err("Invalid operator sequence");
            }
            self.operator = Some((op, count, specified));
            return Ok(None);
        }
        if self.operator.is_some() {
            self.clear();
            return Err("Unsupported operator motion");
        }
        if visual && !matches!(ch, 'v' | 'V' | 'x') {
            self.clear();
            return Err("Unsupported Visual command");
        }
        if visual && ch == 'x' {
            return Ok(Some(Command::Vim(VimCommand::Operate(
                Operator::Delete,
                None,
                count,
            ))));
        }
        if ch == 'r' {
            self.replace = Some(count);
            return Ok(None);
        }
        if specified
            && matches!(
                ch,
                'i' | 'a' | 'I' | 'A' | 'o' | 'O' | 'v' | 'V' | '/' | '?' | ':'
            )
        {
            return Err("Counts are not supported for this command");
        }
        let action = match ch {
            'i' => Command::Vim(VimCommand::Insert(Insert::Before)),
            'a' => Command::Vim(VimCommand::Insert(Insert::After)),
            'I' => Command::Vim(VimCommand::Insert(Insert::Start)),
            'A' => Command::Vim(VimCommand::Insert(Insert::End)),
            'o' => Command::Vim(VimCommand::Insert(Insert::Below)),
            'O' => Command::Vim(VimCommand::Insert(Insert::Above)),
            's' => Command::Vim(VimCommand::Operate(
                Operator::Change,
                Some(Motion::Right),
                count,
            )),
            'S' => Command::Vim(VimCommand::Operate(Operator::Change, None, count)),
            'x' => Command::Vim(VimCommand::DeleteChar {
                backward: false,
                count,
            }),
            'X' => Command::Vim(VimCommand::DeleteChar {
                backward: true,
                count,
            }),
            'D' => Command::Vim(VimCommand::Operate(
                Operator::Delete,
                Some(Motion::End),
                count,
            )),
            'C' => Command::Vim(VimCommand::Operate(
                Operator::Change,
                Some(Motion::End),
                count,
            )),
            'p' | 'P' => Command::Vim(VimCommand::Put {
                before: ch == 'P',
                count,
            }),
            'u' => Command::Vim(VimCommand::Undo { redo: false, count }),
            'v' | 'V' => Command::Vim(VimCommand::Visual {
                linewise: ch == 'V',
            }),
            '/' | '?' => Command::Vim(VimCommand::Search {
                backward: ch == '?',
            }),
            'n' | 'N' => Command::Vim(VimCommand::RepeatSearch {
                reverse: ch == 'N',
                count,
            }),
            ':' => Command::Ex(String::new()),
            _ => {
                self.clear();
                return Err("Unsupported Normal command");
            }
        };
        Ok(Some(action))
    }
    fn motion(&mut self, motion: Motion, count: usize) -> Command {
        if let Some((op, before, specified)) = self.operator.take() {
            Command::Vim(VimCommand::Operate(
                op,
                Some(motion),
                if count == usize::MAX {
                    if specified { before } else { count }
                } else {
                    (before * count).min(10000)
                },
            ))
        } else {
            Command::Vim(VimCommand::Move(motion, count))
        }
    }
}
