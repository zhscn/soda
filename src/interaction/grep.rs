//! Results documents: project search writes `*grep*`, one match per line
//! as `path:line:column: text`, and `run` writes its output to `*run*`,
//! where compilers report `path:line[:column]: message`. Enter on such a
//! line, or stepping through the latest results, opens the location.
use super::{Message, Response};
use crate::{
    application::{Application, Event, ViewId},
    core::Selection,
    editor::Command as Edit,
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

/// A results document's view to step through: one on screen if any.
fn results_view(app: &Application, name: &str) -> Option<ViewId> {
    let document = app.workspace().scratch(name)?;
    app.views()
        .filter(|view| view.document_id == document)
        .max_by_key(|view| app.windows().contains(view.id))
        .map(|view| view.id)
}

fn open(file_root: &Path, text: &str, response: &mut Response) -> bool {
    let Some((path, line, column)) = location(text) else {
        return false;
    };
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    match super::path::resolve_path(file_root, home.as_deref(), Path::new(path)) {
        Ok(path) => response.events.push(Event::OpenAt { path, line, column }),
        Err(error) => response.message = Message::Set(error),
    }
    true
}

/// Opens the location on the caret line of the active view. Returns false
/// when that line names none, so Enter can keep its usual meaning.
pub(super) fn jump(app: &Application, file_root: &Path, response: &mut Response) -> bool {
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
    let text = snapshot.line(line).unwrap_or_default();
    open(file_root, &text, response)
}

/// Moves the results caret to the next or previous result line and opens
/// it, as Vim's `:cnext` and `:cprevious`. On fresh results the caret has
/// not visited its line yet, so a first line that is a result comes first.
pub(super) fn step(
    app: &Application,
    results: &str,
    fresh: bool,
    file_root: &Path,
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
        let text = snapshot.line(line).unwrap_or_default();
        if location(&text).is_some() {
            response.events.push(Event::Edit {
                view: view.id,
                command: Edit::SetSelection(Selection::caret(snapshot.line_start(line).unwrap())),
                time,
            });
            open(file_root, &text, response);
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
}
