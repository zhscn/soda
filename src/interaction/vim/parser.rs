//! Counts and operator-pending parsing, independent of document storage.
use super::{
    Insert, Motion, Object, Operator, Target, VimCommand,
    motion::Find,
    replay::{Marks, Replay},
};
use crate::interaction::Command;

/// Commands that read one more character.
#[derive(Clone, Copy, Debug)]
pub(super) enum Pending {
    Replace,
    Find { till: bool, backward: bool },
    Object { inner: bool },
    Register,
    Record,
    Play,
    Mark,
    Jump { exact: bool },
}
#[derive(Default)]
pub(in crate::interaction) struct State {
    pub(super) count: usize,
    pub(super) pending: Option<(Pending, usize)>,
    pub(super) operator: Option<(Operator, usize, bool)>,
    pub(super) g: bool,
    /// A register named with `"` for the command being typed.
    pub(super) register: Option<char>,
    /// The register of the command just parsed, until it executes.
    pub(in crate::interaction) armed: Option<char>,
    pub(super) goal: Option<crate::core::LogicalColumn>,
    pub(in crate::interaction) visual: Option<(usize, usize)>,
    pub search_backward: bool,
    pub last_search: Option<crate::editor::search::SearchQuery>,
    pub(super) last_find: Option<Find>,
    pub insert_view: Option<crate::application::ViewId>,
    pub(in crate::interaction) replay: Replay,
    pub(in crate::interaction) marks: Marks,
}
fn operator_key(op: Operator) -> &'static str {
    match op {
        Operator::Delete => "d",
        Operator::Change => "c",
        Operator::Yank => "y",
        Operator::Indent => ">",
        Operator::Outdent => "<",
        Operator::Lower => "gu",
        Operator::Upper => "gU",
        Operator::ToggleCase => "g~",
    }
}
impl State {
    pub fn caret(&self) -> Option<usize> {
        self.visual.map(|(_, head)| head)
    }
    pub fn clear(&mut self) {
        self.count = 0;
        self.pending = None;
        self.operator = None;
        self.g = false;
        self.register = None;
    }
    pub fn active(&self) -> bool {
        self.count != 0
            || self.operator.is_some()
            || self.g
            || self.pending.is_some()
            || self.register.is_some()
    }
    pub fn hint(&self) -> String {
        let mut keys = String::new();
        if let Some(register) = self.register {
            keys.push('"');
            keys.push(register);
        }
        if let Some((op, count, specified)) = self.operator {
            if specified {
                keys.push_str(&count.to_string());
            }
            keys.push_str(operator_key(op));
        }
        if let Some((pending, count)) = self.pending {
            if count > 1 {
                keys.push_str(&count.to_string());
            }
            keys.push_str(match pending {
                Pending::Replace => "r",
                Pending::Find {
                    till: false,
                    backward: false,
                } => "f",
                Pending::Find {
                    till: true,
                    backward: false,
                } => "t",
                Pending::Find {
                    till: false,
                    backward: true,
                } => "F",
                Pending::Find {
                    till: true,
                    backward: true,
                } => "T",
                Pending::Object { inner: true } => "i",
                Pending::Object { inner: false } => "a",
                Pending::Register => "\"",
                Pending::Record => "q",
                Pending::Play => "@",
                Pending::Mark => "m",
                Pending::Jump { exact: false } => "'",
                Pending::Jump { exact: true } => "`",
            });
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
        let result = self.parse(ch, visual);
        match &result {
            Ok(Some(_)) => {
                self.armed = self.register.take();
                self.clear();
            }
            Ok(None) => {}
            Err(_) => self.clear(),
        }
        result
    }
    fn parse(&mut self, ch: char, visual: bool) -> Result<Option<Command>, &'static str> {
        let vim = |command| Ok(Some(Command::Vim(command)));
        if let Some((pending, count)) = self.pending.take() {
            return self.complete(pending, ch, count, visual);
        }
        if ch.is_ascii_digit() && (ch != '0' || self.count != 0) {
            if self.g {
                return Err("Invalid g sequence");
            }
            let next = self.count * 10 + ch.to_digit(10).unwrap() as usize;
            if next > 10000 {
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
            let op = match ch {
                'g' => return Ok(Some(self.motion(Motion::Top, count))),
                'u' => Operator::Lower,
                'U' => Operator::Upper,
                '~' => Operator::ToggleCase,
                _ => return Err("Unsupported g command"),
            };
            return self.operator(op, count, specified, visual);
        }
        if ch == 'g' {
            self.g = true;
            self.count = if specified { count } else { 0 };
            return Ok(None);
        }
        let find = |till, backward| Pending::Find { till, backward };
        let pending = match ch {
            'f' => Some(find(false, false)),
            't' => Some(find(true, false)),
            'F' => Some(find(false, true)),
            'T' => Some(find(true, true)),
            'i' | 'a' if self.operator.is_some() || visual => {
                Some(Pending::Object { inner: ch == 'i' })
            }
            'r' if !visual => Some(Pending::Replace),
            '"' if self.operator.is_none() => Some(Pending::Register),
            _ => None,
        };
        if let Some(pending) = pending {
            self.pending = Some((pending, count));
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
            ';' => Some(Motion::RepeatFind { reverse: false }),
            ',' => Some(Motion::RepeatFind { reverse: true }),
            '%' => Some(Motion::MatchPair),
            '}' => Some(Motion::Paragraph { forward: true }),
            '{' => Some(Motion::Paragraph { forward: false }),
            _ => None,
        };
        if let Some(motion) = motion {
            let count = if ch == 'G' && !specified {
                usize::MAX
            } else {
                count
            };
            return Ok(Some(self.motion(motion, count)));
        }
        let op = match ch {
            'd' => Some(Operator::Delete),
            'c' => Some(Operator::Change),
            'y' => Some(Operator::Yank),
            '>' => Some(Operator::Indent),
            '<' => Some(Operator::Outdent),
            // Repeating the key of a g operator applies it to lines (`guu`).
            'u' if self.operator.is_some_and(|(op, ..)| op == Operator::Lower) => {
                Some(Operator::Lower)
            }
            'U' if self.operator.is_some_and(|(op, ..)| op == Operator::Upper) => {
                Some(Operator::Upper)
            }
            '~' if self
                .operator
                .is_some_and(|(op, ..)| op == Operator::ToggleCase) =>
            {
                Some(Operator::ToggleCase)
            }
            _ => None,
        };
        if let Some(op) = op {
            return self.operator(op, count, specified, visual);
        }
        if self.operator.is_some() {
            return Err("Unsupported operator motion");
        }
        if visual {
            return match ch {
                'v' | 'V' => vim(VimCommand::Visual {
                    linewise: ch == 'V',
                }),
                'x' => vim(VimCommand::Operate(Operator::Delete, Target::Line, count)),
                '~' => vim(VimCommand::Operate(
                    Operator::ToggleCase,
                    Target::Line,
                    count,
                )),
                'u' => vim(VimCommand::Operate(Operator::Lower, Target::Line, count)),
                'U' => vim(VimCommand::Operate(Operator::Upper, Target::Line, count)),
                'J' => vim(VimCommand::Join(count)),
                'o' => vim(VimCommand::VisualOther),
                'p' | 'P' => vim(VimCommand::Put {
                    before: ch == 'P',
                    count,
                }),
                _ => Err("Unsupported Visual command"),
            };
        }
        if specified
            && matches!(
                ch,
                'i' | 'a'
                    | 'I'
                    | 'A'
                    | 'o'
                    | 'O'
                    | 'v'
                    | 'V'
                    | '/'
                    | '?'
                    | ':'
                    | 'q'
                    | 'm'
                    | '\''
                    | '`'
            )
        {
            return Err("Counts are not supported for this command");
        }
        let pending = match ch {
            'q' if self.replay.recording().is_none() => Some(Pending::Record),
            '@' => Some(Pending::Play),
            'm' => Some(Pending::Mark),
            '\'' => Some(Pending::Jump { exact: false }),
            '`' => Some(Pending::Jump { exact: true }),
            _ => None,
        };
        if let Some(pending) = pending {
            self.pending = Some((pending, count));
            return Ok(None);
        }
        let command = match ch {
            'i' => VimCommand::Insert(Insert::Before),
            'a' => VimCommand::Insert(Insert::After),
            'I' => VimCommand::Insert(Insert::Start),
            'A' => VimCommand::Insert(Insert::End),
            'o' => VimCommand::Insert(Insert::Below),
            'O' => VimCommand::Insert(Insert::Above),
            's' => VimCommand::Operate(Operator::Change, Target::Motion(Motion::Right), count),
            'S' => VimCommand::Operate(Operator::Change, Target::Line, count),
            'x' => VimCommand::DeleteChar {
                backward: false,
                count,
            },
            'X' => VimCommand::DeleteChar {
                backward: true,
                count,
            },
            'D' => VimCommand::Operate(Operator::Delete, Target::Motion(Motion::End), count),
            'C' => VimCommand::Operate(Operator::Change, Target::Motion(Motion::End), count),
            'p' | 'P' => VimCommand::Put {
                before: ch == 'P',
                count,
            },
            'u' => VimCommand::Undo { redo: false, count },
            '~' => VimCommand::ToggleCaseChar(count),
            'J' => VimCommand::Join(count),
            '.' => VimCommand::RepeatChange(specified.then_some(count)),
            'q' => VimCommand::Record(None),
            '*' | '#' => VimCommand::SearchWord {
                backward: ch == '#',
                count,
            },
            'v' | 'V' => VimCommand::Visual {
                linewise: ch == 'V',
            },
            '/' | '?' => VimCommand::Search {
                backward: ch == '?',
            },
            'n' | 'N' => VimCommand::RepeatSearch {
                reverse: ch == 'N',
                count,
            },
            ':' => return Ok(Some(Command::Ex(String::new()))),
            _ => return Err("Unsupported Normal command"),
        };
        vim(command)
    }
    /// The character after `r`, `f`, `i`, `"` and the other prefixes.
    fn complete(
        &mut self,
        pending: Pending,
        ch: char,
        count: usize,
        visual: bool,
    ) -> Result<Option<Command>, &'static str> {
        let vim = |command| Ok(Some(Command::Vim(command)));
        match pending {
            Pending::Replace => vim(VimCommand::ReplaceChar(ch, count)),
            Pending::Find { till, backward } => {
                let find = Find {
                    ch,
                    till,
                    backward,
                    repeat: false,
                };
                self.last_find = Some(find);
                Ok(Some(self.motion(Motion::Find(find), count)))
            }
            Pending::Object { inner } => {
                let object = Object::parse(ch, inner).ok_or("Unknown text object")?;
                match self.operator.take() {
                    Some((op, before, _)) => vim(VimCommand::Operate(
                        op,
                        Target::Object(object),
                        (before * count).min(10000),
                    )),
                    None if visual => vim(VimCommand::Select(object, count)),
                    None => Err("Text objects need an operator or Visual mode"),
                }
            }
            Pending::Register => {
                if !(ch.is_ascii_alphabetic() || matches!(ch, '"' | '_' | '+' | '*')) {
                    return Err("Invalid register");
                }
                self.register = Some(ch);
                // A count typed before the register still applies.
                self.count = if count > 1 { count } else { 0 };
                Ok(None)
            }
            Pending::Record => {
                if !ch.is_ascii_alphabetic() {
                    return Err("Invalid register");
                }
                vim(VimCommand::Record(Some(ch)))
            }
            Pending::Play => {
                if !(ch.is_ascii_alphabetic() || ch == '@') {
                    return Err("Invalid register");
                }
                vim(VimCommand::Play(ch.to_ascii_lowercase(), count))
            }
            Pending::Mark => {
                if !ch.is_ascii_lowercase() {
                    return Err("Invalid mark");
                }
                vim(VimCommand::SetMark(ch))
            }
            Pending::Jump { exact } => {
                if !ch.is_ascii_lowercase() {
                    return Err("Invalid mark");
                }
                if self.operator.is_some() {
                    return Err("Unsupported operator motion");
                }
                vim(VimCommand::JumpMark { mark: ch, exact })
            }
        }
    }
    fn operator(
        &mut self,
        op: Operator,
        count: usize,
        specified: bool,
        visual: bool,
    ) -> Result<Option<Command>, &'static str> {
        if visual {
            return Ok(Some(Command::Vim(VimCommand::Operate(
                op,
                Target::Line,
                count,
            ))));
        }
        if let Some((pending, before, _)) = self.operator.take() {
            if pending == op {
                return Ok(Some(Command::Vim(VimCommand::Operate(
                    op,
                    Target::Line,
                    (before * count).min(10000),
                ))));
            }
            return Err("Invalid operator sequence");
        }
        self.operator = Some((op, count, specified));
        Ok(None)
    }
    fn motion(&mut self, motion: Motion, count: usize) -> Command {
        if let Some((op, before, specified)) = self.operator.take() {
            Command::Vim(VimCommand::Operate(
                op,
                Target::Motion(motion),
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
