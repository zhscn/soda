//! Results documents: project search writes `*grep*`, a file's name with
//! its matches indented below as `line:column  text`, and `run` writes its
//! output to `*run*`, where compilers report `path:line[:column]: message`.
//! Enter on such a line, or stepping through the latest results, opens the
//! location.
use super::{Command, Layers, Message, Response, ResponseEffect};
use crate::{
    application::{Application, Event, ViewId},
    core::{Selection, Snapshot},
    editor::{Command as Edit, DocumentId},
};
use std::{path::Path, time::Duration};

pub const SCRATCH: &str = "*grep*";
pub use crate::application::RUN;

/// Commands that produce or visit a results document.
#[derive(Clone, Debug)]
pub enum ResultsCommand {
    /// Searches the project; results go to the `*grep*` document.
    Grep(String),
    Ripgrep(Box<RipgrepRequest>),
    /// Opens the location on the caret line, or moves to the next line's
    /// first non-blank.
    Jump,
    /// Opens the next or previous location in the latest results: search
    /// matches or `run` output.
    ResultStep {
        backward: bool,
    },
    /// Fills the latest results document with lines supplied by a command.
    Fill {
        kind: String,
        lines: Vec<String>,
    },
    /// Runs a command whose output streams into the `*run*` document.
    Run(String),
}

#[derive(Default)]
pub(super) struct ResultNavigation {
    /// The results document `]q` and `[q` step through: the latest filled.
    results: String,
    /// `]q` has not stepped through these results yet.
    results_fresh: bool,
}

impl Layers {
    pub(super) fn execute_results(
        &mut self,
        command: ResultsCommand,
        app: &Application,
        time: Duration,
        file_root: &Path,
        response: &mut Response,
    ) {
        match command {
            ResultsCommand::Ripgrep(request) => {
                self.set_results("*rg*".into());
                response
                    .effects
                    .push(ResponseEffect::Search(Box::new(SearchRequest::Ripgrep(
                        *request,
                    ))));
            }
            ResultsCommand::Grep(pattern) => {
                self.set_results(SCRATCH.to_owned());
                response
                    .effects
                    .push(ResponseEffect::Search(Box::new(SearchRequest::Grep(
                        GrepRequest {
                            pattern,
                            root: file_root.to_owned(),
                        },
                    ))));
            }
            ResultsCommand::Jump => {
                // Enter on the results visits that line, as `]q` would.
                let document = app.active_view().and_then(|view| app.view(view));
                if document.map(|view| view.document_id)
                    == app.workspace().scratch(&self.result_navigation.results)
                {
                    self.result_navigation.results_fresh = false;
                }
                self.jumps.expect_result();
                if !jump(app, time, response) {
                    self.jumps.clear_pending();
                    self.jumps.end_walk();
                    response.commands.extend([
                        Command::Modal(super::modal::Action::Move {
                            step: super::modal::Step::Down,
                            extend: false,
                        }),
                        Command::Named("line-start".into()),
                    ]);
                }
            }
            ResultsCommand::ResultStep { backward } => {
                let fresh = std::mem::take(&mut self.result_navigation.results_fresh);
                step(
                    app,
                    &self.result_navigation.results,
                    fresh,
                    backward,
                    time,
                    response,
                )
            }
            ResultsCommand::Fill { kind, lines } => {
                if lines
                    .iter()
                    .any(|line| location(line).is_some() || row(line).is_some())
                {
                    let name = format!("*{kind}*");
                    self.set_results(name.clone());
                    response.events.push(Event::ResultsDisplay { kind });
                    response.events.push(Event::Scratch {
                        name,
                        directory: file_root.to_owned(),
                        text: lines.join("\n") + "\n",
                    });
                } else {
                    response.message = Message::Set(format!("{kind}: no results"));
                }
            }
            ResultsCommand::Run(shell) => {
                self.set_results(RUN.to_owned());
                let view = app.active_view().and_then(|view| app.view(view));
                response
                    .effects
                    .push(ResponseEffect::Run(Box::new(super::shell::run(
                        app, view, shell, file_root,
                    ))));
            }
        }
    }

    /// Makes a results document the one `]q` and `[q` step through.
    fn set_results(&mut self, name: String) {
        self.result_navigation.results = name;
        self.result_navigation.results_fresh = true;
        self.jumps.end_walk();
    }
}

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

pub use crate::application::results_kind;
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
