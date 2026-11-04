//! Named histories of what prompts took, as Emacs's history variables: the
//! command line, search, and each kind of argument have their own, and a
//! prompt walks one with `M-p` and `M-n`. The histories only hold entries;
//! where a prompt has recalled to is the prompt's own, as Emacs keeps
//! `minibuffer-history-position` in the minibuffer.
use super::registry::{Slot, SlotKind};
use std::{
    collections::{BTreeMap, HashMap},
    path::{Path, PathBuf},
};

/// Whole command lines.
pub const COMMAND: &str = "command";
/// Searches.
pub const SEARCH: &str = "search";
/// Command names taken in the command line, as `extended-command-history`;
/// they order the command names, and `M-p` there recalls whole lines.
pub const COMMAND_NAME: &str = "extended-command";
/// Files, under `~` when they are below it, as `file-name-history`.
pub const FILE: &str = "file";
/// Entries each history keeps, as `history-length`.
const LIMIT: usize = 100;

#[derive(Clone, Default)]
pub struct Histories {
    /// Each history, oldest first.
    lists: BTreeMap<String, Vec<String>>,
}
impl Histories {
    /// A history's entries, oldest first.
    pub fn entries(&self, name: &str) -> &[String] {
        self.lists.get(name).map_or(&[], Vec::as_slice)
    }
    /// Every history that has entries, by name.
    pub fn all(&self) -> impl Iterator<Item = (&str, &[String])> {
        self.lists
            .iter()
            .map(|(name, entries)| (name.as_str(), entries.as_slice()))
    }
    /// Adds an entry, moving an equal one to the end; blank ones are left
    /// out, as `add-to-history` leaves out empty strings.
    pub fn record(&mut self, name: &str, entry: &str) {
        if entry.trim().is_empty() {
            return;
        }
        let entries = self.lists.entry(name.to_owned()).or_default();
        entries.retain(|e| e != entry);
        if entries.len() == LIMIT {
            entries.remove(0);
        }
        entries.push(entry.to_owned());
    }
    /// Replaces a history, oldest first, keeping its newest entries.
    pub fn set(&mut self, name: &str, entries: Vec<String>) {
        self.lists.remove(name);
        entries.iter().for_each(|entry| self.record(name, entry));
    }
    /// How recently each entry of a history was taken: 0 is the newest.
    pub fn ranks(&self, name: &str) -> HashMap<String, u32> {
        self.entries(name)
            .iter()
            .rev()
            .enumerate()
            .map(|(age, entry)| (entry.clone(), age as u32))
            .collect()
    }
}

/// Merges a history kept in memory with the same history another session
/// saved since, both oldest first, as `savehist--merge`: the two are
/// interleaved from their newest, ours first, keeping each entry's newest
/// place.
pub fn merge(ours: &[String], theirs: &[String]) -> Vec<String> {
    let mut merged: Vec<&String> = vec![];
    let (mut a, mut b) = (ours.iter().rev(), theirs.iter().rev());
    loop {
        match (a.next(), b.next()) {
            (None, None) => break,
            (x, y) => merged.extend(x.into_iter().chain(y)),
        }
    }
    let mut seen = std::collections::HashSet::new();
    merged.retain(|entry| seen.insert(*entry));
    let mut out: Vec<String> = merged.into_iter().take(LIMIT).cloned().collect();
    out.reverse();
    out
}

/// The history an argument slot of a command takes from and adds to, as
/// the history variable each `completing-read` names: files, buffers and
/// projects share one each whatever the command, a free argument has one
/// of its command's, and fixed words and answers have none.
pub fn of_slot(command: &str, slots: &[Slot], index: usize) -> Option<String> {
    let slot = &slots[index];
    Some(
        match slot.kind {
            SlotKind::Path | SlotKind::File | SlotKind::Recent => FILE,
            SlotKind::Buffer | SlotKind::CurrentBuffer => "buffer",
            SlotKind::Project => "project",
            SlotKind::Symbol => "symbol",
            SlotKind::Option => "option",
            SlotKind::Face => "face",
            SlotKind::Theme => "theme",
            SlotKind::Language => "language",
            SlotKind::Keymap => "keymap",
            SlotKind::Choice(_) | SlotKind::Item => return None,
            SlotKind::Word | SlotKind::Rest => {
                // `pipe` reads a shell command as `shell` does, as
                // `shell-command-on-region` shares `shell-command-history`.
                let command = match command {
                    "pipe" => "shell",
                    command => command,
                };
                let free = slots
                    .iter()
                    .filter(|s| matches!(s.kind, SlotKind::Word | SlotKind::Rest))
                    .count();
                return Some(if free == 1 {
                    command.to_owned()
                } else {
                    format!("{command}-{}", slot.name.to_ascii_lowercase())
                });
            }
        }
        .to_owned(),
    )
}

