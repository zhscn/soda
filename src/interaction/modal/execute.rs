//! What each key does to the selection, and what it does with one.
use super::{Action, Effect, Entry, Grab, Kind, LastFind, Query, Read, Step, Tag, text};
use crate::{
    application::{Application, ClipboardAction, Event, View, ViewId},
    core::{
        Association, ByteOffset, Change, Selection, Snapshot, Transaction, logical_column_at,
        offset_at_logical_column,
    },
    editor::{Command as Edit, Direction, Document, search::SearchQuery},
    interaction::{Command, EditMode, Layers, Message, Response},
};
use std::time::Duration;

/// The text a command works on.
pub(super) struct Place<'a> {
    pub view: ViewId,
    pub document: &'a Document,
    pub text: &'a Snapshot,
    pub selection: Selection,
    pub time: Duration,
}
impl Place<'_> {
    pub fn event(&self, command: Edit) -> Event {
        Event::Edit {
            view: self.view,
            command,
            time: self.time,
        }
    }
    /// Deletes `range`, leaving the caret where it started.
    fn erase(&self, range: std::ops::Range<usize>) -> Event {
        let start = range.start;
        self.event(Edit::Apply(tx(
            self.text,
            vec![Change::new(range, "")],
            start,
        )))
    }
    /// Drops the selection, keeping its head.
    fn caret(&self) -> Event {
        self.event(Edit::SetSelection(Selection::caret(self.selection.head)))
    }
    fn clipboard(&self, action: ClipboardAction) -> Event {
        Event::Clipboard {
            view: self.view,
            action,
            time: self.time,
        }
    }
}
pub(super) fn place<'a>(app: &'a Application, time: Duration) -> Option<Place<'a>> {
    let view: &View = app.active_view().and_then(|id| app.view(id))?;
    let editor = app.workspace().editor(view.document_id)?;
    let document = editor.model().document();
    Some(Place {
        view: view.id,
        document,
        text: document.snapshot(),
        selection: editor.model().session(view.session_id)?.selection(),
        time,
    })
}
pub(super) fn position(
    document: &Document,
    offset: usize,
) -> Option<crate::editor::DocumentPosition> {
    document
        .position(ByteOffset(offset), Association::After)
        .ok()
}
/// Where `count` words or symbols from `from` end.
fn walk_things(
    text: &Snapshot,
    mut from: usize,
    symbol: bool,
    backward: bool,
    count: usize,
) -> Option<usize> {
    for _ in 0..count {
        from = if backward {
            text::thing_start(text, from, symbol)?
        } else {
            text::thing_end(text, from, symbol)?
        };
    }
    Some(from)
}
/// Where a find or till selection ends at a found character: past it going
/// forward to it, or going back till it.
fn found_end(found: usize, ch: char, till: bool, backward: bool) -> usize {
    if till == backward {
        found + ch.len_utf8()
    } else {
        found
    }
}
fn tx(text: &Snapshot, changes: Vec<Change>, caret: usize) -> Transaction {
    let mut tx = Transaction::new(text.version(), changes);
    tx.selection = Some(Selection::caret(caret));
    tx
}

