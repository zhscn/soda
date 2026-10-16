//! Explicit mode-scoped overrides. Complete bindings cannot also be prefixes.
use super::{Command, EditMode, Key, KeyStroke};
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BindingError {
    Empty,
    TooLong,
    InvalidKey,
    PrefixConflict,
}
impl std::fmt::Display for BindingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for BindingError {}
const MAX_KEYS: usize = 4;
fn canonical(mut key: KeyStroke) -> Result<KeyStroke, BindingError> {
    if key.release || key.unsupported_modifiers || key.code == Key::Unrecognized {
        return Err(BindingError::InvalidKey);
    }
    // Printable characters already encode Shift in their character value.
    if let Key::Char(ch) = key.code
        && !key.control
        && (ch.is_uppercase() || !ch.is_alphabetic())
    {
        key.shift = false;
    }
    Ok(key)
}
#[derive(Default)]
pub struct Keymap {
    entries: Vec<(EditMode, Vec<KeyStroke>, Command)>,
    inputs: Vec<(KeyStroke, super::Input)>,
}
impl Keymap {
    pub fn bind_input(&mut self, key: KeyStroke, input: super::Input) -> Result<(), BindingError> {
        let key = canonical(key)?;
        if let Some(entry) = self
            .inputs
            .iter_mut()
            .find(|(existing, _)| *existing == key)
        {
            entry.1 = input;
        } else {
            self.inputs.push((key, input));
        }
        Ok(())
    }
    pub fn unbind_input(&mut self, key: KeyStroke) -> Result<(), BindingError> {
        let key = canonical(key)?;
        self.inputs.retain(|(existing, _)| *existing != key);
        Ok(())
    }
    pub(super) fn input(&self, key: KeyStroke) -> Option<super::Input> {
        let key = canonical(key).ok()?;
        self.inputs
            .iter()
            .find(|(existing, _)| *existing == key)
            .map(|(_, input)| input.clone())
    }

    pub fn bind(
        &mut self,
        mode: EditMode,
        keys: &[KeyStroke],
        command: Command,
    ) -> Result<(), BindingError> {
        if keys.is_empty() {
            return Err(BindingError::Empty);
        }
        if keys.len() > MAX_KEYS {
            return Err(BindingError::TooLong);
        }
        let keys = keys
            .iter()
            .copied()
            .map(canonical)
            .collect::<Result<Vec<_>, _>>()?;
        if keys.iter().skip(1).any(|key| {
            key.code == Key::Esc || (key.control && matches!(key.code, Key::Char('c' | '[')))
        }) {
            return Err(BindingError::InvalidKey);
        }
        for (scope, existing, _) in &self.entries {
            if *scope == mode
                && *existing != keys
                && (keys.starts_with(existing) || existing.starts_with(&keys))
            {
                return Err(BindingError::PrefixConflict);
            }
        }
        if let Some(entry) = self
            .entries
            .iter_mut()
            .find(|(scope, existing, _)| *scope == mode && *existing == keys)
        {
            entry.2 = command;
        } else {
            self.entries.push((mode, keys, command));
        }
        Ok(())
    }
    pub fn unbind(&mut self, mode: EditMode, keys: &[KeyStroke]) -> Result<(), BindingError> {
        let keys = keys
            .iter()
            .copied()
            .map(canonical)
            .collect::<Result<Vec<_>, _>>()?;
        self.entries
            .retain(|(scope, existing, _)| *scope != mode || *existing != keys);
        Ok(())
    }
}
pub(super) enum Resolution {
    Pass,
    Prefix,
    Complete(Command),
    Invalid,
}
#[derive(Default)]
pub(super) struct Sequence {
    keys: Vec<KeyStroke>,
}
impl Sequence {
    pub fn active(&self) -> bool {
        !self.keys.is_empty()
    }
    pub fn clear(&mut self) {
        self.keys.clear();
    }
    pub fn push(&mut self, key: KeyStroke, mode: EditMode, map: &Keymap) -> Resolution {
        let Some(key) = canonical(key).ok() else {
            let active = self.active();
            self.clear();
            return if active {
                Resolution::Invalid
            } else {
                Resolution::Pass
            };
        };
        let active = self.active();
        self.keys.push(key);
        for (scope, keys, action) in &map.entries {
            if *scope == mode && *keys == self.keys {
                self.clear();
                return Resolution::Complete(action.clone());
            }
        }
        if map
            .entries
            .iter()
            .any(|(scope, keys, _)| *scope == mode && keys.starts_with(&self.keys))
        {
            Resolution::Prefix
        } else {
            self.clear();
            if active {
                Resolution::Invalid
            } else {
                Resolution::Pass
            }
        }
    }
    pub fn hint(&self) -> String {
        let keys = self
            .keys
            .iter()
            .map(|key| {
                let code = match key.code {
                    Key::Char(' ') => "SPC".into(),
                    Key::Char(ch) => ch.to_string(),
                    other => format!("{other:?}"),
                };
                format!(
                    "{}{}{}{code}",
                    if key.control { "C-" } else { "" },
                    if key.alt { "M-" } else { "" },
                    if key.shift { "S-" } else { "" }
                )
            })
            .collect::<Vec<_>>()
            .join(" ");
        format!("{keys} …  (Esc cancels)")
    }
}
