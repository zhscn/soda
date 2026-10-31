//! Jump history for `<c-o>` and `<c-i>`, one list for the session, as a
//! browser's: going back and then jumping elsewhere drops what lay ahead, so
//! the list follows the path taken through searches and definitions.
//!
//! Places are the caret in files; results and other scratch documents are
//! not, so a list shown on the way does not become a stop. Changing document
//! always counts, however it happened. Moves within a document count when
//! a command said it jumps, and walking through results counts once, for
//! the place the walk started from.
use crate::{
    application::{Application, Update},
    core::{Association, ByteOffset},
    editor::{DocumentId, DocumentPosition},
};

/// Places kept; older ones drop.
const LIMIT: usize = 100;

/// What the next move of the caret means.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum Pending {
    #[default]
    Nothing,
    Record,
    /// The history itself, or a later step through results.
    Skip,
}
#[derive(Default)]
pub(super) struct Jumps {
    places: Vec<DocumentPosition>,
    /// The place in `places` the caret came from; its length at the tip.
    current: usize,
    /// Where the caret last was in a file.
    last: Option<DocumentPosition>,
    pending: Pending,
    /// The last jump stepped through results.
    walking: bool,
}
/// The caret of the active view, in a file.
fn place(app: &Application) -> Option<DocumentPosition> {
    let view = app.view(app.active_view()?)?;
    let file = app.workspace().file(view.document_id)?;
    if file.scratch().is_some() {
        return None;
    }
    let editor = app.workspace().editor(view.document_id)?;
    let head = editor.model().session(view.session_id)?.selection().head;
    let document = editor.model().document();
    document
        .position(ByteOffset(head), Association::Before)
        .ok()
}
fn line(app: &Application, place: &DocumentPosition) -> Option<(DocumentId, usize)> {
    let editor = app.workspace().editor(place.document_id)?;
    let snapshot = editor.model().document().snapshot();
    Some((place.document_id, snapshot.line_of(place.offset.0)?))
}
impl Jumps {
    /// A command starts: forgets what an earlier one left unfinished.
    pub fn clear_pending(&mut self) {
        self.pending = Pending::Nothing;
    }
    /// The command about to run jumps.
    pub fn expect(&mut self) {
        self.pending = Pending::Record;
        self.walking = false;
    }
    /// The command about to run opens a result. Only the first in a row
    /// counts, so one step back leaves the results.
    pub fn expect_result(&mut self) {
        self.pending = if self.walking {
            Pending::Skip
        } else {
            Pending::Record
        };
        self.walking = true;
    }
    /// New results start a walk of their own.
    pub fn end_walk(&mut self) {
        self.walking = false;
    }
    fn push(&mut self, app: &Application, place: DocumentPosition) {
        self.places.truncate(self.current);
        if self.places.last().and_then(|last| line(app, last)) != line(app, &place) {
            if self.places.len() == LIMIT {
                self.places.remove(0);
            }
            self.places.push(place);
        }
        self.current = self.places.len();
    }
    /// The caret moved during a search, which `observe` left alone.
    pub fn searched(&mut self, app: &Application) {
        self.pending = Pending::Record;
        self.walking = false;
        self.settle(app);
    }
    fn settle(&mut self, app: &Application) {
        let here = place(app);
        if let (Some(from), Some(to)) = (self.last, here) {
            let changed = from.document_id != to.document_id;
            if changed || from.offset != to.offset {
                let pending = std::mem::take(&mut self.pending);
                if pending == Pending::Record || (pending == Pending::Nothing && changed) {
                    self.walking &= pending == Pending::Record;
                    self.push(app, from);
                }
            }
        }
        if here.is_some() {
            self.last = here;
        }
    }
    /// Follows edits and closed documents, then records what moved. While
    /// `searching`, the caret shows matches and has not gone anywhere yet.
    pub fn observe(&mut self, app: &Application, update: &Update, searching: bool) {
        let closed =
            |place: &DocumentPosition| update.closed_documents.contains(&place.document_id);
        let before = self.places.iter().take(self.current).filter(|p| closed(p));
        self.current -= before.count();
        self.places.retain(|place| !closed(place));
        self.last = self.last.filter(|place| !closed(place));
        if let Some(edit) = update.edit.as_ref().and_then(|edit| edit.document.as_ref()) {
            let follow = |place: &mut DocumentPosition| {
                if place.document_id == edit.document_id
                    && let Ok(Some(mapped)) = place.map(edit, false)
                {
                    *place = mapped;
                }
            };
            self.places.iter_mut().for_each(follow);
            self.last.iter_mut().for_each(follow);
        }
        if !searching {
            self.settle(app);
        }
    }
    /// The older place to go to, leaving the current one reachable forward.
    pub fn back(&mut self, app: &Application) -> Option<DocumentPosition> {
        let here = place(app).or(self.last);
        if self.current == self.places.len()
            && let Some(here) = here
        {
            self.push(app, here);
            self.current = self.current.saturating_sub(1);
        }
        let line_here = here.and_then(|here| line(app, &here));
        while self.current > 0 {
            self.current -= 1;
            let target = self.places[self.current];
            if line(app, &target) != line_here {
                self.pending = Pending::Skip;
                self.walking = false;
                return Some(target);
            }
        }
        None
    }
    /// The newer place to go to, after going back.
    pub fn forward(&mut self) -> Option<DocumentPosition> {
        if self.current + 1 >= self.places.len() {
            return None;
        }
        self.current += 1;
        self.pending = Pending::Skip;
        self.walking = false;
        Some(self.places[self.current])
    }
}
