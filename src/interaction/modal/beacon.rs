//! Beacon: many selections inside a grabbed range. The session holds the
//! main one; the others are positions that follow the text. Every other
//! selection is derived from the kind of the main one, so that moving it
//! moves all of them. Typing edits all of them at once, in one transaction.
use super::{
    Entry, Grab, Kind,
    execute::{Place, place, position},
    text,
};
use crate::{
    application::Application,
    core::{Change, Selection, Transaction, offset_at_logical_column},
    editor::Command as Edit,
    interaction::{EditMode, Layers, Response, UserInput},
};
use std::{ops::Range, time::Duration};

impl Layers {
    /// Whether commands act on more than the main selection.
    pub(super) fn beacon_active(&self) -> bool {
        self.mode == EditMode::Beacon && self.modal.grab.is_some()
    }
    pub(in crate::interaction) fn leave_beacon(&mut self) {
        self.mode = EditMode::Normal;
        self.modal.grab = None;
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
    /// The other selections, as ranges in the text.
    pub fn beacons(&self, app: &Application) -> Vec<Range<usize>> {
        let Some(at) = place(app, Default::default()) else {
            return vec![];
        };
        resolved(&self.modal.beacons, &at)
    }
    pub(in crate::interaction) fn derive_beacons(&mut self, app: &Application, time: Duration) {
        let Some(at) = place(app, time) else {
            return;
        };
        let Some(grab) = self.modal.grab else {
            return;
        };
        let (Ok(start), Ok(end)) = (
            grab.start.resolve(at.document),
            grab.end.resolve(at.document),
        ) else {
            return;
        };
        let main = at.selection.range();
        let ranges = self.derived(&at, start.0..end.0);
        self.modal.beacons = ranges
            .into_iter()
            // The main selection stands for its own place: a word it covers
            // only part of, as after `b` from inside it, is not another.
            .filter(|range| {
                let overlaps = range.start < main.end && main.start < range.end;
                *range != main
                    && !overlaps
                    && !(range.is_empty() && range.start == at.selection.head)
            })
            .filter_map(|range| {
                Some(Grab {
                    start: position(at.document, range.start)?,
                    end: position(at.document, range.end)?,
                })
            })
            .collect();
    }
    /// Where selections go, by the kind of the main one.
    fn derived(&self, at: &Place, grab: Range<usize>) -> Vec<Range<usize>> {
        let text = at.text;
        let tag = self.modal.tag(at.selection);
        let width = at.document.whitespace().tab_width;
        let first = text.line_of(grab.start).unwrap();
        let last = text
            .line_of(grab.end.saturating_sub(1).max(grab.start))
            .unwrap();
        let lines = first..=last;
        let column = |offset: usize| {
            crate::core::logical_column_at(text, crate::core::ByteOffset(offset), width).unwrap()
        };
        let matches = |query: &crate::editor::search::SearchQuery| {
            query
                .cursor(text)
                .filter(|found| found.start >= grab.start && found.end <= grab.end)
                .collect::<Vec<_>>()
        };
        match tag.map(|tag| (tag.kind, tag.expand)) {
            None => {
                // Carets in the same column of the other lines; shorter
                // lines are skipped.
                let goal = column(at.selection.head);
                lines
                    .filter_map(|line| {
                        let offset = offset_at_logical_column(text, line, goal, width).ok()?.0;
                        (column(offset) == goal).then_some(offset..offset)
                    })
                    .collect()
            }
            Some((Kind::Char, _)) => {
                let (from, to) = (column(at.selection.anchor), column(at.selection.head));
                lines
                    .filter_map(|line| {
                        let start = offset_at_logical_column(text, line, from, width).ok()?.0;
                        let end = offset_at_logical_column(text, line, to, width).ok()?.0;
                        (column(start) == from && column(end) == to).then_some(start..end)
                    })
                    .collect()
            }
            Some((kind @ (Kind::Word | Kind::Symbol), false)) => {
                // Every word, selected as the main one is, so that `i` and
                // `a` go to the same end of each.
                let symbol = kind == Kind::Symbol;
                let mut words = vec![];
                let mut from = grab.start;
                while let Some(end) = text::thing_end(text, from, symbol) {
                    if end > grab.end {
                        break;
                    }
                    let start = text::thing_start(text, end, symbol).unwrap_or(from);
                    words.push(start.max(grab.start)..end);
                    from = end;
                }
                words
            }
            Some((kind @ (Kind::Word | Kind::Symbol), true)) => {
                use crate::editor::search::SearchQuery;
                let selected = text.byte_slice(at.selection.range()).unwrap().to_string();
                matches(&if kind == Kind::Symbol {
                    SearchQuery::symbol(selected)
                } else {
                    SearchQuery::word(selected)
                })
            }
            Some((Kind::Visit, _)) => self.modal.search().map_or(vec![], matches),
            Some((Kind::Line, _)) => {
                let selected = at.selection.range();
                let height =
                    text.line_of(selected.end).unwrap() - text.line_of(selected.start).unwrap() + 1;
                let mut ranges = vec![];
                let mut line = first;
                while line + height - 1 <= last {
                    ranges.push(
                        text.line_start(line).unwrap()
                            ..text.line_content_range(line + height - 1).unwrap().end,
                    );
                    line += height;
                }
                ranges
            }
            Some((Kind::Join, _)) => lines
                .map(|line| {
                    let caret = text::first(text, line);
                    caret..caret
                })
                .collect(),
            Some((kind @ (Kind::Find | Kind::Till), _)) => {
                let Some(find) = self.modal.last_find else {
                    return vec![];
                };
                let mut carets = vec![];
                let mut from = grab.start;
                while let Some(found) = text::find(text, from, find.ch, 1, false) {
                    if found >= grab.end {
                        break;
                    }
                    let caret = if kind == Kind::Find {
                        found + find.ch.len_utf8()
                    } else {
                        found
                    };
                    carets.push(caret..caret);
                    from = found + find.ch.len_utf8();
                }
                carets
            }
            Some(_) => vec![],
        }
    }
    /// `i` and `a` with beacons: a caret at the same end of each selection.
    pub(super) fn beacon_insert(&mut self, at: &Place, entry: Entry, response: &mut Response) {
        let before = entry == Entry::Before;
        let end = |range: &Range<usize>| if before { range.start } else { range.end };
        let carets: Vec<_> = resolved(&self.modal.beacons, at)
            .iter()
            .map(end)
            .filter_map(|caret| {
                let place = position(at.document, caret)?;
                Some(Grab {
                    start: place,
                    end: place,
                })
            })
            .collect();
        self.modal.beacons = carets;
        self.start_typing(at, end(&at.selection.range()), response);
    }
    fn start_typing(&mut self, at: &Place, caret: usize, response: &mut Response) {
        self.modal.tag = None;
        self.modal.insert_view = Some(at.view);
        self.modal.beacon_insert = true;
        self.mode = EditMode::Insert;
        response
            .events
            .push(at.event(Edit::SetSelection(Selection::caret(caret))));
        response
            .events
            .push(at.event(Edit::BeginUndoGroup(at.selection)));
    }
    /// `s` with beacons: every selection goes, and typing starts there.
    pub(super) fn beacon_change(&mut self, at: &Place, response: &mut Response) {
        self.modal.tag = None;
        self.modal.insert_view = Some(at.view);
        self.modal.beacon_insert = true;
        self.mode = EditMode::Insert;
        response
            .events
            .push(at.event(Edit::BeginUndoGroup(at.selection)));
        if let Some(tx) = self.removal(at) {
            response.events.push(at.event(Edit::Apply(tx)));
        }
    }
    /// `d` and `r` with beacons: every selection goes; `r` puts their text
    /// on the clipboard, a line each.
    pub(super) fn beacon_delete(&mut self, at: &Place, kill: bool, response: &mut Response) {
        self.modal.tag = None;
        if kill {
            let mut ranges = self.selections(at);
            ranges.retain(|range| !range.is_empty());
            let taken: Vec<_> = ranges
                .iter()
                .map(|range| at.text.byte_slice(range.clone()).unwrap().to_string())
                .collect();
            response
                .events
                .push(crate::application::Event::SetClipboard(taken.join("\n")));
        }
        if let Some(tx) = self.removal(at) {
            response.events.push(at.event(Edit::Apply(tx)));
        }
    }
    /// Every selection, the main one too, in order; a caret stands for the
    /// character after it.
    fn selections(&self, at: &Place) -> Vec<Range<usize>> {
        let mut ranges = resolved(&self.modal.beacons, at);
        ranges.push(at.selection.range());
        for range in &mut ranges {
            if range.start == range.end && range.end < at.text.len_bytes() {
                range.end = text::next(at.text, range.end);
            }
        }
        ranges.sort_by_key(|range| range.start);
        // Selections that meet become one, as a transaction wants.
        let mut merged: Vec<Range<usize>> = vec![];
        for range in ranges {
            match merged.last_mut() {
                Some(last) if range.start < last.end || range == *last => {
                    last.end = last.end.max(range.end);
                }
                _ => merged.push(range),
            }
        }
        merged
    }
    /// Takes away every selection, with the caret where the main one was.
    fn removal(&self, at: &Place) -> Option<Transaction> {
        let start = at.selection.range().start;
        let ranges: Vec<_> = self
            .selections(at)
            .into_iter()
            .filter(|range| !range.is_empty())
            .collect();
        if ranges.is_empty() {
            return None;
        }
        let moved: usize = ranges
            .iter()
            .filter(|range| range.start < start)
            .map(|range| range.len().min(start - range.start))
            .sum();
        let changes = ranges
            .into_iter()
            .map(|range| Change::new(range, ""))
            .collect();
        let mut tx = Transaction::new(at.text.version(), changes);
        tx.selection = Some(Selection::caret(start - moved));
        Some(tx)
    }
    /// Typing with beacons: `edit` says what happens at each caret.
    pub(in crate::interaction) fn beacon_type(
        &mut self,
        edit: BeaconEdit,
        app: &Application,
        time: Duration,
    ) -> Response {
        let mut response = Response {
            redraw: true,
            ..Response::default()
        };
        let Some(at) = place(app, time) else {
            return response;
        };
        let main = at.selection.head;
        let mut carets: Vec<_> = resolved(&self.modal.beacons, &at)
            .into_iter()
            .map(|range| range.end)
            .collect();
        carets.push(main);
        carets.sort_unstable();
        carets.dedup();
        let mut after = main;
        let changes: Vec<_> = carets
            .iter()
            .filter_map(|&caret| {
                let change = match &edit {
                    BeaconEdit::Text(text) => Change::new(caret..caret, text.clone()),
                    BeaconEdit::Backward if caret > 0 => {
                        Change::new(text::prev(at.text, caret)..caret, "")
                    }
                    BeaconEdit::Forward if caret < at.text.len_bytes() => {
                        Change::new(caret..text::next(at.text, caret), "")
                    }
                    _ => return None,
                };
                let delta = change.insert.len() as isize - change.range.len() as isize;
                if caret <= main {
                    after = after.wrapping_add_signed(delta);
                }
                Some(change)
            })
            .collect();
        if changes.is_empty() {
            return response;
        }
        let mut tx = Transaction::new(at.text.version(), changes);
        tx.selection = Some(Selection::caret(after));
        response.events.push(at.event(Edit::Apply(tx)));
        response
    }
    /// The last macro at the other selections, after the main one saw it.
    pub(super) fn apply_macro(&mut self, at: &Place, response: &mut Response) {
        let keys: Vec<UserInput> = self.modal.replay.last().to_vec();
        let targets: Vec<_> = resolved(&self.modal.beacons, at);
        // Each selection runs the way the main one did when recording began.
        let (backward, kind) = self.modal.macro_shape.take().unwrap_or((false, None));
        let selections = targets.into_iter().map(|range| {
            if backward {
                Selection {
                    anchor: range.end,
                    head: range.start,
                }
            } else {
                Selection {
                    anchor: range.start,
                    head: range.end,
                }
            }
        });
        self.leave_beacon();
        response
            .commands
            .extend(crate::interaction::commands::replay_each(
                selections,
                kind,
                &keys,
                self.modal.macro_depth,
            ));
    }
}
/// What a key does at every caret.
pub(in crate::interaction) enum BeaconEdit {
    Text(String),
    Backward,
    Forward,
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
