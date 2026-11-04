//! Beacon, as meow's: the grab is Emacs's secondary selection, and while
//! the caret is inside it the other places of what the main selection
//! covers show as fake carets and selections. Edits reach them by keyboard
//! macro: `i`, `a` and `s` record what is typed until Esc and play it at
//! each; a macro recorded in Beacon plays at each when it ends; `<f4>` in
//! Beacon plays the last one at the main selection and then at each.
//!
//! The session holds the main selection; the others are positions that
//! follow the text, derived again after each command from the kind of the
//! main one (`meow--beacon-update-overlays`).
use super::{
    Action, Entry, Grab, Kind,
    execute::{Place, place, position},
    text,
};
use crate::{
    application::ClipboardAction,
    application::{Application, Event},
    core::{Change, Selection, Transaction},
    editor::Command as Edit,
    interaction::{Command, EditMode, Layers, Response, UserInput},
};
use std::{ops::Range, time::Duration};

/// How Insert was entered from Beacon, to enter it the same way at each
/// other place when the typing is played there.
#[derive(Clone, Copy, Debug)]
pub(in crate::interaction) enum BeaconEntry {
    Insert(Entry),
    Change,
}
/// Keys to play at the other places, and how to enter Insert first.
#[derive(Clone, Debug)]
pub(in crate::interaction) struct BeaconPlay {
    pub entry: Option<BeaconEntry>,
    pub keys: Vec<UserInput>,
}
/// The shape of the other selections that are ranges: their kind, and
/// whether they run backward, as the main one did. Carets are carets.
#[derive(Clone, Copy, Debug, Default)]
pub(in crate::interaction) struct BeaconShape {
    pub kind: Option<(Kind, bool)>,
    pub backward: bool,
}

