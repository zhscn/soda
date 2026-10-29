//! Lines entered at the command line and in search, most recent last, and
//! the place a prompt has recalled to.

/// Which history a prompt uses.
pub const COMMAND: usize = 0;
pub const SEARCH: usize = 1;
/// Entries each history keeps.
const LIMIT: usize = 100;

#[derive(Default)]
pub struct History {
    entries: Vec<String>,
    /// The recalled entry, and the text the prompt had before recalling.
    recalled: Option<(usize, String)>,
}
impl History {
    pub fn entries(&self) -> &[String] {
        &self.entries
    }
    /// Adds an entry, moving an equal one to the end.
    pub fn record(&mut self, entry: &str) {
        self.recalled = None;
        if entry.trim().is_empty() {
            return;
        }
        self.entries.retain(|e| e != entry);
        if self.entries.len() == LIMIT {
            self.entries.remove(0);
        }
        self.entries.push(entry.to_owned());
    }
    /// Forgets the recalled place, as a new prompt starts.
    pub fn reset(&mut self) {
        self.recalled = None;
    }
    /// The text to show after moving back to older entries or forward to
    /// newer ones; past the newest is the text from before recalling.
    pub fn recall(&mut self, text: &str, backward: bool) -> Option<String> {
        let current = match &self.recalled {
            Some((index, _)) if self.entries[*index] == text => Some(*index),
            _ => None,
        };
        let draft = match (&self.recalled, current) {
            (Some((_, draft)), Some(_)) => draft.clone(),
            _ => text.to_owned(),
        };
        let next = match (current, backward) {
            (None, true) => self.entries.len().checked_sub(1)?,
            (None, false) => return None,
            (Some(index), true) => index.checked_sub(1)?,
            (Some(index), false) if index + 1 < self.entries.len() => index + 1,
            (Some(_), false) => {
                self.recalled = None;
                return Some(draft);
            }
        };
        self.recalled = Some((next, draft));
        Some(self.entries[next].clone())
    }
}

#[cfg(test)]
mod tests {
    use super::History;
    #[test]
    fn recall_walks_entries_and_returns_to_the_draft() {
        let mut history = History::default();
        for entry in ["a", "b", "a", " "] {
            history.record(entry);
        }
        assert_eq!(history.entries(), ["b", "a"]);
        assert_eq!(history.recall("dr", false), None);
        assert_eq!(history.recall("dr", true).as_deref(), Some("a"));
        assert_eq!(history.recall("a", true).as_deref(), Some("b"));
        assert_eq!(history.recall("b", true), None);
        assert_eq!(history.recall("b", false).as_deref(), Some("a"));
        assert_eq!(history.recall("a", false).as_deref(), Some("dr"));
        // Editing a recalled entry makes it the new draft.
        assert_eq!(history.recall("dr", true).as_deref(), Some("a"));
        assert_eq!(history.recall("ax", true).as_deref(), Some("a"));
        assert_eq!(history.recall("a", false).as_deref(), Some("ax"));
    }
}
