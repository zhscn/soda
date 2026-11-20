//! Candidate sources and their pending requests for one command line.
use super::{CommandLine, Completion, Query, Target, printable, split_path, symbols};
use crate::{
    application::Application,
    files::paths::{DirectoryEntry, PathCompletion, PathRequest},
    interaction::{
        LuaRequest, Response, ResponseEffect, SlotKind, history,
        path::resolve_path,
        picker::{
            Candidate, CandidateKey, MatchedCandidate, PickerCompletion, PickerEffect,
            PickerLimits, PickerSession, PickerStatus, fuzzy_match,
        },
        slots,
    },
};
use nucleo_matcher::{Config, Matcher};
use std::{
    collections::HashMap,
    ops::Range,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

#[derive(Default)]
pub(super) struct PendingSources {
    pub(super) directory: Option<Directory>,
    pub(super) files: Option<PickerSession>,
    pub(super) computed: Option<ComputedList>,
}

pub(super) struct Directory {
    path: PathBuf,
    entries: Option<Vec<DirectoryEntry>>,
    pub(super) pending: Option<Arc<AtomicBool>>,
}
impl Drop for Directory {
    fn drop(&mut self) {
        if let Some(token) = &self.pending {
            token.store(true, Ordering::Relaxed);
        }
    }
}

pub(super) struct ComputedList {
    function: u64,
    /// Which request the answer is to.
    token: u64,
    pub(super) items: Option<Vec<slots::Item>>,
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
impl CommandLine {
    /// The rows of the argument a query completes, matched against its
    /// text. Every list of words goes through `words_matching`; paths,
    /// buffers and project files match as paths.
    pub(super) fn candidates(
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
            SlotKind::Face => app
                .faces()
                .names()
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
            SlotKind::Computed(function) => match &self.pending.computed {
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
                        .push(LuaRequest::Candidates { function, token });
                    self.pending.computed = Some(ComputedList {
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
        if self
            .pending
            .directory
            .as_ref()
            .is_none_or(|d| d.path != path)
        {
            let cancelled = Arc::new(AtomicBool::new(false));
            response.effects.push(ResponseEffect::Path(PathRequest {
                directory: path.clone(),
                cancelled: cancelled.clone(),
            }));
            self.pending.directory = Some(Directory {
                path,
                entries: None,
                pending: Some(cancelled),
            });
            return vec![];
        }
        let Some(directory) = self.pending.directory.as_ref() else {
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
        if self.pending.files.is_none() {
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
                    response
                        .effects
                        .push(ResponseEffect::Picker(PickerEffect::Run(session.task())));
                    self.pending.files = Some(session);
                }
                Err(error) => self.error = Some(error.to_string()),
            }
            return vec![];
        }
        let session = self.pending.files.as_mut().unwrap();
        if let Some(task) = session.set_query(text) {
            response
                .effects
                .push(ResponseEffect::Picker(PickerEffect::Run(task)));
        }
        self.file_rows()
    }
    fn file_rows(&self) -> Vec<MatchedCandidate<Completion>> {
        let Some(session) = &self.pending.files else {
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
    pub(in crate::interaction) fn path_finished(
        &mut self,
        completion: PathCompletion,
        app: &Application,
    ) -> Option<Response> {
        let directory = self.pending.directory.as_mut()?;
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
    pub(in crate::interaction) fn candidates_listed(
        &mut self,
        token: u64,
        items: Vec<slots::Item>,
        app: &Application,
    ) -> Option<Response> {
        let list = self
            .pending
            .computed
            .as_mut()
            .filter(|list| list.token == token)?;
        list.items = Some(items);
        Some(self.refresh(app, true))
    }
    pub(in crate::interaction) fn picker_finished(&mut self, completion: PickerCompletion) -> bool {
        let Some(session) = &mut self.pending.files else {
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
    pub(in crate::interaction) fn picker_failed(&mut self, error: String) {
        self.error = Some(error);
    }
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
/// A request identifier distinguishes an answer from late replies.
fn next_token() -> u64 {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}
/// Moves the row the typed text names exactly to the front, as vertico
/// does after sorting, so that what is typed in full is the first row: by
/// its label, or by the text it fills in when that is its name.
pub(super) fn exact_first(rows: &mut [MatchedCandidate<Completion>], text: &str, named: bool) {
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