impl Layers {
    /// Whether commands act on more than the main selection.
    pub(super) fn beacon_active(&self) -> bool {
        self.mode == EditMode::Beacon && !self.modal.beacons.is_empty()
    }
    /// Back to Normal; the grab stays, for the caret to come back to.
    pub(in crate::interaction) fn leave_beacon(&mut self) {
        self.mode = EditMode::Normal;
        self.modal.beacons.clear();
    }
    /// The grab, as a range in the text of the active view; a marker,
    /// empty, shows nothing.
    pub fn grabbed(&self, app: &Application) -> Option<Range<usize>> {
        let at = place(app, Default::default())?;
        let grab = self.modal.grab?;
        let start = grab.start.resolve(at.document).ok()?.0;
        let end = grab.end.resolve(at.document).ok()?.0;
        (start < end).then_some(start..end)
    }
    /// After each command the user typed, as meow's
    /// `meow--maybe-toggle-beacon-state` on `post-command-hook`: the caret
    /// inside the grab is Beacon, outside it Normal, and in Beacon the
    /// other places are derived again. Some kinds leave carets at the other
    /// places and the main selection shrinks to its caret; the event for
    /// that is returned. Nothing changes while a macro is recorded, as meow
    /// skips while one is defined, nor while a layer such as search is
    /// open. The command loop calls it; see `command_loop`.
    pub(in crate::interaction) fn follow_grab(
        &mut self,
        app: &Application,
        time: Duration,
    ) -> Vec<Event> {
        if self.active.is_some()
            || self.modal.replay.recording()
            || !crate::interaction::modal_on(app)
            || !matches!(self.mode, EditMode::Normal | EditMode::Beacon)
        {
            return vec![];
        }
        let Some(at) = place(app, time) else {
            return vec![];
        };
        let head = at.selection.head;
        let Some(grab) = self
            .grabbed(app)
            .filter(|grab| grab.start <= head && head <= grab.end)
        else {
            if self.mode == EditMode::Beacon {
                self.leave_beacon();
            }
            return vec![];
        };
        self.mode = EditMode::Beacon;
        let (ranges, shape, shrink) = self.derived(&at, grab);
        self.modal.beacon_shape = shape;
        self.modal.beacons = ranges
            .into_iter()
            .filter_map(|range| {
                Some(Grab {
                    start: position(at.document, range.start)?,
                    end: position(at.document, range.end)?,
                })
            })
            .collect();
        if shrink && !at.selection.range().is_empty() {
            self.modal.tag = None;
            return vec![at.event(Edit::SetSelection(Selection::caret(head)))];
        }
        vec![]
    }
    /// The other selections, as ranges in the text.
    pub fn beacons(&self, app: &Application) -> Vec<Range<usize>> {
        let Some(at) = place(app, Default::default()) else {
            return vec![];
        };
        resolved(&self.modal.beacons, &at)
    }
    /// The other places, by the kind of the main selection, as
    /// `meow--beacon-update-overlays`; and whether the main selection
    /// shrinks to its caret, as it does where the others are carets.
    fn derived(&self, at: &Place, grab: Range<usize>) -> (Vec<Range<usize>>, BeaconShape, bool) {
        let text = at.text;
        let main = at.selection.range();
        let head = at.selection.head;
        let backward = at.selection.head < at.selection.anchor;
        let shape = |kind| BeaconShape {
            kind: Some(kind),
            backward,
        };
        let carets = |offsets: Vec<usize>| {
            let ranges = offsets
                .into_iter()
                .filter(|&offset| offset != head)
                .map(|offset| offset..offset)
                .collect();
            (ranges, BeaconShape::default(), true)
        };
        let lines = Lines::new(text, &grab);
        match self
            .modal
            .tag(at.selection)
            .map(|tag| (tag.kind, tag.expand))
        {
            // A caret, or a selection of no kind: carets in the same column,
            // counted in characters, of the other lines.
            None => {
                let column = char_column(text, head);
                let line = text.line_of(head).unwrap();
                let offsets = lines
                    .around(line)
                    .filter_map(|other| at_column(text, other, column))
                    .filter(|offset| grab.start <= *offset && *offset <= grab.end)
                    .collect();
                carets(offsets)
            }
            Some((Kind::Char, true)) => {
                let (from, to) = (char_column(text, main.start), char_column(text, main.end));
                let line = text.line_of(head).unwrap();
                let ranges = lines
                    .around(line)
                    .filter_map(|other| {
                        Some(at_column(text, other, from)?..at_column(text, other, to)?)
                    })
                    .filter(|range| grab.start <= range.start && range.end <= grab.end)
                    .collect();
                (ranges, shape((Kind::Char, true)), false)
            }
            Some((kind @ (Kind::Word | Kind::Symbol), false)) => {
                // A caret at the end of each word going forward, at the start
                // going backward.
                let symbol = kind == Kind::Symbol;
                let mut offsets = vec![];
                if backward {
                    let mut from = grab.end;
                    while let Some(start) = text::thing_start(text, from, symbol) {
                        if start < grab.start {
                            break;
                        }
                        offsets.push(start);
                        from = start;
                    }
                    offsets.reverse();
                } else {
                    let mut from = grab.start;
                    while let Some(end) = text::thing_end(text, from, symbol) {
                        if end > grab.end {
                            break;
                        }
                        offsets.push(end);
                        from = end;
                    }
                }
                carets(offsets)
            }
            Some((kind @ (Kind::Word | Kind::Symbol), true)) => {
                use crate::editor::search::SearchQuery;
                let selected = text.byte_slice(main.clone()).unwrap().to_string();
                let query = if kind == Kind::Symbol {
                    SearchQuery::symbol(selected)
                } else {
                    SearchQuery::word(selected)
                };
                let ranges = matches(at, &grab, &query, &main);
                (ranges, shape((Kind::Visit, false)), false)
            }
            Some((Kind::Visit, _)) => {
                let ranges = self
                    .modal
                    .search()
                    .map_or(vec![], |query| matches(at, &grab, query, &main));
                (ranges, shape((Kind::Visit, false)), false)
            }
            Some((Kind::Line, _)) => {
                // Groups of as many lines as the main selection has, below it
                // and above it.
                let (top, bottom) = (
                    text.line_of(main.start).unwrap(),
                    text.line_of(main.end).unwrap(),
                );
                let height = bottom - top + 1;
                let group = |line: usize| {
                    let start = text.line_start(line).unwrap().max(grab.start);
                    let end = text.line_content_range(line + height - 1).unwrap().end;
                    start..end.min(grab.end)
                };
                let mut ranges = vec![];
                let mut line = lines.first;
                while line + height <= top {
                    ranges.push(group(line));
                    line += height;
                }
                let mut line = bottom + 1;
                while line + height - 1 <= lines.last {
                    ranges.push(group(line));
                    line += height;
                }
                (ranges, shape((Kind::Line, true)), false)
            }
            Some((Kind::Join, _)) => {
                let offsets = (lines.first..=lines.last)
                    .map(|line| text::first(text, line).max(grab.start))
                    .collect();
                carets(offsets)
            }
            Some((kind @ (Kind::Find | Kind::Till), _)) => {
                let Some(find) = self.modal.last_find else {
                    return (vec![], BeaconShape::default(), false);
                };
                let width = find.ch.len_utf8();
                let mut offsets = vec![];
                let mut from = grab.start;
                while let Some(found) = text::find(text, from, find.ch, 1, false) {
                    if found + width > grab.end {
                        break;
                    }
                    // Past the character going forward, on it going back; a
                    // till stops short of it from either side.
                    offsets.push(match (kind == Kind::Till, backward) {
                        (false, false) => found + width,
                        (false, true) => found,
                        (true, false) => found,
                        (true, true) => found + width,
                    });
                    from = found + width;
                }
                carets(offsets)
            }
            Some(_) => (vec![], BeaconShape::default(), false),
        }
    }
    /// `i`, `a` and `s` in Beacon, as `meow-beacon-insert` and its kin: the
    /// main selection enters Insert alone and what is typed is recorded,
    /// to play at each other place when Esc ends it.
    pub(super) fn begin_beacon_insert(&mut self, entry: BeaconEntry) {
        self.modal.beacon_insert = Some(entry);
        self.modal.replay.start(None, false);
    }
    /// Esc after `begin_beacon_insert`: what was typed goes to the others.
    pub(super) fn end_beacon_insert(&mut self, entry: BeaconEntry, response: &mut Response) {
        // Nothing typed, or the recording dropped by `C-g`: nothing plays.
        if !self.modal.replay.stop() {
            return;
        }
        self.modal.play = Some(BeaconPlay {
            entry: Some(entry),
            keys: self.modal.replay.last().to_vec(),
        });
        response
            .commands
            .push(Command::Modal(Action::PlayAtBeacons));
    }
    /// `r` in Beacon, as `meow-beacon-kill-delete`: the main selection is
    /// killed, the other selections deleted; carets stay. One undo step.
    pub(super) fn beacon_kill(&mut self, at: &Place, response: &mut Response) {
        let tag = self.modal.tag(at.selection);
        self.modal.tag = None;
        let mut main = at.selection.range();
        // A forward line selection takes its line break with it.
        if tag.is_some_and(|tag| tag.kind == Kind::Line)
            && at.selection.head > at.selection.anchor
            && main.end < at.text.len_bytes()
        {
            main.end = text::next(at.text, main.end);
        }
        let mut others: Vec<_> = resolved(&self.modal.beacons, at)
            .into_iter()
            .filter(|range| {
                !range.is_empty() && (range.end <= main.start || range.start >= main.end)
            })
            .collect();
        others.sort_by_key(|range| range.start);
        others.dedup_by(|b, a| b.start < a.end);
        let depth = at.document.history_depth();
        let before: usize = others
            .iter()
            .filter(|range| range.end <= main.start)
            .map(Range::len)
            .sum();
        if !others.is_empty() {
            let changes = others
                .into_iter()
                .map(|range| Change::new(range, ""))
                .collect();
            let mut tx = Transaction::new(at.text.version(), changes);
            tx.selection = Some(Selection {
                anchor: at.selection.anchor - before,
                head: at.selection.head - before,
            });
            response.events.push(at.event(Edit::Apply(tx)));
        }
        let main = main.start - before..main.end - before;
        response.events.push(at.clipboard(ClipboardAction::Operate {
            range: main.clone(),
            edit: Change::new(main.clone(), ""),
            selection: Selection::caret(main.start),
        }));
        response.events.push(at.event(Edit::SquashHistory(depth)));
    }
    /// `<f4>` in Beacon, as `meow-beacon-apply-kmacro`: the last macro at the
    /// main selection, then at each other place.
    pub(super) fn beacon_call_macro(&mut self, count: usize, response: &mut Response) {
        let keys = self.modal.replay.last().to_vec();
        self.mode = EditMode::Normal;
        for _ in 0..count {
            response.commands.push(Command::Replay(keys.clone()));
        }
        self.modal.play = Some(BeaconPlay { entry: None, keys });
        response
            .commands
            .push(Command::Modal(Action::PlayAtBeacons));
    }
    /// A macro recorded in Beacon ends: it plays at each other place.
    pub(super) fn beacon_end_macro(&mut self, response: &mut Response) {
        self.modal.play = Some(BeaconPlay {
            entry: None,
            keys: self.modal.replay.last().to_vec(),
        });
        response
            .commands
            .push(Command::Modal(Action::PlayAtBeacons));
    }
    /// Plays the keys at each other place, last first so that earlier ones
    /// hold, as one undo step, as `meow--beacon-apply-command`. A caret is
    /// a caret; a selection has the shape the main one had.
    pub(super) fn play_at_beacons(&mut self, at: &Place, response: &mut Response) {
        let Some(play) = self.modal.play.take() else {
            return;
        };
        let shape = self.modal.beacon_shape;
        let targets = resolved(&self.modal.beacons, at);
        // The anchor goes in `start`, the head in `end`, whichever is first.
        self.modal.held = position(at.document, at.selection.anchor)
            .zip(position(at.document, at.selection.head))
            .map(|(start, end)| Grab { start, end });
        self.leave_beacon();
        for range in targets.into_iter().rev() {
            response.commands.push(Command::SetMode(EditMode::Normal));
            response.commands.push(match shape.kind {
                Some((kind, expand)) if !range.is_empty() => {
                    let (anchor, head) = if shape.backward {
                        (range.end, range.start)
                    } else {
                        (range.start, range.end)
                    };
                    Command::Modal(Action::Found {
                        anchor,
                        head,
                        kind,
                        expand,
                    })
                }
                _ => Command::Edit(Edit::SetSelection(Selection::caret(range.start))),
            });
            match play.entry {
                Some(BeaconEntry::Insert(entry)) => {
                    response
                        .commands
                        .push(Command::Modal(Action::Insert(entry)));
                }
                Some(BeaconEntry::Change) => {
                    response.commands.push(Command::Modal(Action::Change));
                }
                None => {}
            }
            response.commands.push(Command::Replay(play.keys.clone()));
            if play.entry.is_some() {
                response.commands.push(Command::Modal(Action::Leave));
            }
        }
        response.commands.extend([
            Command::SetMode(EditMode::Normal),
            Command::Edit(Edit::SquashHistory(at.document.history_depth())),
            Command::Modal(Action::ReturnFromBeacons),
        ]);
    }
    pub(super) fn return_from_beacons(&mut self, at: &Place, response: &mut Response) {
        let Some(held) = self.modal.held.take() else {
            return;
        };
        if let (Ok(anchor), Ok(head)) = (
            held.start.resolve(at.document),
            held.end.resolve(at.document),
        ) {
            response.events.push(at.event(Edit::SetSelection(Selection {
                anchor: anchor.0,
                head: head.0,
            })));
        }
    }
}
/// The lines a grab touches, and the order meow goes through them around
/// the caret's line: those below it, then those above.
struct Lines {
    first: usize,
    last: usize,
}
impl Lines {
    fn new(text: &crate::core::Snapshot, grab: &Range<usize>) -> Self {
        // A grab that ends at a line's start does not reach that line.
        let first = text.line_of(grab.start).unwrap();
        let last = text
            .line_of(grab.end.saturating_sub(1).max(grab.start))
            .unwrap();
        Self { first, last }
    }
    fn around(&self, line: usize) -> impl Iterator<Item = usize> {
        (line + 1..=self.last).chain(self.first..line.min(self.last + 1))
    }
}
/// The characters from the start of the line to `offset`.
fn char_column(text: &crate::core::Snapshot, offset: usize) -> usize {
    let line = text.line_of(offset).unwrap();
    let start = text.line_start(line).unwrap();
    text.byte_slice(start..offset)
        .unwrap()
        .to_string()
        .chars()
        .count()
}
/// The place `column` characters into `line`, if the line is that long.
fn at_column(text: &crate::core::Snapshot, line: usize, column: usize) -> Option<usize> {
    let range = text.line_content_range(line)?;
    let content = text.byte_slice(range.clone())?.to_string();
    let mut chars = content
        .char_indices()
        .map(|(at, _)| at)
        .chain([content.len()]);
    chars.nth(column).map(|at| range.start + at)
}
/// The matches of `query` in the grab but the main selection's.
fn matches(
    at: &Place,
    grab: &Range<usize>,
    query: &crate::editor::search::SearchQuery,
    main: &Range<usize>,
) -> Vec<Range<usize>> {
    query
        .cursor(at.text)
        .filter(|found| found.start >= grab.start && found.end <= grab.end)
        .filter(|found| found.end != main.end && found.end != main.start)
        .collect()
}
fn resolved(beacons: &[Grab], at: &Place) -> Vec<Range<usize>> {
    beacons
        .iter()
        .filter_map(|beacon| {
            let start = beacon.start.resolve(at.document).ok()?.0;
            let end = beacon.end.resolve(at.document).ok()?.0;
            Some(start.min(end)..start.max(end))
        })
        .collect()
}
