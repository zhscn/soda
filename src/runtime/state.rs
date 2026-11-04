//! What outlives a session: the histories of the prompts, as savehist
//! keeps Emacs's, where the caret was in recently closed files, and the
//! projects files were opened in. The text form has one tab-separated
//! record per line, so a damaged line loses only itself.
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

/// Files whose caret position is remembered.
const POSITION_LIMIT: usize = 200;
/// Projects remembered for choosing one, like project.el's list.
const PROJECT_LIMIT: usize = 100;

#[derive(Default)]
pub(super) struct State {
    /// Each history by name, oldest first.
    pub histories: BTreeMap<String, Vec<String>>,
    /// Paths with a zero-based line and logical column, oldest first.
    positions: Vec<(PathBuf, usize, usize)>,
    /// Project roots, oldest first.
    projects: Vec<PathBuf>,
}
fn escape(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace('\t', "\\t")
        .replace('\n', "\\n")
}
fn unescape(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars();
    while let Some(ch) = chars.next() {
        match (ch, ch == '\\') {
            (_, true) => match chars.next() {
                Some('t') => out.push('\t'),
                Some('n') => out.push('\n'),
                Some(other) => out.push(other),
                None => {}
            },
            (ch, false) => out.push(ch),
        }
    }
    out
}
impl State {
    pub fn parse(text: &str) -> Self {
        let mut state = Self::default();
        for line in text.lines() {
            let fields: Vec<_> = line.split('\t').map(unescape).collect();
            match fields.as_slice() {
                [kind, name, entry] if kind == "history" => state
                    .histories
                    .entry(name.clone())
                    .or_default()
                    .push(entry.clone()),
                // Before histories had names, the two there were.
                [kind, entry] if kind == "command" || kind == "search" => state
                    .histories
                    .entry(kind.clone())
                    .or_default()
                    .push(entry.clone()),
                [kind, path] if kind == "project" => state.remember_project(PathBuf::from(path)),
                [kind, path, line, column] if kind == "position" => {
                    if let (Ok(line), Ok(column)) = (line.parse(), column.parse()) {
                        state.remember(PathBuf::from(path), line, column);
                    }
                }
                _ => {}
            }
        }
        state
    }
    pub fn text(&self) -> String {
        let mut out = String::new();
        for (name, entries) in &self.histories {
            let name = escape(name);
            for entry in entries {
                out.push_str(&format!("history\t{name}\t{}\n", escape(entry)));
            }
        }
        for path in &self.projects {
            let path = escape(&path.to_string_lossy());
            out.push_str(&format!("project\t{path}\n"));
        }
        for (path, line, column) in &self.positions {
            let path = escape(&path.to_string_lossy());
            out.push_str(&format!("position\t{path}\t{line}\t{column}\n"));
        }
        out
    }
    pub fn remember(&mut self, path: PathBuf, line: usize, column: usize) {
        self.positions.retain(|(p, ..)| *p != path);
        if self.positions.len() == POSITION_LIMIT {
            self.positions.remove(0);
        }
        self.positions.push((path, line, column));
    }
    /// Makes a file the most recent, keeping its caret position.
    pub fn touch(&mut self, path: &Path) {
        let (line, column) = self.position(path).unwrap_or((0, 0));
        self.remember(path.to_owned(), line, column);
    }
    /// Remembered files, newest first.
    pub fn recent(&self) -> Vec<PathBuf> {
        self.positions
            .iter()
            .rev()
            .map(|(path, ..)| path.clone())
            .collect()
    }
    /// Makes a project the most recent.
    pub fn remember_project(&mut self, root: PathBuf) {
        self.projects.retain(|p| *p != root);
        if self.projects.len() == PROJECT_LIMIT {
            self.projects.remove(0);
        }
        self.projects.push(root);
    }
    /// Remembered projects, newest first.
    pub fn projects(&self) -> Vec<PathBuf> {
        self.projects.iter().rev().cloned().collect()
    }
    pub fn position(&self, path: &Path) -> Option<(usize, usize)> {
        self.positions
            .iter()
            .find(|(p, ..)| p == path)
            .map(|(_, line, column)| (*line, *column))
    }
}

#[cfg(test)]
mod tests {
    use super::State;
    use std::path::{Path, PathBuf};
    #[test]
    fn state_survives_its_text_form() {
        let mut state = State::default();
        let commands = vec!["shell printf 'a\\tb'".to_owned(), "two\nlines".into()];
        state.histories.insert("command".into(), commands.clone());
        state.histories.insert("search".into(), vec!["foo".into()]);
        state.remember(PathBuf::from("/a b/c"), 3, 4);
        state.remember(PathBuf::from("/d"), 1, 0);
        state.remember(PathBuf::from("/a b/c"), 5, 6);
        state.remember_project(PathBuf::from("/p"));
        state.remember_project(PathBuf::from("/q\tr"));
        state.remember_project(PathBuf::from("/p"));
        let text = format!("{}garbage\nposition\t/e\tx\t1\n", state.text());
        let back = State::parse(&text);
        assert_eq!(back.histories["command"], commands);
        assert_eq!(back.histories["search"], ["foo"]);
        // The records of before histories had names still read.
        let old = State::parse("command\tclose\nsearch\ty\n");
        assert_eq!(old.histories["command"], ["close"]);
        assert_eq!(old.histories["search"], ["y"]);
        assert_eq!(
            back.projects(),
            [PathBuf::from("/p"), PathBuf::from("/q\tr")]
        );
        assert_eq!(back.position(Path::new("/a b/c")), Some((5, 6)));
        assert_eq!(back.position(Path::new("/d")), Some((1, 0)));
        assert_eq!(back.position(Path::new("/e")), None);
        assert_eq!(back.positions.last().unwrap().0, PathBuf::from("/a b/c"));
    }
}
