//! Results documents: project search writes `*grep*`, a file's name with
//! its matches indented below as `line:column  text`, and `run` writes its
//! output to `*run*`, where compilers report `path:line[:column]: message`.
//! Enter on such a line, or stepping through the latest results, opens the
//! location.
use super::{Message, Response};
use crate::{
    application::{Application, Event, ViewId},
    core::{Selection, Snapshot},
    editor::{Command as Edit, DocumentId},
};
use std::{path::Path, time::Duration};

pub const SCRATCH: &str = "*grep*";
pub const RUN: &str = "*run*";

/// A search for the Runtime to run.
#[derive(Clone, Debug)]
pub struct GrepRequest {
    pub pattern: String,
    pub root: std::path::PathBuf,
}

/// A project search for one of the background search engines.
#[derive(Clone, Debug)]
pub enum SearchRequest {
    Grep(GrepRequest),
    Ripgrep(RipgrepRequest),
}

/// A ripgrep search assembled by the interactive frontend.
#[derive(Clone, Debug)]
pub struct RipgrepRequest {
    pub pattern: String,
    pub files: String,
    pub root: std::path::PathBuf,
    pub literal: bool,
    pub case: String,
    pub hidden: bool,
    pub no_ignore: bool,
}

impl RipgrepRequest {
    pub(crate) fn case_insensitive(&self) -> Result<bool, String> {
        match self.case.as_str() {
            "smart" => Ok(!self.pattern.chars().any(char::is_uppercase)),
            "insensitive" => Ok(true),
            "sensitive" => Ok(false),
            _ => Err("rg: case must be smart, sensitive or insensitive".into()),
        }
    }
}

/// The path, zero-based line and zero-based byte column of a result line,
/// `path:line:column:` or `path:line:`; a missing column is the first.
pub fn location(line: &str) -> Option<(&str, usize, usize)> {
    let (path, rest) = line.split_once(':')?;
    let path = path.trim_start();
    if path.is_empty() || path.contains(char::is_whitespace) {
        return None;
    }
    let (number, rest) = rest.split_once(':')?;
    let number = number.parse::<usize>().ok()?.checked_sub(1)?;
    let column = rest
        .split_once(':')
        .and_then(|(column, _)| column.parse::<usize>().ok());
    let column = match column {
        Some(column) => column.checked_sub(1)?,
        None => 0,
    };
    Some((path, number, column))
}

/// The zero-based line and column of a row under a file's name, indented
/// as `line:column  text`.
pub fn row(line: &str) -> Option<(usize, usize)> {
    let rest = line.strip_prefix(' ')?.trim_start();
    let (number, rest) = rest.split_once(':')?;
    let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let number = number.parse::<usize>().ok()?.checked_sub(1)?;
    let column = rest[..end].parse::<usize>().ok()?.checked_sub(1)?;
    Some((number, column))
}

/// Whether a scratch document holds results, and if so whether rows under
/// file names count: compiler output in `*run*` is not grouped.
pub fn results_kind(name: &str) -> Option<bool> {
    (name != "*messages*").then_some(name != RUN)
}
fn grouped(app: &Application, document: DocumentId) -> bool {
    app.workspace()
        .file(document)
        .and_then(|file| file.scratch())
        .and_then(results_kind)
        .unwrap_or(false)
}

/// The location a line of a results document names, if any.
fn entry(snapshot: &Snapshot, line: usize, grouped: bool) -> Option<(String, usize, usize)> {
    let text = snapshot.line(line)?;
    if grouped && let Some((number, column)) = row(&text) {
        let heading = (0..line)
            .rev()
            .filter_map(|line| snapshot.line(line))
            .find(|text| !text.is_empty() && !text.starts_with(char::is_whitespace))?;
        return Some((heading.into_owned(), number, column));
    }
    let (path, number, column) = location(&text)?;
    Some((path.to_owned(), number, column))
}

/// A results document's view to step through: one on screen if any.
fn results_view(app: &Application, name: &str) -> Option<ViewId> {
    let document = app.workspace().scratch(name)?;
    app.views()
        .filter(|view| view.document_id == document)
        .max_by_key(|view| app.windows().contains(view.id))
        .map(|view| view.id)
}

