//! The command line: one input row and the candidates of the argument under
//! the cursor. The command name, slots and current slot are parsed from the
//! text on every change; focus never leaves the input.
use super::{
    Command, Input, InputKey, Presentation, Response, TextInput,
    path::resolve_path,
    picker::{
        Candidate, CandidateKey, CandidateListState, ListMotion, MatchedCandidate,
        PickerCompletion, PickerEffect, PickerLimits, PickerSession, PickerStatus, fuzzy_match,
    },
    registry::{self, CommandInfo, SlotKind},
    session::{Transition, edit_field, field_presentation},
};
use crate::{
    application::{Application, ViewId},
    files::paths::{DirectoryEntry, PathCompletion, PathRequest},
};
use nucleo_matcher::{Config, Matcher};
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
    /// Byte offset in the label where secondary text, such as a command's
    /// description, begins.
    pub detail: Option<usize>,
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
    /// What a typed path is relative to.
    base: PathBuf,
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
    matcher: Matcher,
    /// Recently used files, newest first.
    recent: Vec<PathBuf>,
    /// The items of an `Item` slot.
    items: Vec<String>,
    /// The rows are those of the last input, kept in view while the worker
    /// answers this one, so the list does not blink at each key. They can
    /// be looked at and not chosen.
    stale: bool,
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
                detail: None,
            },
        }),
        score: 0,
        highlights: vec![],
    }
}
/// A single matched range.
fn one(range: Range<usize>) -> Vec<Range<usize>> {
    std::iter::once(range).collect()
}
/// Marks matched label ranges and where the label's secondary text begins.
fn mark(
    mut row: MatchedCandidate<Completion>,
    highlights: Vec<Range<usize>>,
    detail: Option<usize>,
) -> MatchedCandidate<Completion> {
    row.highlights = highlights;
    if detail.is_some() {
        Arc::get_mut(&mut row.candidate).unwrap().payload.detail = detail;
    }
    row
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
/// How a file name answers typed text, after orderless: each word separated
/// by spaces appears somewhere, in any order, and case counts only if the
/// text has capitals. Gives whether the name begins with the text, and the
/// ranges that matched.
fn name_match(name: &str, text: &str) -> Option<(bool, Vec<Range<usize>>)> {
    let exact = text.chars().any(char::is_uppercase);
    let fold = |text: &str| {
        if exact {
            text.to_owned()
        } else {
            text.to_ascii_lowercase()
        }
    };
    let (folded, wanted) = (fold(name), fold(text));
    let mut ranges = vec![];
    for word in wanted.split_whitespace() {
        let at = folded.find(word)?;
        ranges.push(at..at + word.len());
    }
    let leading = folded.starts_with(wanted.trim_start());
    Some((leading, ranges))
}
fn printable(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { '�' } else { c })
        .collect()
}

