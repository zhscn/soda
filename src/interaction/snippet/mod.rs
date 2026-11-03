//! Snippets: text with places to fill in, in the LSP syntax. Unlike
//! completion, a snippet goes on after its text is in the document: the
//! session holds where each place is, follows every edit, and ends when the
//! caret leaves or the last place is reached.
//!
//! A number used more than once has one place to fill in, its first with a
//! default; the others are mirrors, which copy what it holds as it is typed,
//! changed by a regular expression if they have one. Variables take their
//! value; unknown ones become places holding their name. A snippet expanded
//! in another's place stacks on it, and the outer goes on once it ends.
use crate::{
    application::{Application, Event, PaintSpan, ViewId},
    core::{Association, Change, Selection, Snapshot, Transaction},
    editor::{Command as EditCommand, DocumentId, DocumentUpdate},
};
use std::{ops::Range, time::Duration};

mod syntax;
mod variables;
pub use syntax::{Mirror, Parsed, Stop, Transform, parse, parse_with};
pub(super) use variables::variables;

/// Text just expanded, waiting for its update to become a session.
pub(super) struct Pending {
    pub view: ViewId,
    pub document: DocumentId,
    pub offset: usize,
    pub stops: Vec<Stop>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Span {
    start: usize,
    end: usize,
    order: usize,
}
impl Span {
    fn new(range: &Range<usize>, offset: usize, order: usize) -> Self {
        Self {
            start: offset + range.start,
            end: offset + range.end,
            order,
        }
    }
    fn range(self) -> Range<usize> {
        self.start..self.end
    }
    fn is_empty(self) -> bool {
        self.start == self.end
    }
    /// The place being filled takes what is typed at either edge.
    fn grow(&mut self, edit: &DocumentUpdate) {
        self.start = edit.mapping.map(self.start, Association::Before);
        self.end = edit
            .mapping
            .map(self.end, Association::After)
            .max(self.start);
    }
    /// Other places keep what is typed at their edges out. An empty one
    /// stays on its side of the place being filled; one an edit replaces
    /// exactly holds what replaced it. Returns whether a larger edit took
    /// all of it.
    fn keep(&mut self, edit: &DocumentUpdate, active: usize, ours: bool) -> bool {
        let range = self.range();
        if (ours || !self.is_empty())
            && let Some(change) = edit.changes.iter().find(|change| change.range == range)
        {
            self.start = edit.mapping.map(self.start, Association::Before);
            self.end = self.start + change.insert.len();
            return false;
        }
        let swallowed = !self.is_empty()
            && edit
                .changes
                .iter()
                .any(|change| change.range.start <= self.start && self.end <= change.range.end);
        if self.is_empty() {
            let side = if self.order < active {
                Association::Before
            } else {
                Association::After
            };
            self.start = edit.mapping.map(self.start, side);
            self.end = self.start;
        } else {
            self.start = edit.mapping.map(self.start, Association::After);
            self.end = edit
                .mapping
                .map(self.end, Association::Before)
                .max(self.start);
        }
        swallowed
    }
}
struct Field {
    place: Span,
    mirrors: Vec<(Span, Option<Transform>)>,
    choices: Vec<String>,
    /// An edit took the place with its surroundings: Tab passes it.
    gone: bool,
}
pub(super) struct Session {
    view: ViewId,
    document: DocumentId,
    revision: u64,
    fields: Vec<Field>,
    /// The field being filled.
    at: usize,
    bounds: Span,
}
/// Choices of a place, for the list of candidates.
pub(super) struct Offer {
    pub view: ViewId,
    pub place: Range<usize>,
    pub choices: Vec<String>,
}
#[derive(Default)]
pub(super) struct State {
    pub pending: Option<Pending>,
    /// Innermost last.
    sessions: Vec<Session>,
    /// The revision mirrors were last brought in line from.
    syncing: Option<(DocumentId, u64)>,
    offer: Option<Offer>,
    /// The document and spans last painted.
    painted: Option<(DocumentId, Vec<Range<usize>>)>,
}
impl State {
    pub fn active(&self) -> bool {
        !self.sessions.is_empty()
    }
    pub fn take_offer(&mut self) -> Option<Offer> {
        self.offer.take()
    }
    /// Follows an edit; brings mirrors in line with their places by an
    /// edit to make.
    pub fn observe(
        &mut self,
        app: &Application,
        update: &crate::application::Update,
        time: Duration,
    ) -> Option<Event> {
        let edit = update.edit.as_ref()?.document.as_ref()?;
        let ours = self.syncing.take() == Some((edit.document_id, edit.before_revision));
        self.sessions
            .retain_mut(|session| session.document != edit.document_id || session.map(edit, ours));
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.document == edit.document_id)
        {
            let pending = self.pending.take().unwrap();
            if let Some(session) = Session::new(pending, edit.after_revision) {
                self.offer = session.offer();
                self.sessions.push(session);
            }
        }
        let document = app.workspace().editor(edit.document_id)?.model().document();
        let snapshot = document.snapshot();
        for session in self.sessions.iter().rev() {
            if session.document != edit.document_id || app.view(session.view).is_none() {
                continue;
            }
            let changes = session.mirrored(snapshot.text());
            if !changes.is_empty() {
                self.syncing = Some((edit.document_id, snapshot.version()));
                return Some(Event::Edit {
                    view: session.view,
                    command: EditCommand::Apply(Transaction::new(snapshot.version(), changes)),
                    time,
                });
            }
        }
        None
    }
    /// Ends the snippets the caret is out of.
    pub fn sync(&mut self, app: &Application, editing: bool) {
        let caret = (|| {
            let view = app.view(app.active_view()?)?;
            let editor = app.workspace().editor(view.document_id)?;
            let selection = editor.model().session(view.session_id)?.selection();
            Some((view.id, selection.range()))
        })();
        while let Some(session) = self.sessions.last() {
            let inside = editing
                && caret.as_ref().is_some_and(|(view, range)| {
                    *view == session.view
                        && session.bounds.start <= range.start
                        && range.end <= session.bounds.end
                });
            if inside {
                break;
            }
            self.sessions.pop();
        }
    }
    /// The selection of the next or previous place; reaching the last ends
    /// the snippet, and the one it is in goes on.
    pub fn step(&mut self, backward: bool) -> Option<(ViewId, Selection)> {
        let session = self.sessions.last_mut()?;
        let last = session.fields.len() - 1;
        let at = if backward {
            (0..session.at)
                .rev()
                .find(|at| !session.fields[*at].gone)
                .unwrap_or(session.at)
        } else {
            (session.at + 1..=last)
                .find(|at| *at == last || !session.fields[*at].gone)
                .unwrap_or(last)
        };
        session.at = at;
        let place = session.fields[at].place;
        let selection = Selection {
            anchor: place.start,
            head: place.end,
        };
        let view = session.view;
        if at == last {
            self.sessions.pop();
        } else {
            self.offer = session.offer();
        }
        Some((view, selection))
    }
    /// What to paint for the innermost snippet: the places not being
    /// filled, and mirrors. An event when that changed.
    pub fn paint(&mut self, app: &Application) -> Vec<Event> {
        let wanted = self.sessions.last().map(|session| {
            let mut spans = vec![];
            for (at, field) in session.fields.iter().enumerate() {
                if at != session.at && !field.gone {
                    spans.push(field.place.range());
                }
                spans.extend(field.mirrors.iter().map(|(span, _)| span.range()));
            }
            spans.retain(|span| !span.is_empty());
            spans.sort_by_key(|span| span.start);
            (session.document, spans)
        });
        if wanted == self.painted {
            return vec![];
        }
        let mut events = vec![];
        if let Some((document, _)) = &self.painted
            && wanted.as_ref().is_none_or(|(other, _)| other != document)
        {
            events.push(Event::Paint {
                document: *document,
                group: "snippet".into(),
                paints: vec![],
            });
        }
        if let Some((document, spans)) = &wanted
            && let Some(editor) = app.workspace().editor(*document)
        {
            let snapshot = editor.model().document().snapshot();
            let face = crate::application::faces::index("snippet")
                .map(crate::application::Face::Named)
                .unwrap();
            events.push(Event::Paint {
                document: *document,
                group: "snippet".into(),
                paints: spans
                    .iter()
                    .filter_map(|span| {
                        Some(PaintSpan {
                            start: place(snapshot, span.start)?,
                            end: place(snapshot, span.end)?,
                            face,
                        })
                    })
                    .collect(),
            });
        }
        self.painted = wanted;
        events
    }
}
/// Zero-based line and byte in it.
fn place(snapshot: &Snapshot, offset: usize) -> Option<(usize, usize)> {
    let line = snapshot.line_of(offset)?;
    Some((line, offset - snapshot.line_start(line)?))
}
impl Session {
    fn new(pending: Pending, revision: u64) -> Option<Self> {
        if pending.stops.len() < 2 {
            return None;
        }
        let offset = pending.offset;
        let first = pending.stops.iter().map(|stop| stop.range.start).min()?;
        let last = pending.stops.iter().map(|stop| stop.range.end).max()?;
        let mirrors_end = pending
            .stops
            .iter()
            .flat_map(|stop| stop.mirrors.iter().map(|mirror| mirror.range.end))
            .max()
            .unwrap_or(0);
        let mirrors_start = pending
            .stops
            .iter()
            .flat_map(|stop| stop.mirrors.iter().map(|mirror| mirror.range.start))
            .min()
            .unwrap_or(first);
        let fields = pending
            .stops
            .into_iter()
            .map(|stop| Field {
                place: Span::new(&stop.range, offset, stop.order),
                mirrors: stop
                    .mirrors
                    .into_iter()
                    .map(|mirror| {
                        (
                            Span::new(&mirror.range, offset, mirror.order),
                            mirror.transform,
                        )
                    })
                    .collect(),
                choices: stop.choices,
                gone: false,
            })
            .collect();
        Some(Self {
            view: pending.view,
            document: pending.document,
            revision,
            fields,
            at: 0,
            bounds: Span {
                start: offset + first.min(mirrors_start),
                end: offset + last.max(mirrors_end),
                order: 0,
            },
        })
    }
    fn offer(&self) -> Option<Offer> {
        let field = &self.fields[self.at];
        (!field.choices.is_empty()).then(|| Offer {
            view: self.view,
            place: field.place.range(),
            choices: field.choices.clone(),
        })
    }
    fn map(&mut self, edit: &DocumentUpdate, ours: bool) -> bool {
        if edit.before_revision != self.revision {
            return false;
        }
        self.revision = edit.after_revision;
        let active = self.fields[self.at].place.order;
        for (at, field) in self.fields.iter_mut().enumerate() {
            if at == self.at {
                field.place.grow(edit);
            } else if field.place.keep(edit, active, ours) {
                field.gone = true;
            }
            for (mirror, _) in &mut field.mirrors {
                mirror.keep(edit, active, ours);
            }
        }
        self.bounds.grow(edit);
        true
    }
    /// The edits that make each mirror what its place holds.
    fn mirrored(&self, text: &str) -> Vec<Change> {
        let places: Vec<Range<usize>> = self
            .fields
            .iter()
            .filter(|field| !field.gone)
            .map(|field| field.place.range())
            .collect();
        let mut changes: Vec<Change> = vec![];
        for field in self.fields.iter().filter(|field| !field.gone) {
            let Some(held) = text.get(field.place.range()) else {
                continue;
            };
            for (mirror, transform) in &field.mirrors {
                let range = mirror.range();
                let wanted = transform
                    .as_ref()
                    .map_or(held.to_owned(), |t| t.apply(held));
                let overlaps = |other: &Range<usize>| {
                    other.start < range.end && range.start < other.end
                        || other.start == range.start && (other.is_empty() || range.is_empty())
                };
                if text.get(range.clone()) != Some(wanted.as_str()) && !places.iter().any(overlaps)
                {
                    changes.push(Change::new(range, wanted));
                }
            }
        }
        changes.sort_by_key(|change| change.range.start);
        let mut kept: Vec<Change> = vec![];
        for change in changes {
            if kept.last().is_none_or(|last| {
                last.range.end <= change.range.start && last.range.start != change.range.start
            }) {
                kept.push(change);
            }
        }
        kept
    }
}
