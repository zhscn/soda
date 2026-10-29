//! What outlives a session: command line and search history, and where the
//! caret was in recently closed files. The text form has one tab-separated
//! record per line, so a damaged line loses only itself.
use std::path::{Path, PathBuf};

/// Files whose caret position is remembered.
const POSITION_LIMIT: usize = 200;

#[derive(Default)]
pub(super) struct State {
    pub commands: Vec<String>,
    pub searches: Vec<String>,
    /// Paths with a zero-based line and logical column, oldest first.
    positions: Vec<(PathBuf, usize, usize)>,
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
                [kind, entry] if kind == "command" => state.commands.push(entry.clone()),
                [kind, entry] if kind == "search" => state.searches.push(entry.clone()),
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
        for entry in &self.commands {
            out.push_str(&format!("command\t{}\n", escape(entry)));
        }
        for entry in &self.searches {
            out.push_str(&format!("search\t{}\n", escape(entry)));
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
        let mut state = State {
            commands: vec!["shell printf 'a\\tb'".into(), "two\nlines".into()],
            searches: vec!["foo".into()],
            ..State::default()
        };
        state.remember(PathBuf::from("/a b/c"), 3, 4);
        state.remember(PathBuf::from("/d"), 1, 0);
        state.remember(PathBuf::from("/a b/c"), 5, 6);
        let text = format!("{}garbage\nposition\t/e\tx\t1\n", state.text());
        let back = State::parse(&text);
        assert_eq!(back.commands, state.commands);
        assert_eq!(back.searches, ["foo"]);
        assert_eq!(back.position(Path::new("/a b/c")), Some((5, 6)));
        assert_eq!(back.position(Path::new("/d")), Some((1, 0)));
        assert_eq!(back.position(Path::new("/e")), None);
        assert_eq!(back.positions.last().unwrap().0, PathBuf::from("/a b/c"));
    }
}
