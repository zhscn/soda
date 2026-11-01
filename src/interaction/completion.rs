//! Completion in Insert mode, modelled on an input method: the text being
//! composed is real text between an anchor and the caret, and everything
//! else follows from those two. Any move or edit that keeps the caret in one
//! word keeps the session; there are no key-by-key rules. Candidates stay
//! out of the document until one is accepted. See `docs/completion.md`.
use crate::{
    application::{Application, ViewId},
    core::{Association, ByteOffset, Change, Selection, Snapshot, Transaction},
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
    pub text: String,
    pub detail: &'static str,
    /// Bytes before the anchor that this candidate also replaces: a file
    /// name holds more than the word at the caret.
    pub back: usize,
}

/// What sources need to answer, taken on the owner thread.
pub struct Request {
    pub generation: u64,
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
    pub detail: &'static str,
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
}

pub struct State {
    session: Option<Session>,
    generation: u64,
    /// Text was typed since the last sync.
    pub(super) typed: bool,
    manual: bool,
    /// The start of a word the user closed the list on.
    dismissed: Option<usize>,
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
        file_root: &Path,
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
                self.filter(query, text, caret);
                return (None, true);
            }
        }
        if !typed && !manual {
            return (None, shown);
        }
        let view = app.view(app.active_view().unwrap()).unwrap();
        let document = view.document_id;
        let options = app.options();
        let workspace = app.workspace();
        let base = workspace
            .file(document)
            .and_then(|file| file.path())
            .and_then(Path::parent)
            .unwrap_or(file_root);
        let directory = directory(text, caret, base);
        let long_enough =
            caret - start >= options.int(Some(document), "completion-min-prefix") as usize;
        let after_slash = directory.as_ref().is_some_and(|d| d.back == 0);
        let wanted = options.bool(Some(document), "completion")
            && self.dismissed.is_none()
            && (long_enough || after_slash);
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
        let request = Request {
            generation: self.generation,
            word: start..word_end(text, caret),
            caret,
            snapshot: snapshot.clone(),
            others,
            directory,
        };
        (Some(request), shown)
    }
    /// Takes what sources found; a stale answer is dropped.
    pub(super) fn results(&mut self, generation: u64, items: Vec<Item>, app: &Application) -> bool {
        if generation != self.generation || self.session.is_none() {
            return false;
        }
        let Some((snapshot, caret)) = at_caret(app) else {
            return false;
        };
        let session = self.session.as_mut().unwrap();
        session.items.extend(items);
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
            .and_then(|at| session.matches.get(at).copied());
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
        let mut ranked: Vec<(bool, u16, usize)> = vec![];
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
                pattern.score(Utf32Str::new(&item.label, &mut chars), &mut self.matcher)
            };
            if let Some(score) = score {
                ranked.push((item.label.starts_with(typed), score, index));
            }
        }
        // Sources give the nearest first; that order breaks ties.
        ranked.sort_by_key(|(prefix, score, index)| (!prefix, u16::MAX - score, *index));
        session.matches = ranked.into_iter().map(|(.., index)| index).collect();
        session.query = query;
        session.selected = chosen.map(|item| {
            session
                .matches
                .iter()
                .position(|index| *index == item)
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
    /// The edit that accepts a candidate, and the keys that would have
    /// typed it, for `.` and macros: their replays do not complete.
    pub(super) fn accept(
        &mut self,
        replace: bool,
        app: &Application,
    ) -> Option<(ViewId, Transaction, Replayed)> {
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
        let replay = Replayed {
            before: text[from..caret].chars().count(),
            after: text[caret..to].chars().count(),
            text: item.text.clone(),
        };
        let mut tx = Transaction::new(
            snapshot.version(),
            vec![Change::new(from..to, item.text.clone())],
        );
        tx.selection = Some(Selection::caret(from + item.text.len()));
        Some((session.view, tx, replay))
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
                    detail: item.detail,
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
/// What a replay types instead of choosing from a list.
pub(super) struct Replayed {
    pub before: usize,
    pub after: usize,
    pub text: String,
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
