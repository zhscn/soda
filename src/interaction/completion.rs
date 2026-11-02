//! Completion in Insert mode, modelled on an input method: the text being
//! composed is real text between an anchor and the caret, and everything
//! else follows from those two. Any move or edit that keeps the caret in one
//! word keeps the session; there are no key-by-key rules. Candidates stay
//! out of the document until one is accepted. See `docs/completion.md`.
use crate::{
    application::{Application, ViewId},
    core::{Association, ByteOffset, Snapshot},
    editor::DocumentPosition,
    interaction::{EditMode, picker::fuzzy_match},
};
use nucleo_matcher::{
    Config, Matcher, Utf32Str,
    pattern::{Atom, AtomKind, CaseMatching, Normalization},
};
use std::path::{Path, PathBuf};

/// Rows of a page of candidates.
pub const PAGE: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Action {
    /// Starts completion at the caret, however little is typed.
    Trigger,
    Dismiss,
    Move {
        backward: bool,
    },
    /// Takes the selection, leaving the text after the caret.
    Accept,
    /// Takes the selection or the first candidate, replacing through the
    /// end of the word.
    Replace,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Item {
    pub label: String,
    /// What typing matches against, when it is not the label.
    pub filter: String,
    pub text: String,
    /// `text` is a snippet, not plain text.
    pub snippet: bool,
    pub detail: String,
    /// Bytes before the anchor that this candidate also replaces: a file
    /// name holds more than the word at the caret.
    pub back: usize,
    /// Other edits made with it, such as an `#include` the name needs:
    /// zero-based lines and byte columns of the start and end, and the text.
    pub edits: Vec<Extra>,
    /// Who gave it, filled in on arrival.
    pub source: u64,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Extra {
    pub from: (usize, usize),
    pub to: (usize, usize),
    pub text: String,
}
impl Item {
    pub fn plain(label: impl Into<String>, detail: impl Into<String>, back: usize) -> Self {
        let label = label.into();
        Self {
            filter: label.clone(),
            text: label.clone(),
            label,
            snippet: false,
            detail: detail.into(),
            back,
            edits: vec![],
            source: BUILTIN,
        }
    }
}

/// The built-in sources, among the sources a request names.
pub const BUILTIN: u64 = 0;
/// A source of candidates registered from Lua.
struct Source {
    id: u64,
    triggers: Vec<char>,
}
/// Who to ask about a position.
pub struct Asked {
    pub generation: u64,
    /// Run the built-in sources.
    pub builtin: bool,
    /// Lua sources.
    pub sources: Vec<u64>,
    pub view: ViewId,
    pub prefix: String,
    /// The character that started this, outside a word.
    pub trigger: Option<char>,
    pub language: String,
    /// One-based, as Lua counts.
    pub line: usize,
    pub column: usize,
}

/// What sources need to answer, taken on the owner thread.
pub struct Request {
    pub asked: Asked,
    pub snapshot: Snapshot,
    pub caret: usize,
    /// The word at the caret, which is not a candidate for itself.
    pub word: std::ops::Range<usize>,
    pub others: Vec<Snapshot>,
    pub directory: Option<Directory>,
}
/// A path at the caret: where to list, and how much of it names a file.
pub struct Directory {
    pub path: PathBuf,
    pub back: usize,
}

pub struct Row {
    pub label: String,
    pub detail: String,
    /// The ranges of `label` that match what is typed.
    pub matched: Vec<std::ops::Range<usize>>,
    pub selected: bool,
}
pub struct Popup {
    pub rows: Vec<Row>,
    /// Bytes from the anchor to the caret, to place the list under the word.
    pub typed: usize,
}

struct Session {
    view: ViewId,
    start: DocumentPosition,
    query: String,
    items: Vec<Item>,
    /// Indices into `items`, best first.
    matches: Vec<usize>,
    /// Into `matches`; none until the user chooses, so Enter stays Enter.
    selected: Option<usize>,
    top: usize,
    /// The latest question to each source; other answers are stale.
    asked: Vec<(u64, u64)>,
    /// Sources to ask again when the prefix changes.
    incomplete: Vec<u64>,
    /// Sources whose earlier answer goes when their next one comes.
    replacing: Vec<u64>,
}

pub struct State {
    session: Option<Session>,
    generation: u64,
    /// Text was typed since the last sync.
    pub(super) typed: bool,
    manual: bool,
    /// The start of a word the user closed the list on.
    dismissed: Option<usize>,
    sources: Vec<Source>,
    matcher: Matcher,
}
impl Default for State {
    fn default() -> Self {
        Self {
            session: None,
            generation: 0,
            typed: false,
            manual: false,
            dismissed: None,
            sources: vec![],
            matcher: Matcher::new(Config::DEFAULT),
        }
    }
}

pub fn is_word(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}
fn word_start(text: &str, caret: usize) -> usize {
    text[..caret]
        .char_indices()
        .rev()
        .take_while(|(_, ch)| is_word(*ch))
        .last()
        .map_or(caret, |(at, _)| at)
}
fn word_end(text: &str, caret: usize) -> usize {
    text[caret..]
        .char_indices()
        .find(|(_, ch)| !is_word(*ch))
        .map_or(text.len(), |(at, _)| caret + at)
}
/// The path being typed before `caret`, when it has a directory part.
fn directory(text: &str, caret: usize, base: &Path) -> Option<Directory> {
    let start = text[..caret]
        .rfind(|ch: char| ch.is_whitespace() || "\"'`<>(){}[],;=".contains(ch))
        .map_or(0, |at| {
            at + text[at..].chars().next().map_or(1, char::len_utf8)
        });
    let token = &text[start..caret];
    if token.starts_with("//") {
        return None;
    }
    let slash = token.rfind('/')?;
    let written = &token[..=slash];
    let path = match written.strip_prefix("~/") {
        Some(rest) => PathBuf::from(std::env::var_os("HOME")?).join(rest),
        None => base.join(written),
    };
    Some(Directory {
        path,
        back: token.len() - slash - 1,
    })
}

impl State {
    pub(super) fn visible(&self) -> bool {
        self.session.as_ref().is_some_and(Session::shown)
    }
    pub(super) fn selected(&self) -> bool {
        self.session.as_ref().is_some_and(|s| s.selected.is_some())
    }
    pub(super) fn register(&mut self, id: u64, triggers: Vec<char>) {
        self.sources.push(Source { id, triggers });
    }
    pub(super) fn trigger(&mut self) {
        self.manual = true;
    }
    /// Closes the list until the caret leaves the word.
    pub(super) fn dismiss(&mut self, app: &Application) {
        self.session = None;
        if let Some((snapshot, caret)) = at_caret(app) {
            self.dismissed = Some(word_start(snapshot.text(), caret));
        }
    }
    pub(super) fn observe(&mut self, update: &crate::application::Update) {
        let Some(edit) = update.edit.as_ref().and_then(|edit| edit.document.as_ref()) else {
            return;
        };
        if let Some(session) = &mut self.session
            && session.start.document_id == edit.document_id
        {
            match session.start.map(edit, false) {
                Ok(Some(start)) => session.start = start,
                _ => self.session = None,
            }
        }
    }
    /// Brings the session in line with the caret; returns a request for
    /// sources if one starts, and whether what is shown may have changed.
    pub(super) fn sync(
        &mut self,
        app: &Application,
        mode: EditMode,
        blocked: bool,
    ) -> (Option<Request>, bool) {
        let typed = std::mem::take(&mut self.typed);
        let manual = std::mem::take(&mut self.manual);
        let shown = self.visible();
        let current = (mode == EditMode::Insert && !blocked)
            .then(|| at_caret(app))
            .flatten();
        let Some((snapshot, caret)) = current else {
            self.session = None;
            self.dismissed = None;
            return (None, shown);
        };
        let text = snapshot.text();
        let start = word_start(text, caret);
        if self.dismissed.is_some_and(|word| word != start) {
            self.dismissed = None;
        }
        if let Some(session) = &self.session {
            let offset = session.start.offset.0;
            if Some(session.view) != app.active_view()
                || offset > caret
                || !text[offset..caret].chars().all(is_word)
            {
                self.session = None;
            } else {
                let query = text[offset..caret].to_owned();
                let changed = self.session.as_ref().unwrap().query != query;
                self.filter(query.clone(), text, caret);
                let session = self.session.as_mut().unwrap();
                if !changed || session.incomplete.is_empty() {
                    return (None, true);
                }
                self.generation += 1;
                let session = self.session.as_mut().unwrap();
                let sources = std::mem::take(&mut session.incomplete);
                for source in &sources {
                    session.asked.retain(|(asked, _)| asked != source);
                    session.asked.push((*source, self.generation));
                }
                session.replacing.extend(&sources);
                let asked = self.asked(app, sources, false, query, None, caret, &snapshot);
                let request = Request {
                    asked,
                    word: offset..word_end(text, caret),
                    caret,
                    snapshot: snapshot.clone(),
                    others: vec![],
                    directory: None,
                };
                return (Some(request), true);
            }
        }
        if !typed && !manual {
            return (None, shown);
        }
        let view = app.view(app.active_view().unwrap()).unwrap();
        let document = view.document_id;
        let options = app.options();
        let workspace = app.workspace();
        let directory = directory(text, caret, &app.directory_of(document));
        let long_enough =
            caret - start >= options.int(Some(document), "completion-min-prefix") as usize;
        let after_slash = directory.as_ref().is_some_and(|d| d.back == 0);
        let trigger = text[..caret]
            .chars()
            .next_back()
            .filter(|ch| self.sources.iter().any(|s| s.triggers.contains(ch)));
        let wanted = options.bool(Some(document), "completion")
            && self.dismissed.is_none()
            && (long_enough || after_slash || trigger.is_some());
        if !manual && !wanted {
            return (None, shown);
        }
        let editor = workspace.editor(document).unwrap();
        let Ok(anchor) = editor
            .model()
            .document()
            .position(ByteOffset(start), Association::Before)
        else {
            return (None, shown);
        };
        self.generation += 1;
        self.dismissed = None;
        self.session = Some(Session {
            view: view.id,
            start: anchor,
            query: text[start..caret].to_owned(),
            items: vec![],
            matches: vec![],
            selected: None,
            top: 0,
            asked: vec![],
            incomplete: vec![],
            replacing: vec![],
        });
        let others = workspace
            .documents()
            .filter(|other| *other != document)
            .filter_map(|other| {
                Some(
                    workspace
                        .editor(other)?
                        .model()
                        .document()
                        .snapshot()
                        .clone(),
                )
            })
            .collect();
        // A character that starts a member list says what is wanted: words
        // are no answer, nor are sources that do not take it.
        let by_trigger = trigger.filter(|_| !manual);
        let sources: Vec<u64> = self
            .sources
            .iter()
            .filter(|s| by_trigger.is_none_or(|ch| s.triggers.contains(&ch)))
            .map(|s| s.id)
            .collect();
        let builtin = by_trigger.is_none() || after_slash;
        let session = self.session.as_mut().unwrap();
        session.asked = sources.iter().map(|id| (*id, self.generation)).collect();
        if builtin {
            session.asked.push((BUILTIN, self.generation));
        }
        let prefix = text[start..caret].to_owned();
        let asked = self.asked(app, sources, builtin, prefix, by_trigger, caret, &snapshot);
        let request = Request {
            asked,
            word: start..word_end(text, caret),
            caret,
            snapshot: snapshot.clone(),
            others,
            directory,
        };
        (Some(request), shown)
    }
    #[allow(clippy::too_many_arguments)]
    fn asked(
        &self,
        app: &Application,
        sources: Vec<u64>,
        builtin: bool,
        prefix: String,
        trigger: Option<char>,
        caret: usize,
        snapshot: &Snapshot,
    ) -> Asked {
        let view = app.view(app.active_view().unwrap()).unwrap();
        let editor = app.workspace().editor(view.document_id).unwrap();
        let line = snapshot.line_of(caret).unwrap_or(0);
        let start = snapshot.line_start(line).unwrap_or(0);
        Asked {
            generation: self.generation,
            builtin,
            sources,
            view: view.id,
            prefix,
            trigger,
            language: editor.model().document().language().profile().id.clone(),
            line: line + 1,
            column: caret - start + 1,
        }
    }
    /// Takes what a source found; a stale answer is dropped.
    pub(super) fn results(
        &mut self,
        generation: u64,
        source: u64,
        items: Vec<Item>,
        incomplete: bool,
        app: &Application,
    ) -> bool {
        let current = self
            .session
            .as_ref()
            .is_some_and(|s| s.asked.contains(&(source, generation)));
        if !current {
            return false;
        }
        let Some((snapshot, caret)) = at_caret(app) else {
            return false;
        };
        let session = self.session.as_mut().unwrap();
        if session.replacing.contains(&source) {
            session.replacing.retain(|replacing| *replacing != source);
            session.items.retain(|item| item.source != source);
        }
        if incomplete && !session.incomplete.contains(&source) {
            session.incomplete.push(source);
        }
        session
            .items
            .extend(items.into_iter().map(|item| Item { source, ..item }));
        let query = std::mem::take(&mut session.query);
        session.matches.clear();
        self.filter(query, snapshot.text(), caret);
        true
    }
    fn filter(&mut self, query: String, text: &str, caret: usize) {
        let Some(session) = &mut self.session else {
            return;
        };
        let chosen = session
            .selected
            .and_then(|at| session.matches.get(at))
            .map(|index| session.items[*index].label.clone());
        // One more letter can only remove matches.
        let narrowing = query.starts_with(&session.query)
            && !session.matches.is_empty()
            && query != session.query;
        if query == session.query && !session.matches.is_empty() {
            return;
        }
        let pool: Vec<usize> = if narrowing {
            std::mem::take(&mut session.matches)
        } else {
            (0..session.items.len()).collect()
        };
        let offset = session.start.offset.0;
        let atom = |typed: &str| {
            Atom::new(
                typed,
                CaseMatching::Smart,
                Normalization::Smart,
                AtomKind::Fuzzy,
                false,
            )
        };
        let mut atoms: Vec<(usize, Atom)> = vec![];
        let mut chars = vec![];
        let mut ranked: Vec<(bool, bool, u16, usize)> = vec![];
        for index in pool {
            let item = &session.items[index];
            let Some(from) = offset.checked_sub(item.back) else {
                continue;
            };
            let typed = text.get(from..caret).unwrap_or(&query);
            if !atoms.iter().any(|(back, _)| *back == item.back) {
                atoms.push((item.back, atom(typed)));
            }
            let (_, pattern) = atoms.iter().find(|(back, _)| *back == item.back).unwrap();
            let score = if typed.is_empty() {
                Some(0)
            } else {
                pattern.score(Utf32Str::new(&item.filter, &mut chars), &mut self.matcher)
            };
            if let Some(score) = score {
                let prefix = item.filter.starts_with(typed);
                ranked.push((!prefix, item.source == BUILTIN, u16::MAX - score, index));
            }
        }
        // Sources give the nearest first; that order breaks ties.
        ranked.sort_unstable();
        session.matches = ranked.into_iter().map(|(.., index)| index).collect();
        session.query = query;
        session.selected = chosen.map(|label| {
            let items = &session.items;
            session
                .matches
                .iter()
                .position(|index| items[*index].label == label)
                .unwrap_or(0)
        });
        session.top = 0;
        session.follow();
    }
    pub(super) fn step(&mut self, backward: bool) {
        let Some(session) = &mut self.session else {
            return;
        };
        let count = session.matches.len();
        if count == 0 {
            return;
        }
        session.selected = Some(match (session.selected, backward) {
            (None, false) => 0,
            (None, true) => count - 1,
            (Some(at), false) => (at + 1) % count,
            (Some(at), true) => (at + count - 1) % count,
        });
        session.follow();
    }
    /// What accepting a candidate replaces, and with what.
    pub(super) fn accept(&mut self, replace: bool, app: &Application) -> Option<Accepted> {
        let (snapshot, caret) = at_caret(app)?;
        let session = self.session.take()?;
        let at = session.selected.or(replace.then_some(0))?;
        let item = session.items.get(*session.matches.get(at)?)?;
        let text = snapshot.text();
        let from = session.start.offset.0.checked_sub(item.back)?;
        let to = if replace {
            word_end(text, caret)
        } else {
            caret
        };
        let range = from..to;
        Some(Accepted {
            view: session.view,
            edits: extra_changes(&snapshot, &item.edits, &range),
            range,
            caret,
            text: item.text.clone(),
            snippet: item.snippet,
        })
    }
    pub(super) fn popup(&self) -> Option<Popup> {
        let session = self.session.as_ref().filter(|s| s.shown())?;
        let mut matcher = Matcher::new(Config::DEFAULT);
        let rows = session
            .matches
            .iter()
            .enumerate()
            .skip(session.top)
            .take(PAGE)
            .map(|(at, index)| {
                let item = &session.items[*index];
                let matched = fuzzy_match(&mut matcher, &session.query, &item.label)
                    .map_or(vec![], |(_, ranges)| ranges);
                Row {
                    label: item.label.clone(),
                    detail: item.detail.clone(),
                    matched,
                    selected: session.selected == Some(at),
                }
            })
            .collect();
        Some(Popup {
            rows,
            typed: session.query.len(),
        })
    }
}
impl Session {
    /// Nothing to show, or the only match is what is already typed.
    fn shown(&self) -> bool {
        match self.matches.as_slice() {
            [] => false,
            [only] => self.items[*only].label != self.query,
            _ => true,
        }
    }
    fn follow(&mut self) {
        if let Some(at) = self.selected {
            if at < self.top {
                self.top = at;
            } else if at >= self.top + PAGE {
                self.top = at + 1 - PAGE;
            }
        }
    }
}
/// The other edits of a candidate in bytes of the document as it is now;
/// none when any of them is out of the document or meets the replaced range.
fn extra_changes(
    snapshot: &Snapshot,
    edits: &[Extra],
    range: &std::ops::Range<usize>,
) -> Vec<crate::core::Change> {
    let offset = |(line, column): (usize, usize)| {
        let start = snapshot.line_start(line)?;
        let at = start + column;
        (at <= snapshot.len_bytes() && snapshot.is_char_boundary(at)).then_some(at)
    };
    let mut changes = vec![];
    for edit in edits {
        let (Some(from), Some(to)) = (offset(edit.from), offset(edit.to)) else {
            return vec![];
        };
        if from > to || (from < range.end && to > range.start) || from == range.start {
            return vec![];
        }
        changes.push(crate::core::Change::new(from..to, edit.text.clone()));
    }
    changes
}
/// A candidate on its way into the document.
pub(super) struct Accepted {
    pub view: ViewId,
    /// Changes beside the replaced range, made in the same step.
    pub edits: Vec<crate::core::Change>,
    pub range: std::ops::Range<usize>,
    pub caret: usize,
    pub text: String,
    pub snippet: bool,
}
fn at_caret(app: &Application) -> Option<(Snapshot, usize)> {
    let view = app.view(app.active_view()?)?;
    let editor = app.workspace().editor(view.document_id)?;
    let selection = editor.model().session(view.session_id)?.selection();
    selection
        .range()
        .is_empty()
        .then(|| (editor.model().document().snapshot().clone(), selection.head))
}