/// A path as file histories keep it: under `~` when it is below it, with
/// `.` and `..` resolved; None when it is not UTF-8.
pub fn abbreviate(path: &Path, home: Option<&Path>) -> Option<String> {
    let normal = normalize(path);
    let text = match home.and_then(|home| normal.strip_prefix(home).ok()) {
        Some(below) if below.as_os_str().is_empty() => "~".to_owned(),
        Some(below) => format!("~/{}", below.to_str()?),
        None => normal.to_str()?.to_owned(),
    };
    (!text.chars().any(char::is_control)).then_some(text)
}
/// A path with `.` and `..` resolved by its text alone.
pub fn normalize(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut normal = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normal.pop();
            }
            component => normal.push(component),
        }
    }
    normal
}
/// The path a file history's entry names.
pub fn expand(entry: &str, home: Option<&Path>) -> PathBuf {
    match (entry.strip_prefix('~'), home) {
        (Some(below), Some(home)) => home.join(below.trim_start_matches('/')),
        _ => PathBuf::from(entry),
    }
}
/// Where a prompt has recalled to in one history: the field it fills and
/// the entry it shows, with the text the field had before recalling.
#[derive(Default)]
pub struct Recall {
    field: Option<(String, usize)>,
    recalled: Option<(usize, String)>,
}
impl Recall {
    /// The text to show after moving back to older entries or forward to
    /// newer ones in `entries`, oldest first; past the newest is the text
    /// from before recalling. `field` names the history and where the
    /// field starts; moving to another field starts over.
    pub fn step(
        &mut self,
        field: (&str, usize),
        entries: &[String],
        text: &str,
        backward: bool,
    ) -> Option<String> {
        if self.field.as_ref().map(|(n, s)| (n.as_str(), *s)) != Some(field) {
            self.field = Some((field.0.to_owned(), field.1));
            self.recalled = None;
        }
        let current = match &self.recalled {
            Some((index, _)) if entries.get(*index).is_some_and(|e| e == text) => Some(*index),
            _ => None,
        };
        let draft = match (&self.recalled, current) {
            (Some((_, draft)), Some(_)) => draft.clone(),
            _ => text.to_owned(),
        };
        let next = match (current, backward) {
            (None, true) => entries.len().checked_sub(1)?,
            (None, false) => return None,
            (Some(index), true) => index.checked_sub(1)?,
            (Some(index), false) if index + 1 < entries.len() => index + 1,
            (Some(_), false) => {
                self.recalled = None;
                return Some(draft);
            }
        };
        self.recalled = Some((next, draft));
        Some(entries[next].clone())
    }
}

#[cfg(test)]
mod tests {
    use super::{Histories, Recall, merge};
    #[test]
    fn recall_walks_entries_and_returns_to_the_draft() {
        let mut histories = Histories::default();
        for entry in ["a", "b", "a", " "] {
            histories.record("h", entry);
        }
        let entries = histories.entries("h").to_vec();
        assert_eq!(entries, ["b", "a"]);
        let mut recall = Recall::default();
        let mut step = |text: &str, backward| recall.step(("h", 0), &entries, text, backward);
        assert_eq!(step("dr", false), None);
        assert_eq!(step("dr", true).as_deref(), Some("a"));
        assert_eq!(step("a", true).as_deref(), Some("b"));
        assert_eq!(step("b", true), None);
        assert_eq!(step("b", false).as_deref(), Some("a"));
        assert_eq!(step("a", false).as_deref(), Some("dr"));
        // Editing a recalled entry makes it the new draft.
        assert_eq!(step("dr", true).as_deref(), Some("a"));
        assert_eq!(step("ax", true).as_deref(), Some("a"));
        assert_eq!(step("a", false).as_deref(), Some("ax"));
    }
    #[test]
    fn another_field_starts_over() {
        let entries = vec!["x".to_owned(), "y".to_owned()];
        let mut recall = Recall::default();
        assert_eq!(
            recall.step(("h", 0), &entries, "", true).as_deref(),
            Some("y")
        );
        assert_eq!(
            recall.step(("h", 4), &entries, "y", true).as_deref(),
            Some("y")
        );
    }
    #[test]
    fn merging_interleaves_from_the_newest() {
        let v = |items: &[&str]| items.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let ours = v(&["a", "b", "c"]);
        let theirs = v(&["x", "b", "y"]);
        let merged = merge(&ours, &theirs);
        assert_eq!(merged, v(&["x", "a", "b", "y", "c"]));
        assert_eq!(merge(&ours, &ours), ours);
    }
}
