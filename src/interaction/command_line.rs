//! The command line: one input row and the candidates of the argument under
//! the cursor. The command name, slots and current slot are parsed from the
//! text on every change; focus never leaves the input.
use super::{
    Command, Input, InputKey, Presentation, Response, TextInput,
    path::resolve_path,
    picker::{
        Candidate, CandidateKey, CandidateListState, ListMotion, MatchedCandidate,
        PickerCompletion, PickerEffect, PickerLimits, PickerSession, PickerStatus,
    },
    registry::{self, CommandInfo, SlotKind},
    session::{Transition, edit_field, field_presentation},
};
use crate::{
    application::{Application, ViewId},
    files::paths::{DirectoryEntry, PathCompletion, PathRequest},
};
use std::{
    ops::Range,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

/// Text a candidate puts into its slot; None for names that cannot be
/// written into a single-line UTF-8 field.
pub struct Completion {
    pub replacement: Option<String>,
    pub directory: bool,
}

/// What the cursor is completing: the command name or one of its slots.
#[derive(Clone, Copy, PartialEq)]
enum Target {
    Name,
    Slot(SlotKind),
}
struct Location {
    target: Option<Target>,
    range: Range<usize>,
    /// Whether a slot follows the current one.
    more: bool,
}
#[derive(PartialEq)]
struct Query {
    target: Target,
    start: usize,
    text: String,
}
struct Directory {
    path: PathBuf,
    entries: Option<Vec<DirectoryEntry>>,
    pending: Option<Arc<AtomicBool>>,
}
impl Drop for Directory {
    fn drop(&mut self) {
        if let Some(token) = &self.pending {
            token.store(true, Ordering::Relaxed);
        }
    }
}

pub struct CommandLine {
    input: TextInput,
    catalog: Vec<CommandInfo>,
    root: PathBuf,
    home: Option<PathBuf>,
    view: Option<ViewId>,
    rows: Vec<MatchedCandidate<Completion>>,
    list: CandidateListState,
    query: Option<Query>,
    directory: Option<Directory>,
    files: Option<PickerSession>,
    /// What the line asks about, such as the document a departure concerns.
    note: Option<String>,
    error: Option<String>,
}
fn row(
    key: u64,
    label: String,
    replacement: Option<String>,
    directory: bool,
) -> MatchedCandidate<Completion> {
    MatchedCandidate {
        candidate: Arc::new(Candidate {
            key: CandidateKey(key),
            label,
            payload: Completion {
                replacement,
                directory,
            },
        }),
        score: 0,
        highlights: vec![],
    }
}
fn word_end(text: &str, from: usize) -> usize {
    text[from..]
        .find(char::is_whitespace)
        .map_or(text.len(), |i| from + i)
}
fn skip_space(text: &str, from: usize) -> usize {
    text[from..]
        .find(|c: char| !c.is_whitespace())
        .map_or(text.len(), |i| from + i)
}
/// Splits a path slot into the directory part, kept verbatim in
/// replacements, and the file name prefix being completed.
fn split_path(text: &str) -> (&str, &str) {
    if text == "~" {
        return ("~/", "");
    }
    text.rfind('/')
        .map_or(("", text), |i| (&text[..=i], &text[i + 1..]))
}
/// Buffer names: full paths, or `[untitled N]` by document number.
pub(super) fn buffer_name(app: &Application, document: crate::editor::DocumentId) -> String {
    app.workspace().file(document).unwrap().path().map_or_else(
        || format!("[untitled {}]", document.number()),
        |path| path.to_string_lossy().into_owned(),
    )
}
fn printable(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { '�' } else { c })
        .collect()
}