/// Relative paths mean the directory of the list that holds them.
fn open(base: &Path, target: (String, usize, usize), response: &mut Response) {
    let (path, line, column) = target;
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    match super::path::resolve_path(base, home.as_deref(), Path::new(&path)) {
        Ok(path) => response.events.push(Event::OpenAt { path, line, column }),
        Err(error) => response.message = Message::Set(error),
    }
}

/// Opens the location on the caret line of the active view. Returns false
/// when that line names none, so Enter can keep its usual meaning. On a
/// file's name, it goes to the first result below.
pub(super) fn jump(app: &Application, time: Duration, response: &mut Response) -> bool {
    let Some(view) = app.active_view().and_then(|id| app.view(id)) else {
        return false;
    };
    let editor = app.workspace().editor(view.document_id).unwrap();
    let snapshot = editor.model().document().snapshot();
    let head = editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head;
    let line = snapshot.line_of(head).unwrap();
    let grouped = grouped(app, view.document_id);
    let base = app.directory_of(view.document_id);
    if let Some(target) = entry(snapshot, line, grouped) {
        open(&base, target, response);
        return true;
    }
    let Some(target) = grouped.then(|| entry(snapshot, line + 1, true)).flatten() else {
        return false;
    };
    response.events.push(Event::Edit {
        view: view.id,
        command: Edit::SetSelection(Selection::caret(snapshot.line_start(line + 1).unwrap())),
        time,
    });
    open(&base, target, response);
    true
}

/// Moves the results caret to the next or previous result line and opens
/// it. On fresh results the caret has
/// not visited its line yet, so a first line that is a result comes first.
pub(super) fn step(
    app: &Application,
    results: &str,
    fresh: bool,
    backward: bool,
    time: Duration,
    response: &mut Response,
) {
    let Some(view) = results_view(app, results).and_then(|id| app.view(id)) else {
        response.message = Message::Set("No results".into());
        return;
    };
    let editor = app.workspace().editor(view.document_id).unwrap();
    let snapshot = editor.model().document().snapshot();
    let head = editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head;
    let current = snapshot.line_of(head).unwrap();
    let lines = snapshot.line_count();
    let grouped = grouped(app, view.document_id);
    let mut line = current;
    let mut stay = fresh && !backward && current == 0;
    loop {
        line = if std::mem::take(&mut stay) {
            line
        } else if backward {
            match line.checked_sub(1) {
                Some(line) => line,
                None => break,
            }
        } else if line + 1 < lines {
            line + 1
        } else {
            break;
        };
        if let Some(target) = entry(snapshot, line, grouped) {
            response.events.push(Event::Edit {
                view: view.id,
                command: Edit::SetSelection(Selection::caret(snapshot.line_start(line).unwrap())),
                time,
            });
            open(&app.directory_of(view.document_id), target, response);
            return;
        }
    }
    response.message = Message::Set(
        if backward {
            "At the first result"
        } else {
            "At the last result"
        }
        .into(),
    );
}

#[cfg(test)]
mod tests {
    #[test]
    fn result_lines_name_a_location() {
        assert_eq!(
            super::location("src/a.rs:12:5: let x = 1;"),
            Some(("src/a.rs", 11, 4))
        );
        assert_eq!(super::location("src/a.rs:12:5:"), Some(("src/a.rs", 11, 4)));
        assert_eq!(super::location("src/a.rs:0:5: x"), None);
        assert_eq!(super::location("no location here"), None);
        assert_eq!(super::location("a:b:c: d"), None);
        assert_eq!(
            super::location("src/a.cpp:3: error: x"),
            Some(("src/a.cpp", 2, 0))
        );
        assert_eq!(
            super::location("src/a.cpp:3:7: error: x"),
            Some(("src/a.cpp", 2, 6))
        );
        assert_eq!(super::location("note: see a.cpp:3"), None);
    }
    #[test]
    fn rows_are_indented_lines_and_columns() {
        assert_eq!(super::row("  12:5   text: 1"), Some((11, 4)));
        assert_eq!(super::row("  12:5"), Some((11, 4)));
        assert_eq!(super::row("12:5  text"), None);
        assert_eq!(super::row("  12:x  text"), None);
        assert_eq!(super::row("  0:5  text"), None);
        assert_eq!(super::row("  note: text"), None);
    }
}