impl Layers {
    /// Replaces the selection, remembering the one it replaces for `z`.
    fn select(
        &mut self,
        at: &Place,
        selection: Selection,
        kind: Option<(Kind, bool)>,
        response: &mut Response,
    ) {
        let old = (at.selection, self.modal.tag(at.selection));
        if !at.selection.range().is_empty()
            && self.modal.history.last().map(|entry| entry.0) != Some(at.selection)
        {
            self.modal.history.push(old);
        }
        self.modal.tag = kind.map(|(kind, expand)| Tag {
            selection,
            kind,
            expand,
        });
        response
            .events
            .push(at.event(Edit::SetSelection(selection)));
    }
    pub(in crate::interaction) fn fail(
        &mut self,
        mut response: Response,
        message: &str,
    ) -> Response {
        self.failed = true;
        response.message = Message::Set(message.into());
        response
    }
    pub(in crate::interaction) fn modal_execute(
        &mut self,
        action: Action,
        app: &Application,
        time: Duration,
    ) -> Response {
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        let Some(at) = place(app, time) else {
            return response;
        };
        // These leave the prefix argument for the command that comes next.
        match action {
            Action::Negative => {
                self.modal.negative = !self.modal.negative;
                return response;
            }
            Action::Digit(digit) => {
                let count = self.modal.count.unwrap_or(0);
                self.modal.count = Some(count.saturating_mul(10).saturating_add(digit).min(10000));
                return response;
            }
            Action::Find { till } => {
                self.modal.read = Some(Read::Find { till });
                return response;
            }
            Action::ThingAt { inner } => {
                self.modal.read = Some(Read::Thing { inner });
                return response;
            }
            Action::Expand(_) if self.modal.tag(at.selection).is_none() => {
                // Without a selection to extend, a digit is a count; a zero
                // starts none.
                if let Action::Expand(digit) = action
                    && digit != 0
                {
                    self.modal.count = Some(digit);
                }
                return response;
            }
            _ => {}
        }
        let (count, negative) = self.modal.take_prefix();
        if !matches!(
            action,
            Action::Move {
                step: Step::Up | Step::Down,
                ..
            }
        ) {
            self.modal.goal = None;
        }
        match action {
            Action::Move { step, extend } => self.step(&at, step, extend, count, &mut response),
            Action::Thing { symbol, backward } => {
                return self.thing(&at, symbol, backward ^ negative, count, response);
            }
            Action::Mark { symbol } => {
                let Some(range) = text::thing_at(at.text, at.selection.head, symbol) else {
                    return self.fail(response, "No word here");
                };
                let word = at.text.byte_slice(range.clone()).unwrap().to_string();
                self.modal.set_search(if symbol {
                    SearchQuery::symbol(word)
                } else {
                    SearchQuery::word(word)
                });
                let selection = ranged(range, negative);
                let kind = if symbol { Kind::Symbol } else { Kind::Word };
                self.select(&at, selection, Some((kind, true)), &mut response);
            }
            Action::Line => return self.line(&at, count, negative, response),
            Action::Query(query) => {
                response
                    .commands
                    .push(Command::Effect(Box::new(Effect::Structure(
                        query,
                        at.selection,
                    ))))
            }
            Action::Found {
                anchor,
                head,
                kind,
                expand,
            } => {
                self.select(
                    &at,
                    Selection { anchor, head },
                    Some((kind, expand)),
                    &mut response,
                );
            }
            Action::Reverse => {
                let selection = Selection {
                    anchor: at.selection.head,
                    head: at.selection.anchor,
                };
                self.modal.tag = self
                    .modal
                    .tag(at.selection)
                    .map(|tag| Tag { selection, ..tag });
                response
                    .events
                    .push(at.event(Edit::SetSelection(selection)));
            }
            Action::Cancel => {
                let leave = self.mode == EditMode::Beacon && at.selection.range().is_empty();
                self.modal.history.clear();
                self.modal.tag = None;
                if leave {
                    self.leave_beacon();
                }
                if !at.selection.range().is_empty() {
                    response.events.push(at.caret());
                }
            }
            Action::PopSelection { all } => {
                let entry = if all {
                    self.modal.history.drain(..).next()
                } else {
                    self.modal.history.pop()
                };
                let Some((selection, tag)) = entry else {
                    return self.fail(response, "No previous selection");
                };
                self.modal.tag = tag;
                response
                    .events
                    .push(at.event(Edit::SetSelection(selection)));
            }
            Action::Expand(digit) => return self.expand_selection(&at, digit, response),
            Action::Insert(entry) => self.enter_insert(&at, entry, &mut response),
            Action::Leave => {
                if self.mode == EditMode::Beacon {
                    self.leave_beacon();
                    return response;
                }
                let beacon = std::mem::take(&mut self.modal.beacon_insert);
                self.modal.insert_view = None;
                self.mode = if beacon {
                    EditMode::Beacon
                } else {
                    EditMode::Normal
                };
                response
                    .events
                    .push(at.event(Edit::EndUndoGroup(Selection::caret(at.selection.head))));
            }
            Action::Kill | Action::Delete if self.beacon_active() => {
                self.beacon_delete(&at, matches!(action, Action::Kill), &mut response);
            }
            Action::Kill => self.kill(&at, &mut response),
            Action::Change => {
                let range = changed(&at);
                if self.beacon_active() {
                    self.beacon_change(&at, &mut response);
                    return response;
                }
                self.modal.insert_view = Some(at.view);
                self.mode = EditMode::Insert;
                self.modal.tag = None;
                response
                    .events
                    .push(at.event(Edit::BeginUndoGroup(at.selection)));
                response.events.push(at.erase(range));
            }
            Action::Delete => {
                if self.join_tagged(&at) {
                    response.events.push(at.event(Edit::Apply(joined(&at))));
                } else if at.selection.range().is_empty() {
                    response.events.push(at.event(Edit::Delete {
                        direction: Direction::Forward,
                        smart: false,
                    }));
                } else {
                    response.events.push(at.erase(at.selection.range()));
                }
                self.modal.tag = None;
            }
            Action::Save => {
                if at.selection.range().is_empty() {
                    return self.fail(response, "No selection");
                }
                response.events.push(at.clipboard(ClipboardAction::Copy));
                // As Emacs's `kill-ring-save`: the selection goes, which
                // shows that the copy was made.
                response.events.push(at.caret());
                self.modal.tag = None;
            }
            Action::Yank => {
                response.events.push(at.caret());
                response.events.push(at.clipboard(ClipboardAction::Paste));
            }
            Action::Replace => response.events.push(at.clipboard(ClipboardAction::Paste)),
            Action::Join => return self.join(&at, response),
            Action::Search => return self.search(&at, negative, count, response),
            Action::PopSearch => {
                self.modal.searches.pop();
                self.modal.tag = None;
                response.events.push(at.caret());
            }
            Action::Undo { redo } => {
                self.modal.tag = None;
                response.events.push(at.caret());
                for _ in 0..count {
                    let edit = if redo { Edit::Redo } else { Edit::Undo };
                    response.events.push(at.event(edit));
                }
            }
            Action::Recenter => {
                let line = at.text.line_of(at.selection.head).unwrap();
                let view = app.view(at.view).unwrap();
                let top = line.saturating_sub(self.page_rows / 2);
                response.events.push(Event::SetViewport {
                    view: at.view,
                    anchor: ByteOffset(at.text.line_start(top).unwrap()),
                    horizontal_scroll: view.viewport.horizontal_scroll,
                });
            }
            Action::HalfPage { down } => return self.half_page(app, &at, down, response),
            Action::SetMark => {
                self.select(
                    &at,
                    Selection::caret(at.selection.head),
                    Some((Kind::Char, true)),
                    &mut response,
                );
            }
            Action::Grab => self.grab(&at, app, &mut response),
            Action::SwapGrab => return self.swap_grab(&at, response),
            Action::MacroStart => {
                // Keys go to the main selection alone until they are played.
                if self.mode == EditMode::Beacon {
                    self.mode = EditMode::Normal;
                }
                self.modal.macro_depth = at.document.history_depth();
                self.modal.replay.start();
                response.message = Message::Set("Recording a macro".into());
            }
            Action::MacroEnd => {
                if self.modal.replay.recording() {
                    self.modal.replay.stop();
                    response.message = Message::Set("Macro recorded".into());
                    if !self.modal.beacons.is_empty() {
                        self.apply_macro(&at, &mut response);
                    }
                } else if self.modal.replay.last().is_empty() {
                    return self.fail(response, "No macro");
                } else {
                    let keys = self.modal.replay.last().to_vec();
                    for _ in 0..count {
                        response.replay.extend(keys.iter().cloned());
                    }
                }
            }
            Action::MacroLines | Action::MacroMatches => {
                let keys = self.modal.replay.last().to_vec();
                if keys.is_empty() {
                    return self.fail(response, "No macro");
                }
                response
                    .commands
                    .push(if matches!(action, Action::MacroLines) {
                        Command::EachLine(keys)
                    } else {
                        // The matches of the search as it is: a whole word stays
                        // whole, and a pattern stays a pattern.
                        let Some(query) = self.modal.search() else {
                            return self.fail(response, "No search");
                        };
                        Command::EachAt {
                            targets: query.cursor(at.text).map(|found| found.start).collect(),
                            keys,
                        }
                    });
            }
            Action::Repeat => match self.modal.last.clone() {
                Some(command) => response.commands.push(command),
                None => return self.fail(response, "No command to repeat"),
            },
            Action::Negative | Action::Digit(_) | Action::Find { .. } | Action::ThingAt { .. } => {
                unreachable!("handled above")
            }
        }
        response
    }
    /// Takes the character a command asked for.
    pub(in crate::interaction) fn modal_read(
        &mut self,
        read: Read,
        ch: char,
        app: &Application,
        time: Duration,
    ) -> Response {
        let response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        let Some(at) = place(app, time) else {
            return response;
        };
        let (count, negative) = self.modal.take_prefix();
        match read {
            Read::Find { till } => {
                self.modal.last_find = Some(LastFind { ch, till });
                self.find(&at, ch, till, count, negative, None, response)
            }
            Read::Thing { inner } => self.thing_at(&at, ch, inner, negative, response),
        }
    }
    fn step(
        &mut self,
        at: &Place,
        step: Step,
        extend: bool,
        count: usize,
        response: &mut Response,
    ) {
        let text = at.text;
        let held = self
            .modal
            .tag(at.selection)
            .is_some_and(|tag| tag.kind == Kind::Char);
        let head = at.selection.head;
        let width = at.document.whitespace().tab_width;
        let mut to = head;
        match step {
            Step::Left => {
                for _ in 0..count {
                    to = if to > 0 { text::prev(text, to) } else { 0 };
                }
            }
            Step::Right => {
                for _ in 0..count {
                    to = text::next(text, to);
                }
            }
            Step::Up | Step::Down => {
                let kept = self
                    .modal
                    .goal
                    .filter(|(_, view, left)| *view == at.view && *left == head);
                let goal = match kept {
                    Some((goal, ..)) => goal,
                    None => logical_column_at(text, ByteOffset(head), width).unwrap(),
                };
                self.modal.goal = Some((goal, at.view, head));
                let line = text.line_of(head).unwrap().min(text::lines(text) - 1);
                let target = if step == Step::Up {
                    line.saturating_sub(count)
                } else {
                    line.saturating_add(count).min(text::lines(text) - 1)
                };
                if target == line {
                    self.failed = true;
                }
                to = offset_at_logical_column(text, target, goal, width)
                    .unwrap()
                    .0;
            }
        }
        let goal = self.modal.goal.map(|(goal, view, _)| (goal, view, to));
        let selection = if extend || held {
            let anchor = if at.selection.range().is_empty() || held || extend {
                at.selection.anchor
            } else {
                head
            };
            Selection { anchor, head: to }
        } else {
            Selection::caret(to)
        };
        let kind = (extend || held).then_some((Kind::Char, true));
        self.select(at, selection, kind, response);
        self.modal.goal = goal;
    }
    fn thing(
        &mut self,
        at: &Place,
        symbol: bool,
        backward: bool,
        count: usize,
        mut response: Response,
    ) -> Response {
        let kind = if symbol { Kind::Symbol } else { Kind::Word };
        let tag = self.modal.tag(at.selection).filter(|tag| tag.kind == kind);
        let head = at.selection.head;
        let Some(to) = walk_things(at.text, head, symbol, backward, count) else {
            return self.fail(response, "No more words");
        };
        let expand = tag.is_some_and(|tag| tag.expand);
        // A new selection starts at the word, with the blanks between it and
        // the caret, and never reaches behind the caret.
        let anchor = if expand {
            at.selection.anchor
        } else if backward {
            let end = text::thing_end(at.text, to, symbol).unwrap_or(to);
            text::blanks_after(at.text, end, head).min(head)
        } else {
            let start = text::thing_start(at.text, to, symbol).unwrap_or(to);
            text::blanks_before(at.text, start, head).max(head)
        };
        self.select(
            at,
            Selection { anchor, head: to },
            Some((kind, expand)),
            &mut response,
        );
        response
    }
    fn line(
        &mut self,
        at: &Place,
        count: usize,
        negative: bool,
        mut response: Response,
    ) -> Response {
        let text = at.text;
        let last = text::lines(text) - 1;
        let head = at.selection.head;
        let line = text.line_of(head).unwrap().min(last);
        let tagged = self
            .modal
            .tag(at.selection)
            .filter(|tag| tag.kind == Kind::Line);
        let selection = if tagged.is_some() {
            let backward = at.selection.anchor > at.selection.head;
            let target = if backward {
                line.saturating_sub(count)
            } else {
                (line + count).min(last)
            };
            if target == line {
                return self.fail(response, "No more lines");
            }
            let head = if backward {
                text.line_start(target).unwrap()
            } else {
                text.line_content_range(target).unwrap().end
            };
            Selection {
                anchor: at.selection.anchor,
                head,
            }
        } else if negative {
            let target = line.saturating_sub(count - 1);
            Selection {
                anchor: text.line_content_range(line).unwrap().end,
                head: text.line_start(target).unwrap(),
            }
        } else {
            let target = (line + count - 1).min(last);
            Selection {
                anchor: text.line_start(line).unwrap(),
                head: text.line_content_range(target).unwrap().end,
            }
        };
        self.select(at, selection, Some((Kind::Line, true)), &mut response);
        response
    }
    #[allow(clippy::too_many_arguments)]
    fn find(
        &mut self,
        at: &Place,
        ch: char,
        till: bool,
        count: usize,
        backward: bool,
        anchor: Option<usize>,
        mut response: Response,
    ) -> Response {
        let head = at.selection.head;
        let from = if anchor.is_some() && !backward && !till {
            head
        } else if anchor.is_some() && !backward {
            text::next(at.text, head)
        } else {
            head
        };
        let Some(found) = text::find(at.text, from, ch, count, backward) else {
            return self.fail(response, &format!("{ch} not found"));
        };
        let to = found_end(found, ch, till, backward);
        let kind = if till { Kind::Till } else { Kind::Find };
        self.select(
            at,
            Selection {
                anchor: anchor.unwrap_or(head),
                head: to,
            },
            Some((kind, false)),
            &mut response,
        );
        response
    }
    /// Where `count` more of what the selection covers ends.
    fn reach(&self, at: &Place, tag: Tag, count: usize) -> Option<usize> {
        let backward = at.selection.anchor > at.selection.head;
        let head = at.selection.head;
        match tag.kind {
            Kind::Word | Kind::Symbol => {
                walk_things(at.text, head, tag.kind == Kind::Symbol, backward, count)
            }
            Kind::Line => {
                let line = at.text.line_of(head).unwrap();
                let last = text::lines(at.text) - 1;
                let target = if backward {
                    line.checked_sub(count)?
                } else {
                    Some(line + count).filter(|target| *target <= last)?
                };
                Some(if backward {
                    at.text.line_start(target).unwrap()
                } else {
                    at.text.line_content_range(target).unwrap().end
                })
            }
            Kind::Find | Kind::Till => self.modal.last_find.and_then(|find| {
                let from = if tag.kind == Kind::Till {
                    text::next(at.text, head)
                } else {
                    head
                };
                let found = text::find(at.text, from, find.ch, count, backward)?;
                Some(found_end(found, find.ch, find.till, backward))
            }),
            _ => None,
        }
    }
    /// The digits that extend the selection, and where each one would take it.
    pub fn expand_hints(&self, app: &Application) -> Vec<(usize, char)> {
        let Some(at) = place(app, Default::default()) else {
            return vec![];
        };
        let Some(tag) = self.modal.tag(at.selection) else {
            return vec![];
        };
        if self.mode == EditMode::Insert {
            return vec![];
        }
        (1..=10)
            .filter_map(|count| {
                let to = self.reach(&at, tag, count)?;
                Some((to, char::from_digit(count as u32 % 10, 10)?))
            })
            .collect()
    }
    /// A digit: the same command again that many times, keeping the far end.
    fn expand_selection(&mut self, at: &Place, digit: usize, mut response: Response) -> Response {
        let Some(tag) = self.modal.tag(at.selection) else {
            return response;
        };
        let count = if digit == 0 { 10 } else { digit };
        let Some(to) = self.reach(at, tag, count) else {
            return self.fail(response, "Nothing to expand to");
        };
        self.select(
            at,
            Selection {
                anchor: at.selection.anchor,
                head: to,
            },
            Some((tag.kind, tag.expand)),
            &mut response,
        );
        response
    }
    fn thing_at(
        &mut self,
        at: &Place,
        ch: char,
        inner: bool,
        negative: bool,
        mut response: Response,
    ) -> Response {
        let head = at.selection.head;
        let open = match ch {
            'r' => Some('('),
            's' => Some('['),
            'c' => Some('{'),
            'a' => Some('<'),
            _ => None,
        };
        if let Some(open) = open {
            response
                .commands
                .push(Command::Effect(Box::new(Effect::Structure(
                    Query::Pair { open, inner },
                    at.selection,
                ))));
            return response;
        }
        let range = match ch {
            'g' => text::quoted(at.text, head, inner),
            'e' => text::thing_at(at.text, head, true),
            'w' => text::thing_at(at.text, head, false),
            'p' => text::paragraph(at.text, head, inner),
            'l' => {
                let line = at.text.line_of(head).unwrap();
                Some(if inner {
                    text::first(at.text, line)..at.text.line_content_range(line).unwrap().end
                } else {
                    at.text.line_range(line).unwrap()
                })
            }
            'b' => Some(0..at.text.len_bytes()),
            _ => return self.fail(response, &format!("No thing called {ch}")),
        };
        let Some(range) = range else {
            return self.fail(response, "No such thing here");
        };
        self.select(
            at,
            ranged(range, negative),
            Some((Kind::Thing, false)),
            &mut response,
        );
        response
    }
    fn enter_insert(&mut self, at: &Place, entry: Entry, response: &mut Response) {
        if self.beacon_active() && matches!(entry, Entry::Before | Entry::After) {
            self.beacon_insert(at, entry, response);
            return;
        }
        let text = at.text;
        let line = text
            .line_of(at.selection.head)
            .unwrap()
            .min(text::lines(text) - 1);
        let range = text.line_content_range(line).unwrap();
        self.modal.tag = None;
        self.modal.insert_view = Some(at.view);
        self.mode = EditMode::Insert;
        let begin = at.event(Edit::BeginUndoGroup(at.selection));
        match entry {
            Entry::Before | Entry::After => {
                let span = at.selection.range();
                let caret = if entry == Entry::Before {
                    span.start
                } else {
                    span.end
                };
                response
                    .events
                    .push(at.event(Edit::SetSelection(Selection::caret(caret))));
                response.events.push(begin);
            }
            Entry::Below => {
                response
                    .events
                    .push(at.event(Edit::SetSelection(Selection::caret(range.end))));
                response.events.push(begin);
                response.events.push(at.event(Edit::Enter));
            }
            Entry::Above => {
                let indent = text
                    .byte_slice(range.start..text::first(text, line))
                    .unwrap()
                    .to_string();
                let full = text.byte_slice(text.line_range(line).unwrap()).unwrap();
                let eol = if full.to_string().ends_with("\r\n") {
                    "\r\n"
                } else {
                    "\n"
                };
                let caret = range.start + indent.len();
                let change = Change::new(range.start..range.start, format!("{indent}{eol}"));
                response.events.push(begin);
                response
                    .events
                    .push(at.event(Edit::Apply(tx(text, vec![change], caret))));
                response.events.push(at.event(Edit::Reindent(line)));
            }
        }
    }
    fn join_tagged(&self, at: &Place) -> bool {
        self.modal
            .tag(at.selection)
            .is_some_and(|tag| tag.kind == Kind::Join)
    }
    fn kill(&mut self, at: &Place, response: &mut Response) {
        if self.join_tagged(at) {
            self.modal.tag = None;
            response.events.push(at.event(Edit::Apply(joined(at))));
            return;
        }
        let tag = self.modal.tag(at.selection);
        self.modal.tag = None;
        let mut range = at.selection.range();
        if range.is_empty() {
            response.events.push(at.clipboard(ClipboardAction::Kill {
                backward: false,
                word: false,
            }));
            return;
        }
        // A forward line selection takes its line break with it.
        if tag.is_some_and(|tag| tag.kind == Kind::Line)
            && at.selection.head > at.selection.anchor
            && range.end < at.text.len_bytes()
        {
            range.end = text::next(at.text, range.end);
        }
        let start = range.start;
        response.events.push(at.clipboard(ClipboardAction::Operate {
            range: range.clone(),
            edit: Change::new(range, ""),
            selection: Selection::caret(start),
        }));
    }
    /// `'`: the blanks between this line and the last line with text.
    fn join(&mut self, at: &Place, mut response: Response) -> Response {
        let text = at.text;
        let line = text.line_of(at.selection.head).unwrap();
        let blank =
            |line: usize| text::first(text, line) == text.line_content_range(line).unwrap().end;
        let mut above = line;
        loop {
            if above == 0 {
                return self.fail(response, "No line to join");
            }
            above -= 1;
            if !blank(above) {
                break;
            }
        }
        let selection = Selection {
            anchor: text::first(text, line),
            head: text.line_content_range(above).unwrap().end,
        };
        self.select(at, selection, Some((Kind::Join, true)), &mut response);
        response
    }
    fn search(
        &mut self,
        at: &Place,
        negative: bool,
        count: usize,
        mut response: Response,
    ) -> Response {
        let range = at.selection.range();
        let selected = at.text.byte_slice(range.clone()).unwrap().to_string();
        let matches_head = self
            .modal
            .search()
            .is_some_and(|query| query.cursor(at.text).any(|found| found == range));
        if !range.is_empty() && !matches_head {
            self.modal
                .set_search(SearchQuery::new(regex::escape(&selected)));
        }
        let Some(query) = self.modal.search().cloned() else {
            return self.fail(response, "No search");
        };
        let backward = (at.selection.anchor > at.selection.head) ^ negative;
        let found: Vec<_> = query.cursor(at.text).collect();
        if found.is_empty() {
            return self.fail(response, &format!("No match for {}", query.text()));
        }
        let mut index = None;
        let head = at.selection.head;
        for _ in 0..count {
            let from = index.map_or(head, |index: usize| {
                if backward {
                    found[index].start
                } else {
                    found[index].end
                }
            });
            index = Some(if backward {
                found
                    .iter()
                    .rposition(|range| range.end <= from)
                    .unwrap_or(found.len() - 1)
            } else {
                found
                    .iter()
                    .position(|range| range.start >= from)
                    .unwrap_or(0)
            });
        }
        let index = index.unwrap();
        let selection = ranged(found[index].clone(), backward);
        self.select(at, selection, Some((Kind::Visit, false)), &mut response);
        self.jumps.expect();
        response
            .commands
            .push(Command::Effect(Box::new(Effect::Indicator(
                at.text.line_of(found[index].start).unwrap(),
                format!("[{}/{}]", index + 1, found.len()),
            ))));
        response
    }
    fn half_page(
        &mut self,
        app: &Application,
        at: &Place,
        down: bool,
        mut response: Response,
    ) -> Response {
        let view = app.view(at.view).unwrap();
        let rows = (self.page_rows / 2).max(1);
        let line = at.text.line_of(at.selection.head).unwrap();
        let last = text::lines(at.text) - 1;
        if (down && line == last) || (!down && line == 0) {
            return self.fail(response, "Motion reached a buffer boundary");
        }
        let top = at.text.line_of(view.viewport.anchor.offset.0).unwrap();
        let top = if down {
            (top + rows).min(last)
        } else {
            top.saturating_sub(rows)
        };
        response.events.push(Event::SetViewport {
            view: at.view,
            anchor: ByteOffset(at.text.line_start(top).unwrap()),
            horizontal_scroll: view.viewport.horizontal_scroll,
        });
        let target = if down {
            (line + rows).min(last)
        } else {
            line.saturating_sub(rows)
        };
        let caret = Selection::caret(text::first(at.text, target));
        self.select(at, caret, None, &mut response);
        response
    }
    fn grab(&mut self, at: &Place, app: &Application, response: &mut Response) {
        let range = at.selection.range();
        self.modal.grab = position(at.document, range.start)
            .zip(position(at.document, range.end))
            .map(|(start, end)| Grab { start, end });
        self.modal.tag = None;
        let caret = Selection::caret(at.selection.head);
        response.events.push(at.event(Edit::SetSelection(caret)));
        if !range.is_empty() {
            self.mode = EditMode::Beacon;
            self.derive_beacons(app, at.time);
        }
    }
    fn swap_grab(&mut self, at: &Place, mut response: Response) -> Response {
        let Some(grab) = self.modal.grab.take() else {
            return self.fail(response, "Nothing grabbed");
        };
        let (Ok(start), Ok(end)) = (
            grab.start.resolve(at.document),
            grab.end.resolve(at.document),
        ) else {
            return self.fail(response, "Nothing grabbed");
        };
        let (other, range) = (start.0..end.0, at.selection.range());
        if other.start < range.end && range.start < other.end {
            return self.fail(response, "The selection overlaps the grab");
        }
        let held = at.text.byte_slice(range.clone()).unwrap().to_string();
        let taken = at.text.byte_slice(other.clone()).unwrap().to_string();
        let mut changes = vec![
            Change::new(other.clone(), held),
            Change::new(range.clone(), taken.clone()),
        ];
        changes.sort_by_key(|change| change.range.start);
        let moved = if other.start < range.start {
            (range.len() as isize - other.len() as isize) as usize
        } else {
            0
        };
        let caret = range.start.wrapping_add(moved) + taken.len();
        response
            .events
            .push(at.event(Edit::Apply(tx(at.text, changes, caret))));
        self.modal.tag = None;
        if self.mode == EditMode::Beacon {
            self.leave_beacon();
        }
        response
    }
}
/// What `s` takes away: the selection, or the character at the caret.
fn changed(at: &Place) -> std::ops::Range<usize> {
    let range = at.selection.range();
    if range.is_empty() && range.end < at.text.len_bytes() {
        range.start..text::next(at.text, range.end)
    } else {
        range
    }
}
fn ranged(range: std::ops::Range<usize>, backward: bool) -> Selection {
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
}
/// Closes the blanks of a join selection up to one space.
fn joined(at: &Place) -> Transaction {
    let range = at.selection.range();
    let start = range.start;
    let next = text::char_at(at.text, range.end);
    let space = if next.is_some_and(|ch| ch == ')' || ch == ']' || ch == '}') {
        ""
    } else {
        " "
    };
    tx(at.text, vec![Change::new(range, space)], start)
}
