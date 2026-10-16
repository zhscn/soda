//! Literal, finite key sequences. Complete bindings cannot also be prefixes.
use super::{Command, Key, KeyStroke};
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Chord {
    code: Key,
    control: bool,
}
impl Chord {
    const fn ctrl(ch: char) -> Self {
        Self {
            code: Key::Char(ch),
            control: true,
        }
    }
    const fn plain(ch: char) -> Self {
        Self {
            code: Key::Char(ch),
            control: false,
        }
    }
    fn from_key(key: KeyStroke) -> Option<Self> {
        (!key.alt && !key.shift && !key.unsupported_modifiers && !key.release).then_some(Self {
            code: key.code,
            control: key.control,
        })
    }
}
use Chord as C;
const MAX_SEQUENCE_KEYS: usize = 4;
const BINDINGS: &[(&[Chord], Command)] = &[
    (&[C::ctrl('x'), C::ctrl('f')], Command::Open),
    (
        &[C::ctrl('x'), C::ctrl('s')],
        Command::Save { choose_path: false },
    ),
    (
        &[C::ctrl('x'), C::ctrl('w')],
        Command::Save { choose_path: true },
    ),
    (&[C::ctrl('x'), C::ctrl('c')], Command::Quit),
    (&[C::ctrl('x'), C::plain('b')], Command::SwitchBuffer),
    (&[C::ctrl('x'), C::plain('k')], Command::Close),
    (&[C::ctrl('x'), C::plain('n')], Command::New),
    (
        &[C::ctrl('x'), C::plain('h')],
        Command::Edit(crate::editor::Command::SelectAll),
    ),
    (&[C::ctrl('x'), C::plain('g')], Command::Goto),
    (&[C::ctrl('x'), C::plain('r')], Command::Reload),
    (
        &[C::ctrl('x'), C::plain('p'), C::plain('f')],
        Command::PickFiles,
    ),
    (&[C::plain(' '), C::plain('f')], Command::PickFiles),
    (&[C::plain(' '), C::plain('b')], Command::SwitchBuffer),
    (
        &[C::plain(' '), C::plain('s')],
        Command::Save { choose_path: false },
    ),
    (&[C::plain(' '), C::plain('q')], Command::Quit),
];
pub(super) enum Resolution {
    Prefix,
    Complete(Command),
    Invalid,
}
#[derive(Default)]
pub(super) struct Sequence {
    keys: Vec<Chord>,
}
impl Sequence {
    pub fn active(&self) -> bool {
        !self.keys.is_empty()
    }
    pub fn clear(&mut self) {
        self.keys.clear();
    }
    pub fn starts(key: KeyStroke, normal: bool) -> bool {
        Chord::from_key(key)
            .is_some_and(|chord| chord == C::ctrl('x') || (normal && chord == C::plain(' ')))
    }
    pub fn push(&mut self, key: KeyStroke) -> Resolution {
        let Some(chord) = Chord::from_key(key) else {
            self.clear();
            return Resolution::Invalid;
        };
        if self.keys.len() == MAX_SEQUENCE_KEYS {
            self.clear();
            return Resolution::Invalid;
        }
        self.keys.push(chord);
        for (keys, action) in BINDINGS {
            if *keys == self.keys {
                self.clear();
                return Resolution::Complete(action.clone());
            }
        }
        if BINDINGS
            .iter()
            .any(|(keys, _)| keys.starts_with(&self.keys))
        {
            Resolution::Prefix
        } else {
            self.clear();
            Resolution::Invalid
        }
    }
    pub fn hint(&self) -> String {
        let prefix = self
            .keys
            .iter()
            .map(|key| match key.code {
                Key::Char(' ') => "SPC".into(),
                Key::Char(ch) => format!("{}{ch}", if key.control { "C-" } else { "" }),
                _ => unreachable!(),
            })
            .collect::<Vec<_>>()
            .join(" ");
        format!("{prefix} …  (C-g / Esc cancels)")
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bindings_are_unique_bounded_and_have_no_leaf_prefix_conflicts() {
        for (index, (keys, _)) in BINDINGS.iter().enumerate() {
            assert!((2..=MAX_SEQUENCE_KEYS).contains(&keys.len()));
            for (other, _) in &BINDINGS[index + 1..] {
                assert!(!keys.starts_with(other) && !other.starts_with(keys));
            }
        }
    }
}
