//! The command line: one input row and the candidates of the argument under
//! the cursor. The command name, slots and current slot are parsed from the
//! text on every change; focus never leaves the input.
use super::{
    Command, Input, InputKey, Presentation, Response, TextInput,
    history::{self, Histories, Recall},
    path::resolve_path,
    picker::{
        Candidate, CandidateKey, CandidateListState, ListMotion, MatchedCandidate,
        PickerCompletion, PickerEffect, PickerLimits, PickerSession, PickerStatus, fuzzy_match,
    },
    registry::{self, CommandInfo, Slot, SlotKind},
    session::{Transition, edit_field, field_presentation},
    slots::{PathForm, Preview, behavior},
};
use crate::{
    application::{Application, ViewId},
    files::paths::{DirectoryEntry, PathCompletion, PathRequest},
};
use nucleo_matcher::{Config, Matcher};
use std::{
    collections::HashMap,
    ops::Range,
    path::{Path, PathBuf},
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
    /// Which slot of the command, when the target is one.
    slot: Option<usize>,
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
    /// The file of the current document, which does not count as taken
    /// when files are ordered by the history: it would always come first.
    current_file: Option<PathBuf>,
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
    projects: Vec<PathBuf>,
    /// Whether project files complete to absolute paths.
    absolute_files: bool,
    /// The items of an `Item` slot.
    items: Vec<super::slots::Item>,
    /// The list a Lua function gives the argument, once asked.
    computed: Option<ComputedList>,
    /// The key tables by name, for a KEYMAP slot.
    keymaps: Vec<(String, String)>,
    /// The symbols of the document, nearest the caret first, once asked.
    symbols: Option<Vec<String>>,
    /// The rows are those of the last input, kept in view while the worker
    /// answers this one, so the list does not blink at each key. They can
    /// be looked at and not chosen.
    stale: bool,
    /// The histories as the line opened, for recalling and for ordering
    /// candidates; they change only as a line closes.
    histories: Histories,
    /// Where `M-p` has recalled to.
    recall: Recall,
    /// The history and the range the last recall filled, until the text is
    /// edited: walking on stays there even if the recalled line puts the
    /// cursor in an argument with a history of its own.
    recalled: Option<(String, Range<usize>)>,
    /// The history a question names for its answer, as the HIST argument
    /// of `read-string`; other questions have none.
    asked_history: Option<String>,
    /// What the line adds to the histories, once it has run.
    records: Vec<(String, String)>,
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
    // Keys in quotes are one argument: `map global "C-c v c" …`.
    if text[from..].starts_with('"') {
        return text[from + 1..]
            .find('"')
            .map_or(text.len(), |i| from + i + 2);
    }
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
pub(super) fn split_path(text: &str) -> (&str, &str) {
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
/// The arguments of a line after its command name, each with its slot,
/// as `locate` divides them: one word each, and the last takes the rest.
fn slot_texts<'a>(
    line: &'a str,
    from: usize,
    slots: &'static [Slot],
) -> Vec<(&'static Slot, &'a str)> {
    let mut out = vec![];
    let mut position = from;
    for (index, slot) in slots.iter().enumerate() {
        let begin = skip_space(line, position);
        let finish = if index + 1 == slots.len() {
            line.len()
        } else {
            word_end(line, begin)
        };
        out.push((slot, line[begin..finish].trim_end()));
        position = finish;
    }
    out
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
            current_file: app
                .active_view()
                .and_then(|view| app.view(view))
                .and_then(|view| app.workspace().file(view.document_id))
                .and_then(|file| file.path())
                .map(Path::to_owned),
            rows: vec![],
            list: CandidateListState::default(),
            query: None,
            directory: None,
            files: None,
            note: None,
            error: None,
            matcher: Matcher::new(Config::DEFAULT),
            recent: vec![],
            projects: vec![],
            absolute_files: false,
            items: vec![],
            computed: None,
            keymaps: vec![],
            symbols: None,
            stale: false,
            histories: Histories::default(),
            recall: Recall::default(),
            recalled: None,
            asked_history: None,
            records: vec![],
        }
    }
    /// The histories to recall from and order candidates by.
    pub fn with_histories(mut self, histories: Histories) -> Self {
        self.histories = histories;
        self
    }
    /// The history a question's answer is recalled from and added to.
    pub fn with_history(mut self, name: Option<String>) -> Self {
        self.asked_history = name;
        self
    }
    /// Recently used files for a `recent` slot, newest first.
    pub fn with_recent(mut self, recent: Vec<PathBuf>) -> Self {
        self.recent = recent;
        self
    }
    /// Remembered projects for a `project-switch` slot, newest first.
    pub fn with_projects(mut self, projects: Vec<PathBuf>) -> Self {
        self.projects = projects;
        self
    }
    /// Project files complete to absolute paths rather than relative ones.
    pub fn with_absolute_files(mut self) -> Self {
        self.absolute_files = true;
        self
    }
    /// The key tables `map` and `unmap` may name, with what each is for.
    pub fn with_keymaps(mut self, keymaps: Vec<(String, String)>) -> Self {
        self.keymaps = keymaps;
        self
    }
    /// Items for an `Item` slot.
    pub fn with_items(mut self, items: Vec<super::slots::Item>) -> Self {
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
                slot: None,
            };
        }
        let none = Location {
            target: None,
            range: cursor..cursor,
            more: false,
            slot: None,
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
                    slot: Some(index),
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
            Some(query) => self.candidates(app, query, &mut response),
        };
        let mut rows = rows;
        // Paths order their own; command names put an exact one first.
        if let Some(query) = &query
            && matches!(query.target, Target::Slot(kind) if kind != SlotKind::Path)
        {
            // An item answers with its number, which is not its name.
            let named = query.target != Target::Slot(SlotKind::Item);
            exact_first(&mut rows, &query.text, named);
        }
        let same_target = self.query.as_ref().map(|q| q.target) == query.as_ref().map(|q| q.target);
        // The same list, only filtered anew: a choice the user moved to
        // stays on its row. A path in another directory is another list,
        // whose rows only share numbers with these.
        let same_list = !restart
            || self
                .query
                .as_ref()
                .zip(query.as_ref())
                .is_some_and(|(old, new)| {
                    old.target == new.target
                        && old.start == new.start
                        && (new.target != Target::Slot(SlotKind::Path)
                            || split_path(&old.text).0 == split_path(&new.text).0)
                });
        if rows.is_empty() && !self.rows.is_empty() && same_target && self.waiting(&query) {
            if !same_list {
                let default = self.default_selection(app, query.as_ref(), &self.rows);
                self.list.reset(&self.rows, default);
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
        let default = self.default_selection(app, query.as_ref(), &rows);
        if same_list {
            self.list.update(&rows, default);
        } else {
            self.list.reset(&rows, default);
        }
        response.redraw = restart || changed;
        self.rows = rows;
        self.query = query;
        response
    }
    /// The rows of the argument a query completes, matched against its
    /// text. Every list of words goes through `words_matching`; paths,
    /// buffers and project files match as paths.
    fn candidates(
        &mut self,
        app: &Application,
        query: &Query,
        response: &mut Response,
    ) -> Vec<MatchedCandidate<Completion>> {
        let text = query.text.as_str();
        let kind = match query.target {
            Target::Name => return self.names(text),
            Target::Slot(kind) => kind,
        };
        let entries: Vec<Entry> = match kind {
            SlotKind::Buffer | SlotKind::CurrentBuffer => {
                return buffers(app, text, &mut self.matcher);
            }
            SlotKind::Recent => return recent(&self.recent, &self.root, text, &mut self.matcher),
            SlotKind::Project => {
                let home = self.home.as_deref();
                return projects(&self.projects, home, text, &mut self.matcher);
            }
            SlotKind::Path => return self.paths(text, response),
            SlotKind::File => return self.project_files(text, response),
            SlotKind::Word | SlotKind::Rest => return vec![],
            SlotKind::Choice(choices) => choices
                .iter()
                .map(|choice| {
                    let key = choice.key.map_or_else(String::new, |k| format!("[{k}] "));
                    Entry::new(choice.word, format!("{key}{}", choice.doc))
                })
                .collect(),
            SlotKind::Option => crate::options::all()
                .into_iter()
                .map(|option| Entry::new(option.name, option.doc.to_owned()))
                .collect(),
            SlotKind::Language => crate::language::catalog()
                .ids()
                .map(|id| Entry::new(id, String::new()))
                .collect(),
            SlotKind::Keymap => {
                let mut names = self.keymaps.clone();
                for id in crate::language::catalog().ids() {
                    if !names.iter().any(|(name, _)| name == id) {
                        names.push((id.to_owned(), format!("Keys of {id} documents")));
                    }
                }
                names
                    .into_iter()
                    .map(|(name, doc)| Entry::new(&name, doc))
                    .collect()
            }
            SlotKind::Face => crate::application::faces::names()
                .map(|name| Entry::new(&name, String::new()))
                .collect(),
            SlotKind::Theme => {
                use crate::application::themes;
                let current = app.options().text(None, "theme");
                app.faces()
                    .theme_names()
                    .map(|name| {
                        let doc = match themes::builtin(name) {
                            // Said once, where the name says it already.
                            Some(theme) => {
                                let shade = if theme.light { "light" } else { "dark" };
                                match theme.doc.to_ascii_lowercase().contains(shade) {
                                    true => theme.doc.to_owned(),
                                    false => format!("{}, {shade}", theme.doc),
                                }
                            }
                            None => "defined by soda.theme".to_owned(),
                        };
                        let mark = if name == current { "● " } else { "" };
                        Entry::new(name, format!("{mark}{doc}"))
                    })
                    .collect()
            }
            SlotKind::Symbol => self
                .symbols(app)
                .iter()
                .map(|s| Entry::new(s, String::new()))
                .collect(),
            // An item answers with its number, so its text may be anything.
            SlotKind::Item => self
                .items
                .iter()
                .enumerate()
                .map(|(index, item)| Entry {
                    replacement: Some((index + 1).to_string()),
                    ..Entry::new(&printable(&item.text), item.doc.clone())
                })
                .collect(),
            SlotKind::Computed(function) => match &self.computed {
                Some(list) if list.function == function => match &list.items {
                    Some(items) => items
                        .iter()
                        .map(|item| Entry::new(&item.text, item.doc.clone()))
                        .collect(),
                    None => return vec![],
                },
                _ => {
                    let token = next_token();
                    response
                        .lua
                        .push(super::LuaRequest::Candidates { function, token });
                    self.computed = Some(ComputedList {
                        function,
                        token,
                        items: None,
                    });
                    return vec![];
                }
            },
        };
        // The history orders the words, but a question's items by the
        // history it names, and the symbols by nearness alone, as
        // `consult-imenu` keeps the document's order.
        let used = match kind {
            SlotKind::Item => self.asked_history.as_ref().map(|name| self.ranks(name)),
            _ => self.slot_history(kind).map(|name| self.ranks(&name)),
        };
        let used = used.unwrap_or_default();
        words_matching(&mut self.matcher, text, entries, &used)
    }
    /// The symbols of the document, nearest the caret first, listed once.
    fn symbols(&mut self, app: &Application) -> &[String] {
        self.symbols.get_or_insert_with(|| {
            let Some(view) = app.active_view().and_then(|view| app.view(view)) else {
                return vec![];
            };
            let editor = app.workspace().editor(view.document_id).unwrap();
            let caret = editor
                .model()
                .session(view.session_id)
                .unwrap()
                .selection()
                .head;
            symbols(editor.model().document().snapshot().text(), caret)
        })
    }
    /// Command names are words with their synopsis, by when each ran.
    fn names(&mut self, query: &str) -> Vec<MatchedCandidate<Completion>> {
        let used = self.ranks(history::COMMAND_NAME);
        let words: Vec<_> = self
            .catalog
            .iter()
            .map(|info| Entry {
                shown: Some(
                    format!("{} {}", info.name, info.synopsis())
                        .trim_end()
                        .to_owned(),
                ),
                ..Entry::new(&info.name, info.doc.clone())
            })
            .collect();
        words_matching(&mut self.matcher, query, words, &used)
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
                cancelled: cancelled.clone(),
            });
            self.directory = Some(Directory {
                path,
                entries: None,
                pending: Some(cancelled),
            });
            return vec![];
        }
        let Some(directory) = self.directory.as_ref() else {
            return vec![];
        };
        let Some(entries) = directory.entries.as_ref() else {
            return vec![];
        };
        let ranks = self.directory_ranks(&directory.path);
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
                let used = ranks.get(&entry.name).copied().unwrap_or(u32::MAX);
                // As vertico puts the typed name first, then the directory
                // of that name.
                let exact = match label.strip_prefix(prefix) {
                    _ if prefix.is_empty() => 2,
                    Some("") => 0,
                    Some("/") => 1,
                    _ => 2,
                };
                let row = row(index as u64, label, replacement, entry.directory);
                Some(((exact, !leading, used), mark(row, typed, None)))
            })
            .collect();
        // Stable: the typed name first, then names that begin with the
        // text, then files taken lately, in directory order.
        matched.sort_by_key(|(key, _)| *key);
        matched.into_iter().map(|(_, row)| row).collect()
    }
    fn project_files(
        &mut self,
        text: &str,
        response: &mut Response,
    ) -> Vec<MatchedCandidate<Completion>> {
        if self.files.is_none() {
            match PickerSession::new(self.root.clone(), PickerLimits::default()) {
                Ok(session) => {
                    let home = self.home.as_deref();
                    let ranks = self
                        .histories
                        .entries(history::FILE)
                        .iter()
                        .rev()
                        .enumerate()
                        .map(|(age, entry)| (history::expand(entry, home), age as u32))
                        .collect();
                    let mut session = session.with_history(ranks);
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
                let relative = match self.absolute_files {
                    true => path,
                    false => path.strip_prefix(&self.root).unwrap_or(path),
                };
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
    /// Takes the words a Lua function listed, if they answer the request
    /// this line made last.
    pub(super) fn candidates_listed(
        &mut self,
        token: u64,
        items: Vec<super::slots::Item>,
        app: &Application,
    ) -> Option<Response> {
        let list = self.computed.as_mut().filter(|list| list.token == token)?;
        list.items = Some(items);
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
            let mut rows = self.file_rows();
            if let Some(query) = &self.query {
                exact_first(&mut rows, &query.text, true);
            }
            // Project files must match, so the first row is the default.
            let default = rows.first().map(|row| row.candidate.key);
            self.list.update(&rows, default);
            self.rows = rows;
            self.stale = false;
        }
        true
    }
    pub(super) fn picker_failed(&mut self, error: String) {
        self.error = Some(error);
    }
    /// Whether the input itself can be selected, so that Enter takes it as
    /// typed, as vertico allows the prompt: where the text need not name a
    /// candidate.
    fn allows_input(&self) -> bool {
        match self.query.as_ref().map(|q| q.target) {
            None => true,
            Some(Target::Name) => false,
            Some(Target::Slot(kind)) => !behavior(kind).requires_match,
        }
    }
    /// Selects the input, so that Enter takes it as typed.
    pub(super) fn select_input(&mut self) {
        self.list.select_input();
    }
    /// Whether the input is selected over rows, so that Enter takes the
    /// text as typed; the screen marks the input then.
    pub fn input_selected(&self) -> bool {
        !self.rows.is_empty() && self.list.index(&self.rows).is_none()
    }
    /// Where the selection starts on new rows, as `vertico-preselect` set
    /// to `directory`: the first row, but the input where the text goes on
    /// to a directory, and while nothing is typed the row of what is in
    /// force, such as the theme or the buffer to kill, so that Enter alone
    /// keeps it. None is the input.
    fn default_selection(
        &self,
        app: &Application,
        query: Option<&Query>,
        rows: &[MatchedCandidate<Completion>],
    ) -> Option<CandidateKey> {
        let first = rows.first().map(|row| row.candidate.key);
        let Some(Query {
            target: Target::Slot(kind),
            text,
            ..
        }) = query
        else {
            return first;
        };
        let behavior = behavior(*kind);
        if behavior.input_first.is_some_and(|starts| starts(text)) {
            return None;
        }
        let current = behavior
            .current
            .filter(|_| text.is_empty())
            .and_then(|current| current(app));
        current
            .and_then(|current| {
                rows.iter()
                    .find(|row| row.candidate.payload.replacement.as_deref() == Some(&current))
            })
            .map(|row| row.candidate.key)
            .or(first)
    }
    /// What to show of the selected row before it is taken, once the user
    /// moves to one or types text that picks one. Closing the line leaves
    /// what is in force; taking the row sets it.
    pub fn preview(&self) -> Option<(Preview, &str)> {
        let query = self.query.as_ref()?;
        let Target::Slot(kind) = query.target else {
            return None;
        };
        let preview = behavior(kind).preview?;
        if self.stale || !(self.list.user_selected() || !query.text.is_empty()) {
            return None;
        }
        let row = &self.rows[self.list.index(&self.rows)?];
        Some((preview, row.candidate.payload.replacement.as_deref()?))
    }
    pub fn completes(&self) -> bool {
        self.query.as_ref().is_some_and(|q| match q.target {
            Target::Name => true,
            Target::Slot(kind) => behavior(kind).completes,
        })
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
            || (matches!(target, Some(Target::Slot(SlotKind::Computed(_))))
                && self.computed.as_ref().is_some_and(|c| c.items.is_none()))
    }
    fn close(&self, commands: Vec<Command>) -> Transition {
        Transition::Closed(Response {
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
    /// Puts the candidate of a row into the slot under the cursor. Returns
    /// whether a directory was entered.
    fn fill(&mut self, location: &Location, index: usize) -> Result<bool, String> {
        let completion = &self
            .rows
            .get(index)
            .ok_or_else(|| "no candidate".to_owned())?
            .candidate
            .payload;
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
    /// Whether the line answers a question, such as a save decision, rather
    /// than being typed; those stay out of the history.
    pub(super) fn asking(&self) -> bool {
        self.note.is_some()
    }
    /// Whether `M-p` and `M-n` walk a history: a typed line always does,
    /// a question only when it names one.
    pub(super) fn has_history(&self) -> bool {
        !self.asking() || self.asked_history.is_some()
    }
    /// The history of the text under the cursor and the range it fills: an
    /// argument's own, or whole lines for the command name and arguments
    /// that have none.
    fn field_history(&self, location: &Location) -> Option<(String, Range<usize>)> {
        if self.asking() {
            let name = self.asked_history.clone()?;
            return matches!(location.target, Some(Target::Slot(_)))
                .then(|| (name, location.range.clone()));
        }
        let text = self.input.text();
        let start = skip_space(text, 0);
        let info = self.info(&text[start..word_end(text, start)]);
        let slot = match (info, location.slot) {
            (Some(info), Some(index)) => history::of_slot(&info.name, info.slots, index),
            _ => None,
        };
        Some(match slot {
            Some(name) => (name, location.range.clone()),
            None => (history::COMMAND.to_owned(), 0..text.len()),
        })
    }
    /// A history's entries as they are written into a slot of `kind`,
    /// oldest first: files relative to the project where the candidates
    /// show them so, and leaving out project files of other projects.
    fn recallable(&self, name: &str, kind: Option<SlotKind>, histories: &Histories) -> Vec<String> {
        let entries = histories.entries(name);
        let form = kind.and_then(|kind| behavior(kind).path);
        if !matches!(form, Some(PathForm::Project | PathForm::Recent)) {
            return entries.to_vec();
        }
        entries
            .iter()
            .filter_map(|entry| {
                let path = history::expand(entry, self.home.as_deref());
                match path.strip_prefix(&self.root) {
                    Ok(relative) => relative.to_str().map(str::to_owned),
                    Err(_) if form == Some(PathForm::Recent) => path.to_str().map(str::to_owned),
                    Err(_) => None,
                }
            })
            .collect()
    }
    /// Puts an older or newer entry of the field's history in the field;
    /// None when there is none that way.
    pub(super) fn recall(
        &mut self,
        histories: &Histories,
        backward: bool,
        app: &Application,
    ) -> Option<Transition> {
        let location = self.locate();
        let (name, range) = match self.recalled.take() {
            Some(field) => field,
            None => self.field_history(&location)?,
        };
        let kind = match location.target {
            Some(Target::Slot(kind)) if name != history::COMMAND => Some(kind),
            _ => None,
        };
        let entries = self.recallable(&name, kind, histories);
        let text = &self.input.text()[range.clone()];
        let Some(entry) = self
            .recall
            .step((&name, range.start), &entries, text, backward)
        else {
            self.recalled = Some((name, range));
            return None;
        };
        let start = range.start;
        self.input.replace_range(range, &entry);
        let transition = self.edited(app);
        self.recalled = Some((name, start..start + entry.len()));
        Some(transition)
    }
    /// What the line adds to the histories, once it has run.
    pub(super) fn take_records(&mut self) -> Vec<(String, String)> {
        std::mem::take(&mut self.records)
    }
    /// What a line about to run adds to the histories: the line, its
    /// command name, and each argument that has a history, files as
    /// absolute paths under `~` so that they recall anywhere. A question
    /// adds its answer to the history it names, and nothing else.
    fn records_of(&self, line: &str) -> Vec<(String, String)> {
        let start = skip_space(line, 0);
        let end = word_end(line, start);
        let Some(info) = self.info(&line[start..end]) else {
            return match self.asking() {
                true => vec![],
                false => vec![(history::COMMAND.to_owned(), line.to_owned())],
            };
        };
        let slots = slot_texts(line, end, info.slots);
        if self.asking() {
            let Some(name) = &self.asked_history else {
                return vec![];
            };
            return slots
                .into_iter()
                .take(1)
                .filter_map(|(slot, text)| {
                    let entry = match slot.kind {
                        // An item answers with its number; its history
                        // keeps the item.
                        SlotKind::Item => text
                            .parse::<usize>()
                            .ok()
                            .and_then(|n| self.items.get(n.checked_sub(1)?))?
                            .text
                            .clone(),
                        _ => text.to_owned(),
                    };
                    Some((name.clone(), entry))
                })
                .collect();
        }
        let mut records = vec![
            (history::COMMAND.to_owned(), line.to_owned()),
            (history::COMMAND_NAME.to_owned(), info.name.clone()),
        ];
        for (index, (slot, text)) in slots.into_iter().enumerate() {
            let Some(name) = history::of_slot(&info.name, info.slots, index) else {
                continue;
            };
            let entry = match behavior(slot.kind).path {
                _ if super::expand::has_expansions(text) => None,
                Some(PathForm::Typed) => {
                    resolve_path(&self.base, self.home.as_deref(), Path::new(text))
                        .ok()
                        .and_then(|path| history::abbreviate(&path, self.home.as_deref()))
                }
                Some(PathForm::Project | PathForm::Recent) => {
                    history::abbreviate(&self.root.join(text), self.home.as_deref())
                }
                None => Some(text.to_owned()),
            };
            if let Some(entry) = entry {
                records.push((name, entry));
            }
        }
        records
    }
    /// How recently each entry of a history was taken: 0 is the newest.
    fn ranks(&self, name: &str) -> HashMap<String, u32> {
        self.histories.ranks(name)
    }
    /// How recently a file was taken in or below each entry of a directory,
    /// 0 the newest, as vertico ranks the steps of a file name: a history
    /// entry under the directory counts for its first component, so
    /// `~/.config/` ranks by `~/.config/soda/init.lua`.
    fn directory_ranks(&self, directory: &Path) -> HashMap<std::ffi::OsString, u32> {
        let home = self.home.as_deref();
        let directory = history::normalize(directory);
        let mut ranks = HashMap::new();
        let entries = self.histories.entries(history::FILE).iter().rev();
        for (age, entry) in entries.enumerate() {
            let path = history::expand(entry, home);
            if self.current_file.as_ref() == Some(&path) {
                continue;
            }
            if let Ok(below) = path.strip_prefix(&directory)
                && let Some(first) = below.components().next()
            {
                ranks
                    .entry(first.as_os_str().to_owned())
                    .or_insert(age as u32);
            }
        }
        ranks
    }
    /// The history of a kind of slot that names no command.
    fn slot_history(&self, kind: SlotKind) -> Option<String> {
        let slot = Slot {
            name: "",
            kind,
            required: true,
        };
        history::of_slot("", &[slot], 0)
    }
    fn edited(&mut self, app: &Application) -> Transition {
        self.error = None;
        self.recalled = None;
        let mut response = self.refresh(app, false);
        response.redraw = true;
        Transition::Active(response)
    }
    /// Takes the selection, as `vertico-exit`: a row fills its slot, the
    /// input stays as typed, which must then name a candidate where one is
    /// required; then the line runs, or goes on to the next argument.
    fn confirm(&mut self, app: &Application) -> Transition {
        let location = self.locate();
        let slot_text = &self.input.text()[location.range.clone()];
        let selected = self.list.index(&self.rows);
        // Rows of the last input wait for this one's; only the input
        // itself can be taken meanwhile.
        if self.stale && selected.is_some() {
            return Transition::Blocked;
        }
        if location.target == Some(Target::Slot(SlotKind::Project))
            && slot_text.trim().is_empty()
            && self.rows.is_empty()
        {
            self.error = Some("no remembered project; type a directory".into());
            return Transition::redraw();
        }
        let mut accepted = false;
        match selected {
            Some(index) => match self.fill(&location, index) {
                Ok(true) => return self.edited(app),
                Ok(false) => accepted = true,
                Err(error) => {
                    self.error = Some(error);
                    return Transition::redraw();
                }
            },
            None => {
                if let Some(Target::Slot(kind)) = location.target
                    && behavior(kind).requires_match
                    && !self
                        .rows
                        .iter()
                        .any(|r| r.candidate.payload.replacement.as_deref() == Some(slot_text))
                {
                    self.error = Some("no matching candidate".into());
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
            Ok(()) => {
                self.records = self.records_of(&text);
                self.close(vec![Command::Named(text)])
            }
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
    /// Backspace after a `/` in a path slot removes the directory before
    /// it, as `vertico-directory-up`; `~/` first becomes the home
    /// directory, so it goes up to the directory holding that. Without a
    /// directory before the slash, Backspace deletes as usual.
    fn delete_directory(&mut self, location: &Location) -> bool {
        let cursor = self.input.cursor();
        if location.target != Some(Target::Slot(SlotKind::Path))
            || !self.input.selection().range().is_empty()
            || cursor <= location.range.start
            || cursor > location.range.end
            || !self.input.text()[..cursor].ends_with('/')
        {
            return false;
        }
        let start = location.range.start;
        if &self.input.text()[start..cursor] == "~/"
            && let Some(home) = self.home.as_ref().and_then(|home| home.to_str())
        {
            let home = format!("{}/", home.trim_end_matches('/'));
            self.input.replace_range(start..cursor, &home);
        }
        let cursor = self.input.cursor();
        let before = &self.input.text()[start..cursor - 1];
        let Some(slash) = before.rfind('/') else {
            return false;
        };
        self.input.replace_range(start + slash + 1..cursor, "");
        true
    }
    /// Drops the part of a path that what was typed after it shadows, as
    /// `vertico-directory-tidy` deletes what `file-name-shadow-mode` greys
    /// out: after `//` the path starts over at the root, and after `/~` at
    /// the home directory. Only typing at the end of the path does this.
    fn tidy_shadowed(&mut self) {
        let location = self.locate();
        if location.target != Some(Target::Slot(SlotKind::Path))
            || self.input.cursor() != location.range.end
        {
            return;
        }
        let text = &self.input.text()[location.range.clone()];
        let from = [text.rfind("//"), text.rfind("/~")]
            .into_iter()
            .flatten()
            .max();
        if let Some(at) = from {
            // The whole slot is replaced, so the caret stays at its end.
            let kept = text[at + 1..].to_owned();
            self.input.replace_range(location.range, &kept);
        }
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
                let input = self.allows_input();
                self.list
                    .navigate(&self.rows, ListMotion::Previous, true, input);
                Transition::redraw()
            }
            Input::Complete { backward: false } if self.stale => Transition::Blocked,
            Input::Complete { backward: false } => {
                // As `vertico-insert`: the selected row, or the first one
                // while the input is selected.
                let location = self.locate();
                let index = self.list.index(&self.rows).unwrap_or(0);
                match self.fill(&location, index) {
                    Ok(_) => self.edited(app),
                    Err(error) => {
                        self.error = Some(error);
                        Transition::redraw()
                    }
                }
            }
            Input::Candidate { motion, wrap } => {
                let input = self.allows_input();
                if self.list.navigate(&self.rows, motion, wrap, input) {
                    Transition::redraw()
                } else {
                    Transition::Blocked
                }
            }
            // As vertico-directory: after a slash, both delete a directory.
            Input::Text(InputKey::Delete {
                backward: true,
                word: _,
            }) if self.delete_directory(&self.locate()) => self.edited(app),
            input => {
                let typed = matches!(input, Input::Text(InputKey::Char(_)));
                match edit_field(&mut self.input, input) {
                    Some(update) if update.text_changed || update.selection_changed => {
                        if typed {
                            self.tidy_shadowed();
                        }
                        self.edited(app)
                    }
                    _ => Transition::Blocked,
                }
            }
        }
    }
    pub(super) fn observe(&mut self, app: &Application) -> Transition {
        if app.active_view() != self.view {
            return self.close(vec![]);
        }
        let live = self
            .query
            .as_ref()
            .is_some_and(|q| matches!(q.target, Target::Slot(kind) if behavior(kind).live));
        Transition::Active(if live {
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

/// The symbols of a text, each once, nearest `caret` first: runs of word
/// characters that do not start with a digit.
pub(super) fn symbols(text: &str, caret: usize) -> Vec<String> {
    let mut found: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    // Where the word being read starts, and whether it is a symbol.
    let mut word: Option<(usize, bool)> = None;
    for (at, ch) in text
        .char_indices()
        .chain(std::iter::once((text.len(), ' ')))
    {
        match (word, super::completion::is_word(ch)) {
            (None, true) => word = Some((at, !ch.is_ascii_digit())),
            (Some((from, symbol)), false) => {
                if symbol {
                    let distance = if at <= caret {
                        caret - at
                    } else {
                        from.saturating_sub(caret)
                    };
                    let entry = found.entry(&text[from..at]).or_insert(distance);
                    *entry = (*entry).min(distance);
                }
                word = None;
            }
            _ => {}
        }
    }
    let mut symbols: Vec<_> = found.into_iter().collect();
    symbols.sort_by_key(|(symbol, distance)| (*distance, *symbol));
    symbols
        .into_iter()
        .map(|(symbol, _)| symbol.to_owned())
        .collect()
}
/// A word a list offers: what is matched, what the row shows for it and
/// after it, and what it fills in. The list lays the rows out, so that
/// descriptions line up whatever lists them, as marginalia aligns
/// annotations.
struct Entry {
    word: String,
    /// The word as the row shows it, starting with it; a command shows its
    /// arguments too.
    shown: Option<String>,
    /// What is said of it, dimmed after the words.
    annotation: String,
    /// What it fills in: the word, unless said otherwise.
    replacement: Option<String>,
}
impl Entry {
    fn new(word: &str, annotation: String) -> Self {
        Self {
            word: word.to_owned(),
            shown: None,
            annotation,
            replacement: Some(word.to_owned()),
        }
    }
}
/// The widest the column of words grows; longer words push their
/// description on.
const WORD_COLUMN: usize = 32;
/// Words match alike whatever lists them, as one completion style serves
/// every completion table: an exact word first, then words that match
/// fuzzily, then words whose description holds the text, all in smart
/// case. Words that match alike come in the order they were last taken,
/// as `minibuffer-sort-by-history` orders them, then in the list's.
fn words_matching(
    matcher: &mut Matcher,
    query: &str,
    entries: impl IntoIterator<Item = Entry>,
    used: &HashMap<String, u32>,
) -> Vec<MatchedCandidate<Completion>> {
    use unicode_width::UnicodeWidthStr;
    matcher.config = Config::DEFAULT;
    let entries: Vec<_> = entries.into_iter().collect();
    // As wide as the words of the whole list, so the column stays put
    // while typing narrows it.
    let column = entries
        .iter()
        .map(|entry| entry.shown.as_deref().unwrap_or(&entry.word).width())
        .max()
        .unwrap_or(0)
        .min(WORD_COLUMN);
    let exact_case = query.chars().any(char::is_uppercase);
    let fold = |text: &str| match exact_case {
        true => text.to_owned(),
        false => text.to_ascii_lowercase(),
    };
    let wanted = fold(query);
    let mut ranked = vec![];
    for (index, entry) in entries.into_iter().enumerate() {
        let shown = entry.shown.unwrap_or_else(|| entry.word.clone());
        let (label, detail) = match entry.annotation.is_empty() {
            true => (shown, None),
            false => {
                let pad = column.saturating_sub(shown.width());
                let label = format!("{shown}{:pad$} {}", "", entry.annotation);
                let detail = label.len() - entry.annotation.len();
                (label, Some(detail))
            }
        };
        let (rank, highlights) = if query.is_empty() {
            (0, vec![])
        } else if entry.word == query {
            (u32::MAX, one(0..query.len()))
        } else if let Some((score, highlights)) = fuzzy_match(matcher, query, &entry.word) {
            (u32::from(score) + 1, highlights)
        } else if let Some(start) = detail.and_then(|at| fold(&label[at..]).find(&wanted)) {
            let start = detail.unwrap_or(0) + start;
            (0, one(start..start + query.len()))
        } else {
            continue;
        };
        let used = history_rank(used, Some(&entry.word));
        let row = row(index as u64, label, entry.replacement, false);
        ranked.push(((rank, used), mark(row, highlights, detail)));
    }
    // Stable: what ties keeps the list's order.
    ranked.sort_by_key(|((rank, used), _)| (std::cmp::Reverse(*rank), *used));
    ranked.into_iter().map(|(_, row)| row).collect()
}
/// A list a Lua function gives an argument, once it answers.
struct ComputedList {
    function: u64,
    /// Which request the answer is to.
    token: u64,
    items: Option<Vec<super::slots::Item>>,
}
/// A request's own number, so a late answer to an earlier one is known.
fn next_token() -> u64 {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}
/// Moves the row the typed text names exactly to the front, as vertico
/// does after sorting, so that what is typed in full is the first row: by
/// its label, or by the text it fills in when that is its name.
fn exact_first(rows: &mut [MatchedCandidate<Completion>], text: &str, named: bool) {
    if text.is_empty() {
        return;
    }
    let exact = rows.iter().position(|row| {
        row.candidate.label == text
            || (named && row.candidate.payload.replacement.as_deref() == Some(text))
    });
    if let Some(index) = exact {
        rows[..=index].rotate_right(1);
    }
}
/// Where an entry stands in a history, newest first; entries the history
/// does not hold come after all.
fn history_rank(ranks: &HashMap<String, u32>, entry: Option<&str>) -> u32 {
    entry
        .and_then(|entry| ranks.get(entry))
        .copied()
        .unwrap_or(u32::MAX)
}
/// Paths that match `query` fuzzily, best first, each with what it shows
/// and the ranges that matched; `rank` orders equal scores, and all of
/// them when the query is empty.
fn ranked<T, K: Ord>(
    matcher: &mut Matcher,
    query: &str,
    candidates: impl IntoIterator<Item = (T, String)>,
    rank: impl Fn(&T) -> K,
) -> impl Iterator<Item = (T, String, Vec<Range<usize>>)> {
    let mut found: Vec<_> = candidates
        .into_iter()
        .filter_map(|(item, shown)| {
            let (score, highlights) = if query.is_empty() {
                (0, vec![])
            } else {
                fuzzy_match(matcher, query, &shown)?
            };
            Some((score, item, shown, highlights))
        })
        .collect();
    found.sort_by_key(|(score, item, ..)| (std::cmp::Reverse(*score), rank(item)));
    found
        .into_iter()
        .map(|(_, item, shown, highlights)| (item, shown, highlights))
}
/// Recent files, newest first, shown relative to the project root.
fn recent(
    paths: &[PathBuf],
    root: &std::path::Path,
    query: &str,
    matcher: &mut Matcher,
) -> Vec<MatchedCandidate<Completion>> {
    matcher.config = Config::DEFAULT.match_paths();
    let shown = paths.iter().enumerate().map(|(age, path)| {
        let shown = printable(&path.strip_prefix(root).unwrap_or(path).to_string_lossy());
        ((age, path), shown)
    });
    ranked(matcher, query, shown, |_| false)
        .map(|((age, path), shown, highlights)| {
            let replacement = path.to_str().filter(|p| !p.chars().any(char::is_control));
            mark(
                row(age as u64, shown, replacement.map(str::to_owned), false),
                highlights,
                None,
            )
        })
        .collect()
}
/// Remembered projects that still exist, newest first, shown as
/// project.el shows them: under `~`, ending in a slash.
fn projects(
    roots: &[PathBuf],
    home: Option<&std::path::Path>,
    query: &str,
    matcher: &mut Matcher,
) -> Vec<MatchedCandidate<Completion>> {
    matcher.config = Config::DEFAULT.match_paths();
    let shown = roots
        .iter()
        .filter(|root| root.is_dir())
        .enumerate()
        .map(|(age, root)| {
            let shown = match home.and_then(|home| root.strip_prefix(home).ok()) {
                Some(below) => format!("~/{}/", below.display()),
                None => format!("{}/", root.display()),
            };
            ((age, root), printable(&shown))
        });
    ranked(matcher, query, shown, |_| false)
        .map(|((age, root), shown, highlights)| {
            let replacement = root.to_str().filter(|p| !p.chars().any(char::is_control));
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
    let shown = app.workspace().documents().map(|id| {
        let name = app.document_name(id);
        let shown = printable(&name);
        ((id, name), shown)
    });
    // As Emacs's other-buffer: the buffer used last before this one comes
    // first, so Enter alone goes back to it; the current one comes last.
    let used: Vec<_> = app.documents_by_use().collect();
    let rank = |(id, _): &(crate::editor::DocumentId, String)| {
        let by_use = used
            .iter()
            .position(|used| used == id)
            .unwrap_or(usize::MAX);
        (active == Some(*id), by_use)
    };
    ranked(matcher, query, shown, rank)
        .map(|((id, name), shown, highlights)| {
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