impl CommandLine {
    pub fn new(text: &str, catalog: Vec<CommandInfo>, root: PathBuf, app: &Application) -> Self {
        Self {
            input: TextInput::new(text),
            catalog,
            root,
            home: std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|p| p.is_absolute()),
            view: app.active_view(),
            rows: vec![],
            list: CandidateListState::default(),
            query: None,
            directory: None,
            files: None,
            note: None,
            error: None,
        }
    }
    /// Shows a note before the input until the line closes.
    pub fn with_note(mut self, note: String) -> Self {
        self.note = Some(note);
        self
    }
    pub fn input(&self) -> &TextInput {
        &self.input
    }
    pub fn rows(&self) -> &[MatchedCandidate<Completion>] {
        &self.rows
    }
    pub fn list(&self) -> &CandidateListState {
        &self.list
    }
    /// The project file search backing a `File` slot, once one was entered.
    pub fn files(&self) -> Option<&PickerSession> {
        self.files.as_ref()
    }
    pub fn picker(&self) -> Option<super::picker::PickerId> {
        self.files.as_ref().map(PickerSession::id)
    }
    pub(super) fn resize(&mut self, rows: usize) {
        self.list.resize(&self.rows, rows);
    }
    fn info(&self, name: &str) -> Option<&CommandInfo> {
        self.catalog.iter().find(|info| info.named(name))
    }
    /// Parses the text around the cursor. Slots past the declared ones and
    /// arguments of unknown commands have no target.
    fn locate(&self) -> Location {
        let text = self.input.text();
        let cursor = self.input.cursor();
        let start = skip_space(text, 0);
        let end = word_end(text, start);
        if cursor <= end {
            let more = self
                .info(&text[start..end])
                .is_some_and(|i| !i.slots.is_empty());
            return Location {
                target: Some(Target::Name),
                range: start..end,
                more,
            };
        }
        let none = Location {
            target: None,
            range: cursor..cursor,
            more: false,
        };
        let Some(info) = self.info(&text[start..end]) else {
            return none;
        };
        let mut position = end;
        for (index, slot) in info.slots.iter().enumerate() {
            let last = index + 1 == info.slots.len();
            let begin = skip_space(text, position);
            let finish = if last {
                text.len()
            } else {
                word_end(text, begin)
            };
            if cursor < begin || cursor <= finish {
                let range = if cursor < begin {
                    cursor..cursor
                } else {
                    begin..finish
                };
                return Location {
                    target: Some(Target::Slot(slot.kind)),
                    range,
                    more: !last,
                };
            }
            position = finish;
        }
        none
    }
    /// Recomputes candidates when the completed slot or its text changed.
    pub(super) fn refresh(&mut self, app: &Application, force: bool) -> Response {
        let location = self.locate();
        let query = location.target.map(|target| Query {
            target,
            start: location.range.start,
            text: self.input.text()[location.range.clone()].to_owned(),
        });
        if !force && query == self.query {
            return Response::default();
        }
        let restart = query != self.query;
        let mut response = Response::default();
        let rows = match &query {
            None => vec![],
            Some(query) => match query.target {
                Target::Name => self.names(&query.text),
                Target::Slot(SlotKind::Choice(choices)) => choices
                    .iter()
                    .enumerate()
                    .filter(|(_, choice)| choice.word.starts_with(&query.text))
                    .map(|(i, choice)| {
                        let key = choice.key.map_or_else(String::new, |k| format!("[{k}] "));
                        let label = format!("{:<12} {key}{}", choice.word, choice.doc);
                        row(i as u64, label, Some(choice.word.into()), false)
                    })
                    .collect(),
                Target::Slot(SlotKind::Buffer) => buffers(app, &query.text),
                Target::Slot(SlotKind::Path) => self.paths(&query.text, &mut response),
                Target::Slot(SlotKind::File) => self.project_files(&query.text, &mut response),
                Target::Slot(SlotKind::Word | SlotKind::Rest) => vec![],
            },
        };
        let changed = self.rows.len() != rows.len()
            || self.rows.iter().zip(&rows).any(|(old, new)| {
                old.candidate.key != new.candidate.key || old.candidate.label != new.candidate.label
            });
        if restart {
            self.list.reset();
            self.list.update(&[], &rows);
        } else {
            self.list.update(&self.rows, &rows);
        }
        response.redraw = restart || changed;
        self.rows = rows;
        self.query = query;
        response
    }
    fn names(&self, query: &str) -> Vec<MatchedCandidate<Completion>> {
        let query = query.to_lowercase();
        let mut rows: Vec<_> = self
            .catalog
            .iter()
            .enumerate()
            .filter(|(_, info)| {
                info.name.contains(&query) || info.doc.to_lowercase().contains(&query)
            })
            .collect();
        // Names starting with the query come first, in catalog order.
        rows.sort_by_key(|(_, info)| !info.name.starts_with(&query));
        rows.into_iter()
            .map(|(index, info)| {
                let name = format!("{} {}", info.name, info.synopsis());
                row(
                    index as u64,
                    format!("{:<32} {}", name.trim_end(), info.doc),
                    Some(info.name.clone()),
                    false,
                )
            })
            .collect()
    }
    fn paths(&mut self, text: &str, response: &mut Response) -> Vec<MatchedCandidate<Completion>> {
        let (parent, prefix) = split_path(text);
        let path = match resolve_path(
            &self.root,
            self.home.as_deref(),
            std::path::Path::new(parent),
        ) {
            Ok(path) => path,
            Err(error) => {
                self.error = Some(error);
                return vec![];
            }
        };
        if self.directory.as_ref().is_none_or(|d| d.path != path) {
            let cancelled = Arc::new(AtomicBool::new(false));
            response.path_requests.push(PathRequest {
                directory: path.clone(),
                prefix: String::new(),
                cancelled: cancelled.clone(),
            });
            self.directory = Some(Directory {
                path,
                entries: None,
                pending: Some(cancelled),
            });
            return vec![];
        }
        let Some(entries) = self.directory.as_ref().and_then(|d| d.entries.as_ref()) else {
            return vec![];
        };
        entries
            .iter()
            .enumerate()
            .filter(|(_, entry)| {
                let name = entry.name.to_string_lossy();
                if name == ".." {
                    prefix.is_empty()
                } else {
                    name.starts_with(prefix)
                }
            })
            .map(|(index, entry)| {
                let slash = if entry.directory { "/" } else { "" };
                let replacement = entry
                    .name
                    .to_str()
                    .filter(|name| !name.chars().any(char::is_control))
                    .map(|name| format!("{parent}{name}{slash}"));
                let label = format!("{}{slash}", printable(&entry.name.to_string_lossy()));
                row(index as u64, label, replacement, entry.directory)
            })
            .collect()
    }
    fn project_files(
        &mut self,
        text: &str,
        response: &mut Response,
    ) -> Vec<MatchedCandidate<Completion>> {
        if self.files.is_none() {
            match PickerSession::new(self.root.clone(), PickerLimits::default()) {
                Ok(mut session) => {
                    session.set_query(text);
                    response.effects.push(PickerEffect::Run(session.task()));
                    self.files = Some(session);
                }
                Err(error) => self.error = Some(error.to_string()),
            }
            return vec![];
        }
        let session = self.files.as_mut().unwrap();
        if let Some(task) = session.set_query(text) {
            response.effects.push(PickerEffect::Run(task));
        }
        self.file_rows()
    }
    fn file_rows(&self) -> Vec<MatchedCandidate<Completion>> {
        let Some(session) = &self.files else {
            return vec![];
        };
        session
            .results()
            .rows
            .iter()
            .map(|matched| {
                let path = &matched.candidate.payload;
                let relative = path.strip_prefix(&self.root).unwrap_or(path);
                MatchedCandidate {
                    candidate: Arc::new(Candidate {
                        key: matched.candidate.key,
                        label: matched.candidate.label.clone(),
                        payload: Completion {
                            replacement: relative
                                .to_str()
                                .filter(|p| !p.chars().any(char::is_control))
                                .map(str::to_owned),
                            directory: false,
                        },
                    }),
                    score: matched.score,
                    highlights: matched.highlights.clone(),
                }
            })
            .collect()
    }
    pub(super) fn path_finished(
        &mut self,
        completion: PathCompletion,
        app: &Application,
    ) -> Option<Response> {
        let directory = self.directory.as_mut()?;
        if !directory
            .pending
            .as_ref()
            .is_some_and(|token| Arc::ptr_eq(token, &completion.cancelled))
        {
            return None;
        }
        directory.pending = None;
        match completion.result {
            Ok(entries) => directory.entries = Some(entries),
            Err(error) => {
                directory.entries = Some(vec![]);
                self.error = Some(error);
            }
        }
        Some(self.refresh(app, true))
    }
    pub(super) fn picker_finished(&mut self, completion: PickerCompletion) -> bool {
        let Some(session) = &mut self.files else {
            return false;
        };
        if !session.accept(completion) {
            return false;
        }
        if let PickerStatus::Failed(error) = session.status() {
            self.error = Some(error.clone());
        }
        if self
            .query
            .as_ref()
            .is_some_and(|q| q.target == Target::Slot(SlotKind::File))
        {
            let rows = self.file_rows();
            self.list.update(&self.rows, &rows);
            self.rows = rows;
        }
        true
    }
    pub(super) fn picker_failed(&mut self, error: String) {
        self.error = Some(error);
    }
    fn loading(&self) -> bool {
        let target = self.query.as_ref().map(|q| q.target);
        (target == Some(Target::Slot(SlotKind::Path))
            && self.directory.as_ref().is_some_and(|d| d.pending.is_some()))
            || (target == Some(Target::Slot(SlotKind::File))
                && self
                    .files
                    .as_ref()
                    .is_some_and(|s| matches!(s.status(), PickerStatus::Loading)))
    }
    fn close(&self, commands: Vec<Command>) -> Transition {
        Transition::finished(Response {
            commands,
            effects: self
                .files
                .as_ref()
                .map(|s| PickerEffect::Cancel(s.id()))
                .into_iter()
                .collect(),
            redraw: true,
            ..Response::default()
        })
    }
    /// Puts the selected candidate into the slot under the cursor. Returns
    /// whether a directory was entered.
    fn fill(&mut self, location: &Location) -> Result<bool, String> {
        let index = self
            .list
            .index(&self.rows)
            .ok_or_else(|| "no candidate".to_owned())?;
        let completion = &self.rows[index].candidate.payload;
        let directory = completion.directory;
        let mut text = completion
            .replacement
            .clone()
            .ok_or_else(|| "this name cannot be written into the command line".to_owned())?;
        let after = &self.input.text()[location.range.end..];
        if !directory && location.more && !after.starts_with(char::is_whitespace) {
            text.push(' ');
        }
        self.input.replace_range(location.range.clone(), &text);
        Ok(directory)
    }
    fn edited(&mut self, app: &Application) -> Transition {
        self.error = None;
        let mut response = self.refresh(app, false);
        response.redraw = true;
        Transition::active(response)
    }
    fn confirm(&mut self, app: &Application) -> Transition {
        let location = self.locate();
        let slot_text = &self.input.text()[location.range.clone()];
        let accept = match location.target {
            Some(Target::Name) => self.info(slot_text).is_none(),
            Some(Target::Slot(SlotKind::Path)) => self.list.user_selected(),
            Some(Target::Slot(kind)) if kind.requires_match() => !self
                .rows
                .iter()
                .any(|r| r.candidate.payload.replacement.as_deref() == Some(slot_text)),
            _ => false,
        };
        let mut accepted = false;
        if accept
            && self.rows.is_empty()
            && matches!(location.target, Some(Target::Slot(kind)) if kind.requires_match())
        {
            self.error = Some("no matching candidate".into());
            return Transition::redraw();
        }
        if accept && !self.rows.is_empty() {
            match self.fill(&location) {
                Ok(true) => return self.edited(app),
                Ok(false) => accepted = true,
                Err(error) => {
                    self.error = Some(error);
                    return Transition::redraw();
                }
            }
        }
        let text = self.input.text().trim().to_owned();
        if text.is_empty() {
            return self.close(vec![]);
        }
        if !accepted
            && location.target == Some(Target::Slot(SlotKind::Path))
            && self.input.text()[location.range.clone()].ends_with('/')
        {
            // A directory: keep browsing instead of opening it.
            return Transition::Blocked;
        }
        match registry::check(&self.catalog, &text) {
            Ok(()) => self.close(vec![Command::Named(text)]),
            Err(registry::CheckError::Missing(_))
                if accepted || location.more || location.target == Some(Target::Name) =>
            {
                // Continue with the next argument, as after choosing in M-x.
                if !self.input.text().ends_with(' ') {
                    let end = self.input.text().len();
                    self.input.replace_range(end..end, " ");
                }
                self.edited(app)
            }
            Err(error) => {
                self.error = Some(error.to_string());
                Transition::redraw()
            }
        }
    }
    /// Backspace after a `/` in a path slot removes the last directory.
    fn delete_directory(&mut self, location: &Location) -> bool {
        let text = &self.input.text()[location.range.clone()];
        if location.target != Some(Target::Slot(SlotKind::Path))
            || self.input.cursor() != location.range.end
            || !self.input.selection().range().is_empty()
            || !text.ends_with('/')
            || text.len() == 1
        {
            return false;
        }
        let keep = text[..text.len() - 1].rfind('/').map_or(0, |i| i + 1);
        let start = location.range.start + keep;
        self.input.replace_range(start..location.range.end, "");
        true
    }
    /// The slot keymap: a key of an empty `Choice` slot chooses its word.
    fn choice_key(&mut self, key: char) -> bool {
        let location = self.locate();
        let Some(Target::Slot(SlotKind::Choice(choices))) = location.target else {
            return false;
        };
        let Some(choice) = choices.iter().find(|c| c.key == Some(key)) else {
            return false;
        };
        if !location.range.is_empty() || !self.input.selection().range().is_empty() {
            return false;
        }
        self.input.replace_range(location.range, choice.word);
        true
    }
    pub(super) fn handle(&mut self, input: Input, app: &Application) -> Transition {
        match input {
            Input::Text(InputKey::Char(key)) if self.choice_key(key) => {
                self.refresh(app, false);
                self.confirm(app)
            }
            Input::Cancel => self.close(vec![]),
            Input::Confirm => self.confirm(app),
            Input::Complete { backward: true } => {
                self.list.navigate(&self.rows, ListMotion::Previous, true);
                Transition::redraw()
            }
            Input::Complete { backward: false } => {
                let location = self.locate();
                match self.fill(&location) {
                    Ok(_) => self.edited(app),
                    Err(error) => {
                        self.error = Some(error);
                        Transition::redraw()
                    }
                }
            }
            Input::Candidate { motion, wrap } => {
                if self.list.navigate(&self.rows, motion, wrap) {
                    Transition::redraw()
                } else {
                    Transition::Blocked
                }
            }
            Input::Text(InputKey::Delete {
                backward: true,
                word: false,
            }) if self.delete_directory(&self.locate()) => self.edited(app),
            input => match edit_field(&mut self.input, input) {
                Some(update) if update.text_changed || update.selection_changed => self.edited(app),
                _ => Transition::Blocked,
            },
        }
    }
    pub(super) fn observe(&mut self, app: &Application) -> Transition {
        if app.active_view() != self.view {
            return self.close(vec![]);
        }
        let buffers = self
            .query
            .as_ref()
            .is_some_and(|q| q.target == Target::Slot(SlotKind::Buffer));
        Transition::active(if buffers {
            self.refresh(app, true)
        } else {
            Response::default()
        })
    }
    pub(super) fn presentation(&self) -> Presentation {
        let label = self
            .note
            .as_ref()
            .map_or_else(|| ":".to_owned(), |note| format!("[{note}] :"));
        let mut presentation = field_presentation(label, &self.input);
        if let Some(error) = &self.error {
            presentation.text.push_str(&format!(" [{error}]"));
        } else if self.loading() {
            presentation.text.push_str(" [loading]");
        }
        presentation
    }
}

fn buffers(app: &Application, query: &str) -> Vec<MatchedCandidate<Completion>> {
    let active = app
        .active_view()
        .and_then(|view| app.view(view))
        .map(|v| v.document_id);
    let query = query.to_lowercase();
    let mut rows: Vec<_> = app
        .workspace()
        .documents()
        .map(|id| (id, buffer_name(app, id)))
        .filter(|(_, name)| name.to_lowercase().contains(&query))
        .collect();
    // Offer another buffer first while preserving document order within groups.
    rows.sort_by_key(|(id, _)| active == Some(*id));
    rows.into_iter()
        .map(|(id, name)| {
            let label = format!(
                "{}{}{}",
                if active == Some(id) { "* " } else { "  " },
                printable(&name),
                if app.workspace().is_dirty(id) {
                    " [+]"
                } else {
                    ""
                }
            );
            let replacement = (!name.chars().any(char::is_control)).then_some(name);
            row(id.number(), label, replacement, false)
        })
        .collect()
}
