//! The command line: one input row and the candidates of the argument under
//! the cursor. The command name, slots and current slot are parsed from the
//! text on every change; focus never leaves the input.
use super::{
    Command, Input, InputKey, Layer, Presentation, Response, TextInput,
    history::{self, Histories, Recall},
    path::resolve_path,
    picker::{CandidateKey, CandidateListState, ListMotion, MatchedCandidate, PickerSession},
    registry::{self, CommandInfo},
    session::{Transition, edit_field, field_presentation},
    slots::{PathForm, Preview, Slot, SlotKind, behavior},
};
use crate::application::{Application, ViewId};
use nucleo_matcher::{Config, Matcher};

use std::{
    collections::HashMap,
    ops::Range,
    path::{Path, PathBuf},
};

pub(super) mod candidates;
pub(super) use candidates as sources;
pub use candidates::CandidateReply;
use candidates::{PendingSources, exact_first};

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
impl Target {
    fn behavior(self) -> super::slots::Behavior {
        match self {
            Self::Name => super::slots::Behavior::TEXT,
            Self::Slot(kind) => behavior(kind),
        }
    }
}

struct Location {
    target: Option<Target>,
    range: Range<usize>,
    /// Whether a slot follows the current one.
    more: bool,
    /// Which slot of the command, when the target is one.
    slot: Option<usize>,
}
impl Location {
    fn behavior(&self) -> super::slots::Behavior {
        self.target
            .map_or(super::slots::Behavior::TEXT, Target::behavior)
    }
}

#[derive(PartialEq)]
struct Query {
    target: Target,
    start: usize,
    text: String,
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
    pending: PendingSources,
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
    directory_input: bool,
    /// What the line adds to the histories, once it has run.
    records: Vec<(String, String)>,
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
            pending: PendingSources::default(),
            note: None,
            error: None,
            matcher: Matcher::new(Config::DEFAULT),
            recent: vec![],
            projects: vec![],
            absolute_files: false,
            items: vec![],
            keymaps: vec![],
            symbols: None,
            stale: false,
            histories: Histories::default(),
            recall: Recall::default(),
            recalled: None,
            asked_history: None,
            directory_input: false,
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
    /// A path question may take the current directory as its answer.
    pub fn with_directory_input(mut self, accepts: bool) -> Self {
        self.directory_input = accepts;
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
        self.pending.files()
    }
    pub fn picker(&self) -> Option<super::picker::PickerId> {
        self.pending.files().map(PickerSession::id)
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
            && matches!(query.target, Target::Slot(kind) if !behavior(kind).source_order)
        {
            // An item answers with its number, which is not its name.
            let named = !query.target.behavior().numbered_items;
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
                        && match new.target {
                            Target::Slot(kind) => behavior(kind)
                                .list_key
                                .is_none_or(|key| key(&old.text) == key(&new.text)),
                            Target::Name => true,
                        }
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
        query
            .as_ref()
            .is_some_and(|query| self.pending.waiting(query.target))
    }
    fn close(&self, commands: Vec<Command>) -> Transition {
        Transition::Closed(Response {
            commands,
            effects: self.pending.cancel().into_iter().collect(),
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
                        kind if behavior(kind).numbered_items => text
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
        if let Some(hint) = location.behavior().empty_hint
            && slot_text.trim().is_empty()
            && self.rows.is_empty()
        {
            self.error = Some(hint.into());
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
            && !self.directory_input
            && location.behavior().browse_directories
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
        if !location.behavior().browse_directories
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
        if !location.behavior().browse_directories || self.input.cursor() != location.range.end {
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
                match edit_field(&mut self.input, input, app.clipboard()) {
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

/// A command line opened for a command, a question or another project.
#[derive(Clone, Debug)]
pub enum PromptCommand {
    /// Open the command line with initial text.
    Ex(String),
    /// Open the command line with a note on what it asks about.
    Ask { line: String, note: String },
    /// The command line for `project`, choosing among this project's files.
    ProjectLine(std::path::PathBuf),
}

impl super::Layers {
    pub(super) fn execute_prompt(
        &mut self,
        command: PromptCommand,
        app: &Application,
        time: std::time::Duration,
        file_root: &Path,
    ) -> Result<Response, crate::core::EditError> {
        // Only the question Lua just put names a history.
        let asked_history = self.lua_interaction.asked_history.take();
        let asked_kind = self.lua_interaction.asked_kind.take();
        let (text, note, project) = match command {
            PromptCommand::Ask { line, note } => (line, Some(note), None),
            PromptCommand::Ex(text) => (text, None, None),
            PromptCommand::ProjectLine(project) => ("project ".to_owned(), None, Some(project)),
        };
        // A command line of its own answers no earlier question.
        if note.is_none() {
            self.forget_reply();
        }
        // A question of a kind answers as an argument of it would.
        let mut catalog = self.registry.commands();
        if let Some(kind) = asked_kind
            && let Some(answer) = catalog.iter_mut().find(|info| info.name == "answer")
        {
            answer.slots = super::slots::answer_slots(kind);
        }
        let mut line = CommandLine::new(
            &text,
            catalog,
            project.clone().unwrap_or_else(|| file_root.to_owned()),
            app.directory(),
            app,
        )
        .with_recent(self.prompt_history.recent_files.clone())
        .with_projects(self.prompt_history.projects.clone())
        .with_keymaps(self.keys.keymap.names())
        .with_items(
            self.lua_interaction
                .question
                .as_ref()
                .map_or(vec![], |(_, i)| i.clone()),
        )
        .with_histories(self.prompt_history.history.clone())
        .with_history(asked_history)
        .with_directory_input(asked_kind.is_some_and(|kind| behavior(kind).browse_directories));
        if let Some(note) = note {
            line = line.with_note(note);
        }
        // Files of another project complete to absolute paths, which
        // `project` opens whatever the active document's project.
        if project.is_some() {
            line = line.with_absolute_files();
        }
        let mut response = self.enter(Layer::CommandLine(Box::new(line)), app, time)?;
        if let Some(Layer::CommandLine(line)) = &mut self.active {
            let first = line.refresh(app, true);
            response.effects.extend(first.effects);
            response.lua.extend(first.lua);
        }
        Ok(response)
    }
}