impl CommandLine {
    pub fn new(
        text: &str,
        catalog: Vec<CommandInfo>,
        root: PathBuf,
        base: PathBuf,
        app: &Application,
    ) -> Self {
        Self {
            input: TextInput::new(text),
            catalog,
            root,
            base,
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
            matcher: Matcher::new(Config::DEFAULT),
            recent: vec![],
            items: vec![],
            stale: false,
        }
    }
    /// Recently used files for a `recent` slot, newest first.
    pub fn with_recent(mut self, recent: Vec<PathBuf>) -> Self {
        self.recent = recent;
        self
    }
    /// Items for an `Item` slot.
    pub fn with_items(mut self, items: Vec<String>) -> Self {
        self.items = items;
        self
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
    pub fn note(&self) -> Option<&str> {
        self.note.as_deref()
    }
    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    /// The typed command with its synopsis, such as `open PATH`.
    pub fn heading(&self) -> Option<String> {
        let text = self.input.text().trim_start();
        let name = &text[..word_end(text, 0)];
        let info = self.info(name)?;
        Some(
            format!("{} {}", info.name, info.synopsis())
                .trim_end()
                .to_owned(),
        )
    }
    /// The input with its `:` prompt, for drawing outside `presentation`.
    pub fn field(&self) -> Presentation {
        field_presentation(":".into(), &self.input)
    }
    pub(super) fn resize(&mut self, rows: usize) {
        self.list.resize(&self.rows, rows);
    }
    fn info(&self, name: &str) -> Option<&CommandInfo> {
        self.catalog.iter().find(|info| info.name == name)
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
                        let detail = label.len() - key.len() - choice.doc.len();
                        let typed = (!query.text.is_empty()).then_some(0..query.text.len());
                        let row = row(i as u64, label, Some(choice.word.into()), false);
                        mark(row, typed.into_iter().collect(), Some(detail))
                    })
                    .collect(),
                Target::Slot(SlotKind::Option) => crate::options::OPTIONS
                    .iter()
                    .enumerate()
                    .filter(|(_, option)| option.name.starts_with(&query.text))
                    .map(|(i, option)| {
                        let label = format!("{:<14} {}", option.name, option.doc);
                        let typed = (!query.text.is_empty()).then_some(0..query.text.len());
                        let row = row(i as u64, label, Some(option.name.into()), false);
                        mark(row, typed.into_iter().collect(), Some(15))
                    })
                    .collect(),
                Target::Slot(SlotKind::Buffer) => buffers(app, &query.text, &mut self.matcher),
                Target::Slot(SlotKind::Recent) => {
                    recent(&self.recent, &self.root, &query.text, &mut self.matcher)
                }
                Target::Slot(SlotKind::Item) => self.item_rows(&query.text),
                Target::Slot(SlotKind::Path) => self.paths(&query.text, &mut response),
                Target::Slot(SlotKind::File) => self.project_files(&query.text, &mut response),
                Target::Slot(SlotKind::Word | SlotKind::Rest) => vec![],
            },
        };
        let same_list = self.query.as_ref().map(|q| q.target) == query.as_ref().map(|q| q.target);
        if rows.is_empty() && !self.rows.is_empty() && same_list && self.waiting(&query) {
            // New input forgets the choice, as it does with fresh rows.
            if restart {
                self.list.reset();
                self.list.update(&[], &self.rows);
            }
            self.stale = true;
            self.query = query;
            response.redraw = true;
            return response;
        }
        self.stale = false;
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
    /// Items match fuzzily and answer with their number, so a title may
    /// hold any text.
    fn item_rows(&mut self, query: &str) -> Vec<MatchedCandidate<Completion>> {
        self.matcher.config = Config::DEFAULT;
        let mut ranked: Vec<_> = self
            .items
            .iter()
            .enumerate()
            .filter_map(|(index, item)| {
                let shown = printable(item);
                let (score, highlights) = matched(&mut self.matcher, query, &shown)?;
                let number = (index + 1).to_string();
                let row = row(index as u64, shown, Some(number), false);
                Some((score, mark(row, highlights, None)))
            })
            .collect();
        ranked.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
        ranked.into_iter().map(|(_, row)| row).collect()
    }
    /// Command names match fuzzily; an exact name or alias comes first.
    /// Descriptions match as substrings, after every name match.
    fn names(&mut self, query: &str) -> Vec<MatchedCandidate<Completion>> {
        self.matcher.config = Config::DEFAULT;
        let lower = query.to_ascii_lowercase();
        let mut ranked = vec![];
        for (index, info) in self.catalog.iter().enumerate() {
            let name = format!("{} {}", info.name, info.synopsis());
            let label = format!("{:<32} {}", name.trim_end(), info.doc);
            let detail = label.len() - info.doc.len();
            let (rank, highlights) = if query.is_empty() {
                (0, vec![])
            } else if info.name == query {
                (u32::MAX, one(0..query.len()))
            } else if let Some((score, highlights)) =
                fuzzy_match(&mut self.matcher, query, &info.name)
            {
                (u32::from(score) + 1, highlights)
            } else if let Some(start) = info.doc.to_ascii_lowercase().find(&lower) {
                (0, one(detail + start..detail + start + query.len()))
            } else {
                continue;
            };
            let row = row(index as u64, label, Some(info.name.clone()), false);
            ranked.push((rank, mark(row, highlights, Some(detail))));
        }
        // Stable: equal ranks keep catalog order.
        ranked.sort_by_key(|(rank, _)| std::cmp::Reverse(*rank));
        ranked.into_iter().map(|(_, row)| row).collect()
    }
    fn paths(&mut self, text: &str, response: &mut Response) -> Vec<MatchedCandidate<Completion>> {
        let (parent, prefix) = split_path(text);
        let path = match resolve_path(
            &self.base,
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
        let mut matched: Vec<_> = entries
            .iter()
            .enumerate()
            .filter_map(|(index, entry)| {
                let slash = if entry.directory { "/" } else { "" };
                let replacement = entry
                    .name
                    .to_str()
                    .filter(|name| !name.chars().any(char::is_control))
                    .map(|name| format!("{parent}{name}{slash}"));
                let label = format!("{}{slash}", printable(&entry.name.to_string_lossy()));
                let (leading, typed) = name_match(&label, prefix)?;
                let row = row(index as u64, label, replacement, entry.directory);
                Some((leading, mark(row, typed, None)))
            })
            .collect();
        // Stable: names that begin with the text first, in directory order.
        matched.sort_by_key(|(leading, _)| !*leading);
        matched.into_iter().map(|(_, row)| row).collect()
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
                            detail: None,
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
            self.stale = false;
        }
        true
    }
    pub(super) fn picker_failed(&mut self, error: String) {
        self.error = Some(error);
    }
    /// Whether the text being completed has candidates to choose from;
    /// free text such as keys or a shell command has none.
    /// Whether Enter would take the selected row. In a path slot it takes
    /// the typed text until a row is chosen, and Tab alone uses the default.
    pub fn enter_selects(&self) -> bool {
        self.list.user_selected() || self.locate().target != Some(Target::Slot(SlotKind::Path))
    }
    pub fn completes(&self) -> bool {
        self.query
            .as_ref()
            .is_some_and(|q| !matches!(q.target, Target::Slot(SlotKind::Word | SlotKind::Rest)))
    }
    pub fn loading(&self) -> bool {
        !self.stale && self.waiting(&self.query)
    }
    /// Whether a worker has yet to answer this query.
    fn waiting(&self, query: &Option<Query>) -> bool {
        let target = query.as_ref().map(|q| q.target);
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
        // A name is followed by its arguments when the chosen command has
        // some, whatever the typed prefix names.
        let more = match location.target {
            Some(Target::Name) => self.info(&text).is_some_and(|i| !i.slots.is_empty()),
            _ => location.more,
        };
        if !directory && more && !after.starts_with(char::is_whitespace) {
            text.push(' ');
        }
        self.input.replace_range(location.range.clone(), &text);
        Ok(directory)
    }
    pub(super) fn text(&self) -> &str {
        self.input.text()
    }
    /// Whether the line answers a question, such as a save decision, rather
    /// than being typed; those stay out of the history.
    pub(super) fn asking(&self) -> bool {
        self.note.is_some()
    }
    pub(super) fn recall(&mut self, text: &str, app: &Application) -> Transition {
        let end = self.input.text().len();
        self.input.replace_range(0..end, text);
        self.edited(app)
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
        // A row chosen by hand wins over whatever the text already names.
        let chosen = self.list.user_selected();
        // Only a typed path needs no row; the rest wait for the answer.
        if self.stale && (chosen || location.target != Some(Target::Slot(SlotKind::Path))) {
            return Transition::Blocked;
        }
        let accept = match location.target {
            Some(Target::Name) => chosen || self.info(slot_text).is_none(),
            Some(Target::Slot(SlotKind::Path)) => chosen,
            Some(Target::Slot(kind)) if kind.requires_match() => {
                chosen
                    || !self
                        .rows
                        .iter()
                        .any(|r| r.candidate.payload.replacement.as_deref() == Some(slot_text))
            }
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
    /// Only a line that asks a question answers with one key; a typed line
    /// takes the key as text, so later slots stay reachable.
    fn choice_key(&mut self, key: char) -> bool {
        if !self.asking() {
            return false;
        }
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
            Input::Complete { backward: false } if self.stale => Transition::Blocked,
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

/// Everything matches an empty query; otherwise a fuzzy match with its score.
fn matched(matcher: &mut Matcher, query: &str, shown: &str) -> Option<(u32, Vec<Range<usize>>)> {
    if query.is_empty() {
        Some((0, vec![]))
    } else {
        fuzzy_match(matcher, query, shown).map(|(score, ranges)| (u32::from(score), ranges))
    }
}
/// Recent files, newest first, shown relative to the project root.
fn recent(
    paths: &[PathBuf],
    root: &std::path::Path,
    query: &str,
    matcher: &mut Matcher,
) -> Vec<MatchedCandidate<Completion>> {
    matcher.config = Config::DEFAULT.match_paths();
    let mut rows: Vec<_> = paths
        .iter()
        .enumerate()
        .filter_map(|(age, path)| {
            let shown = printable(&path.strip_prefix(root).unwrap_or(path).to_string_lossy());
            let (score, highlights) = matched(matcher, query, &shown)?;
            Some((age, path, shown, score, highlights))
        })
        .collect();
    rows.sort_by_key(|(age, _, _, score, _)| (std::cmp::Reverse(*score), *age));
    rows.into_iter()
        .map(|(age, path, shown, _, highlights)| {
            let replacement = path.to_str().filter(|p| !p.chars().any(char::is_control));
            mark(
                row(age as u64, shown, replacement.map(str::to_owned), false),
                highlights,
                None,
            )
        })
        .collect()
}
/// Buffer names match fuzzily; other buffers rank before the current one
/// among equal scores.
fn buffers(
    app: &Application,
    query: &str,
    matcher: &mut Matcher,
) -> Vec<MatchedCandidate<Completion>> {
    matcher.config = Config::DEFAULT.match_paths();
    let active = app
        .active_view()
        .and_then(|view| app.view(view))
        .map(|v| v.document_id);
    let mut rows: Vec<_> = app
        .workspace()
        .documents()
        .filter_map(|id| {
            let name = app.document_name(id);
            let shown = printable(&name);
            let (score, highlights) = matched(matcher, query, &shown)?;
            Some((id, name, shown, score, highlights))
        })
        .collect();
    rows.sort_by_key(|(id, _, _, score, _)| (std::cmp::Reverse(*score), active == Some(*id)));
    rows.into_iter()
        .map(|(id, name, shown, _, highlights)| {
            let marker = if active == Some(id) { "* " } else { "  " };
            let dirty = if app.workspace().is_dirty(id) {
                " [+]"
            } else {
                ""
            };
            let label = format!("{marker}{shown}{dirty}");
            let highlights = highlights
                .into_iter()
                .map(|r| r.start + marker.len()..r.end + marker.len())
                .collect();
            let replacement = (!name.chars().any(char::is_control)).then_some(name);
            mark(
                row(id.number(), label, replacement, false),
                highlights,
                None,
            )
        })
        .collect()
}
