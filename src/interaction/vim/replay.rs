//! Replayed input and marks. `.` and macros replay the keys that were typed,
//! so whatever those keys did, including text typed in Insert mode, happens
//! again through the same routing. Marks are document positions mapped
//! through every edit.
use crate::{
    application::Update,
    core::Association,
    editor::{Document, DocumentId, DocumentPosition},
    interaction::{Key, KeyStroke, UserInput},
};
use std::collections::HashMap;

#[derive(Default)]
pub(in crate::interaction) struct Replay {
    recording: Option<(char, Vec<UserInput>)>,
    macros: HashMap<char, Vec<UserInput>>,
    last_macro: Option<char>,
    /// Keys since Normal mode was last idle.
    typed: Vec<UserInput>,
    /// Set by a command that changes text; its keys become the last change
    /// once Normal mode is idle again, after any Insert mode that followed.
    pub(in crate::interaction) changed: bool,
    capturing: bool,
    last_change: Vec<UserInput>,
}
impl Replay {
    pub fn recording(&self) -> Option<char> {
        self.recording.as_ref().map(|(register, _)| *register)
    }
    /// Starts recording; an uppercase register appends to its lowercase one.
    pub fn start(&mut self, register: char) {
        let keys = if register.is_ascii_uppercase() {
            self.macros
                .get(&register.to_ascii_lowercase())
                .cloned()
                .unwrap_or_default()
        } else {
            vec![]
        };
        self.recording = Some((register.to_ascii_lowercase(), keys));
    }
    pub fn stop(&mut self) {
        if let Some((register, mut keys)) = self.recording.take() {
            // The `q` that stopped recording was recorded too.
            keys.pop();
            self.macros.insert(register, keys);
        }
    }
    /// Keys a macro replays; `@` names the last one played.
    pub fn play(&mut self, register: char) -> Option<Vec<UserInput>> {
        let register = if register == '@' {
            self.last_macro?
        } else {
            register
        };
        self.last_macro = Some(register);
        self.macros.get(&register).cloned()
    }
    /// Keys `.` replays: the last change, with `count` replacing the count
    /// typed before it.
    pub fn last_change(&self, count: Option<usize>) -> Option<Vec<UserInput>> {
        if self.last_change.is_empty() {
            return None;
        }
        let Some(count) = count else {
            return Some(self.last_change.clone());
        };
        let digits = self
            .last_change
            .iter()
            .enumerate()
            .take_while(|(index, input)| {
                matches!(input, UserInput::Key(KeyStroke { code: Key::Char(ch), .. })
                    if ch.is_ascii_digit() && (*index > 0 || *ch != '0'))
            })
            .count();
        let mut keys: Vec<_> = count
            .to_string()
            .chars()
            .map(|ch| UserInput::Key(KeyStroke::plain(Key::Char(ch))))
            .collect();
        keys.extend_from_slice(&self.last_change[digits..]);
        Some(keys)
    }
    /// Records typed input: into a macro while recording, and toward the
    /// next change. `idle` says Normal mode had nothing pending before it.
    pub fn typed(&mut self, input: &UserInput, replayed: bool, idle: bool) {
        if !replayed && let Some((_, keys)) = &mut self.recording {
            keys.push(input.clone());
        }
        if idle && !self.capturing {
            self.typed.clear();
            self.changed = false;
        }
        self.typed.push(input.clone());
    }
    /// Called after routing input; `idle` as in `typed`.
    pub fn routed(&mut self, idle: bool) {
        if std::mem::take(&mut self.changed) {
            self.capturing = true;
        }
        if idle {
            if std::mem::take(&mut self.capturing) {
                self.last_change = std::mem::take(&mut self.typed);
            } else {
                self.typed.clear();
            }
        }
    }
}

/// Lowercase marks, per document.
#[derive(Default)]
pub(in crate::interaction) struct Marks(HashMap<(DocumentId, char), DocumentPosition>);
impl Marks {
    pub fn set(&mut self, document: &Document, mark: char, offset: usize) {
        if let Ok(position) =
            document.position(crate::core::ByteOffset(offset), Association::Before)
        {
            self.0.insert((document.id(), mark), position);
        }
    }
    pub fn get(&self, document: &Document, mark: char) -> Option<usize> {
        let position = self.0.get(&(document.id(), mark))?;
        position.resolve(document).ok().map(|offset| offset.0)
    }
    /// Follows edits; marks of closed documents, and any that cannot be
    /// mapped, are dropped.
    pub fn observe(&mut self, update: &Update) {
        self.0
            .retain(|(document, _), _| !update.closed_documents.contains(document));
        let Some(edit) = update.edit.as_ref().and_then(|edit| edit.document.as_ref()) else {
            return;
        };
        self.0.retain(|(document, _), position| {
            if *document != edit.document_id {
                return true;
            }
            match position.map(edit, false) {
                Ok(Some(mapped)) => {
                    *position = mapped;
                    true
                }
                _ => false,
            }
        });
    }
}
