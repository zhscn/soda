//! Explicit path completion. This component owns filesystem-specific interaction;
//! text editing and candidate geometry remain ordinary reusable primitives.
use super::picker::{Candidate, CandidateKey, CandidateListState, ListMotion, MatchedCandidate};
use super::{Input, Presentation, Response, TextInput, session::field_presentation};
use crate::files::paths::DirectoryEntry;
pub use crate::files::paths::{PathCompletion, PathRequest};
use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

pub struct PathEntry {
    pub path: PathBuf,
    pub directory: bool,
    // Only names representable in a single-line UTF-8 path can be inserted.
    insertion: Option<String>,
}
pub(super) enum PathAction {
    Active(Response),
    Submit(PathBuf),
    Cancel,
    Blocked,
}
/// A path field with an explicitly requested, cancellable directory listing.
/// The absolute base is captured when the workflow starts. Candidate navigation
/// never changes the field; Tab fills it and Enter uses the field itself.
pub struct PathInput {
    field: TextInput,
    base: PathBuf,
    rows: Vec<MatchedCandidate<PathEntry>>,
    list: CandidateListState,
    pending: Option<Arc<AtomicBool>>,
    visible: bool,
    error: Option<String>,
    home: Option<PathBuf>,
}
impl PathInput {
    pub fn new(base: PathBuf, text: &str) -> Self {
        assert!(base.is_absolute(), "path input requires an absolute base");
        Self {
            field: TextInput::new(text),
            base,
            rows: vec![],
            list: CandidateListState::default(),
            pending: None,
            visible: false,
            error: None,
            home: std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|p| p.is_absolute()),
        }
    }
    pub fn selection(&self) -> crate::core::Selection {
        self.field.selection()
    }
    pub fn text(&self) -> &str {
        self.field.text()
    }
    pub fn rows(&self) -> &[MatchedCandidate<PathEntry>] {
        &self.rows
    }
    pub fn list(&self) -> &CandidateListState {
        &self.list
    }
    pub fn visible(&self) -> bool {
        self.visible
    }
    pub(super) fn resize(&mut self, rows: usize) {
        self.list.resize(&self.rows, rows);
    }
    fn invalidate(&mut self) {
        if let Some(token) = self.pending.take() {
            token.store(true, Ordering::Relaxed);
        }
        self.rows.clear();
        self.list.reset();
        self.visible = false;
    }
    pub fn accept(&mut self, completion: PathCompletion) -> bool {
        if !self
            .pending
            .as_ref()
            .is_some_and(|token| Arc::ptr_eq(token, &completion.cancelled))
            || completion.cancelled.load(Ordering::Relaxed)
        {
            return false;
        }

        self.pending.take();
        match completion.result {
            Ok(entries) => {
                let rows = candidate_rows(entries);
                self.list.update(&self.rows, &rows);
                self.rows = rows;
                self.error = None;
            }
            Err(error) => {
                self.error = Some(error);
            }
        }
        true
    }
    fn resolve(&self, text: &str) -> Result<PathBuf, String> {
        if text == "~" || text.starts_with("~/") {
            return self
                .home
                .as_ref()
                .map(|home| home.join(text.strip_prefix("~/").unwrap_or("")))
                .ok_or_else(|| "Home directory is unavailable".into());
        }
        Ok(self.base.join(text))
    }
    fn request(&mut self) -> Response {
        self.invalidate();
        self.error = None;
        // Complete only at the end: interior editing retains ordinary text semantics.
        if self.field.cursor() != self.field.text().len()
            || !self.field.selection().range().is_empty()
        {
            self.error = Some("Move to the end of the path to complete".into());
            return Response {
                redraw: true,
                ..Response::default()
            };
        }
        let text = self.field.text();
        let (parent, prefix) = text
            .rfind('/')
            .map_or(if text == "~" { ("~/", "") } else { ("", text) }, |i| {
                (&text[..=i], &text[i + 1..])
            });
        let request = PathRequest {
            directory: match self.resolve(parent) {
                Ok(path) => path,
                Err(error) => {
                    self.error = Some(error);
                    return Response {
                        redraw: true,
                        ..Response::default()
                    };
                }
            },
            prefix: prefix.to_owned(),
            cancelled: Arc::new(AtomicBool::new(false)),
        };
        self.pending = Some(request.cancelled.clone());
        self.visible = true;

        Response {
            path_requests: vec![request],
            redraw: true,
            ..Response::default()
        }
    }
    pub(super) fn handle(&mut self, input: Input) -> PathAction {
        match input {
            Input::Cancel if self.visible => {
                self.invalidate();
                self.error = None;
                PathAction::Active(Response {
                    redraw: true,
                    ..Response::default()
                })
            }
            Input::Cancel => PathAction::Cancel,
            Input::Complete { backward } => {
                if backward && self.visible {
                    self.list.navigate(&self.rows, ListMotion::Previous, true);
                    return PathAction::Active(Response {
                        redraw: true,
                        ..Response::default()
                    });
                }
                if !self.visible {
                    return PathAction::Active(self.request());
                }
                if self.pending.is_some() {
                    return PathAction::Blocked;
                }
                let Some(index) = self.list.index(&self.rows) else {
                    return PathAction::Active(self.request());
                };
                let entry = &self.rows[index].candidate.payload;
                let directory = entry.directory;
                let Some(text) = entry.insertion.clone() else {
                    self.error = Some("This name cannot be inserted into a text path".into());
                    return PathAction::Active(Response {
                        redraw: true,
                        ..Response::default()
                    });
                };
                self.field.key(super::InputKey::SelectAll);
                self.field.insert(&text);
                self.invalidate();
                if directory {
                    PathAction::Active(self.request())
                } else {
                    self.error = None;
                    PathAction::Active(Response {
                        redraw: true,
                        ..Response::default()
                    })
                }
            }
            Input::Candidate { motion, wrap } if self.visible => {
                if self.list.navigate(&self.rows, motion, wrap) {
                    PathAction::Active(Response {
                        redraw: true,
                        ..Response::default()
                    })
                } else {
                    PathAction::Blocked
                }
            }
            Input::Confirm if self.field.text().is_empty() => PathAction::Cancel,
            Input::Confirm if self.field.text().ends_with('/') || self.field.text() == "~" => {
                PathAction::Active(self.request())
            }
            Input::Confirm => match self.resolve(self.field.text()) {
                Ok(path) => {
                    self.invalidate();
                    PathAction::Submit(path)
                }
                Err(error) => {
                    self.error = Some(error);
                    PathAction::Active(Response {
                        redraw: true,
                        ..Response::default()
                    })
                }
            },
            input => match super::session::edit_field(&mut self.field, input) {
                Some(update) if update.text_changed || update.selection_changed => {
                    if self.visible
                        && update.text_changed
                        && self.field.cursor() == self.field.text().len()
                        && self.field.selection().range().is_empty()
                    {
                        return PathAction::Active(self.request());
                    }
                    self.invalidate();
                    self.error = None;
                    PathAction::Active(Response {
                        redraw: true,
                        ..Response::default()
                    })
                }
                _ => PathAction::Blocked,
            },
        }
    }
    pub(super) fn presentation(&self, label: &str) -> Presentation {
        let status = if self.pending.is_some() {
            " [loading]".to_owned()
        } else if let Some(error) = &self.error {
            format!(" [{error}]")
        } else if self.visible {
            if self.rows.is_empty() {
                " [no matches; Enter uses input]".into()
            } else {
                " [Tab fills; Enter uses input; Esc hides]".into()
            }
        } else {
            " [Tab completes]".into()
        };
        let mut presentation = field_presentation(format!("{label}: "), &self.field);
        presentation.text.push_str(&status);
        presentation
    }
}
impl Drop for PathInput {
    fn drop(&mut self) {
        self.invalidate();
    }
}

fn candidate_rows(entries: Vec<DirectoryEntry>) -> Vec<MatchedCandidate<PathEntry>> {
    entries
        .into_iter()
        .enumerate()
        .map(|(i, entry)| {
            let insertion = entry
                .path
                .to_str()
                .filter(|s| !s.chars().any(char::is_control))
                .map(|s| {
                    format!(
                        "{s}{}",
                        if entry.directory && !s.ends_with('/') {
                            "/"
                        } else {
                            ""
                        }
                    )
                });
            let label: String = entry
                .name
                .to_string_lossy()
                .chars()
                .map(|c| if c.is_control() { '�' } else { c })
                .collect();
            MatchedCandidate {
                candidate: Arc::new(Candidate {
                    key: CandidateKey(i as u64),
                    label: format!("{label}{}", if entry.directory { "/" } else { "" }),
                    payload: PathEntry {
                        path: entry.path,
                        directory: entry.directory,
                        insertion,
                    },
                }),
                score: 0,
                highlights: vec![],
            }
        })
        .collect()
}

#[cfg(test)]
mod tests;
