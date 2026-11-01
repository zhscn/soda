//! Plans cursor changes and register operations; Application owns execution.
use super::{Insert, Motion, Operator, Target, VimCommand, motion, object};
use crate::{
    application::{Application, ClipboardAction, Event},
    core::{Change, Selection, Transaction},
    editor::Command as Edit,
    interaction::{EditMode, Layers, Message, Response},
};
use crate::{core::Snapshot, editor::search::SearchQuery};
use motion::{Find, Kind};
use std::{ops::Range, time::Duration};
impl Layers {
    pub(in crate::interaction) fn vim_visual_valid(&self, app: &Application) -> bool {
        let Some((anchor, head)) = self.vim.visual else {
            return false;
        };
        let Some(view) = app.active_view().and_then(|id| app.view(id)) else {
            return false;
        };
        let editor = app.workspace().editor(view.document_id).unwrap();
        editor.model().session(view.session_id).unwrap().selection()
            == visual_selection(
                editor.model().document().snapshot(),
                anchor,
                head,
                self.mode == EditMode::VisualLine,
            )
    }
    pub(in crate::interaction) fn vim_normalize(
        &mut self,
        app: &Application,
        time: Duration,
    ) -> Response {
        let mut response = Response::default();
        if self.active().is_some() || self.mode != EditMode::Normal {
            return response;
        }
        if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
            let editor = app.workspace().editor(view.document_id).unwrap();
            let selection = editor.model().session(view.session_id).unwrap().selection();
            let caret = motion::clamp(
                editor.model().document().snapshot(),
                selection.range().start,
            );
            if selection != Selection::caret(caret) {
                response.events.push(Event::Edit {
                    view: view.id,
                    command: Edit::SetSelection(Selection::caret(caret)),
                    time,
                });
            }
        }
        response
    }
    pub(in crate::interaction) fn vim_execute(
        &mut self,
        command: VimCommand,
        register_name: Option<char>,
        app: &Application,
        time: Duration,
    ) -> Response {
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        let count = match command {
            VimCommand::Move(_, n)
            | VimCommand::Operate(_, _, n)
            | VimCommand::ReplaceChar(_, n)
            | VimCommand::Undo { count: n, .. }
            | VimCommand::Put { count: n, .. }
            | VimCommand::DeleteChar { count: n, .. }
            | VimCommand::RepeatSearch { count: n, .. }
            | VimCommand::SearchWord { count: n, .. }
            | VimCommand::Select(_, n)
            | VimCommand::ToggleCaseChar(n)
            | VimCommand::Join(n)
            | VimCommand::Play(_, n) => n,
            _ => 1,
        };
        let sentinel = count == usize::MAX
            && matches!(
                command,
                VimCommand::Move(Motion::Bottom, _)
                    | VimCommand::Operate(_, Target::Motion(Motion::Bottom), _)
            );
        if count == 0 || (count > 10000 && !sentinel) {
            response.message = Message::Set("Count must be between 1 and 10000".into());
            return response;
        }
        let Some(view) = app.active_view().and_then(|id| app.view(id)) else {
            return response;
        };
        let document = app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .document();
        let text = document.snapshot();
        let selection = app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .session(view.session_id)
            .unwrap()
            .selection();
        let at = self.vim.visual.map_or(selection.head, |(_, head)| head);
        let line = text.line_of(at).unwrap().min(motion::lines(text) - 1);
        let range = text.line_content_range(line).unwrap();
        let event = |command| Event::Edit {
            view: view.id,
            command,
            time,
        };
        match command {
            VimCommand::Insert(kind) => {
                let was_insert = self.mode == EditMode::Insert;
                self.vim.replay.changed |= !matches!(kind, Insert::Leave);
                self.vim.reset();
                self.vim.insert_view = if matches!(kind, Insert::Leave) {
                    None
                } else {
                    Some(view.id)
                };
                self.mode = if matches!(kind, Insert::Leave) {
                    EditMode::Normal
                } else {
                    EditMode::Insert
                };
                let caret = match kind {
                    Insert::Before => at,
                    Insert::After => motion::next(text, at).min(range.end),
                    Insert::Start => motion::first(text, line),
                    Insert::End => range.end,
                    Insert::Leave => {
                        if was_insert && at > range.start {
                            motion::prev(text, at)
                        } else {
                            at
                        }
                    }
                    Insert::Below => {
                        response
                            .events
                            .push(event(Edit::SetSelection(Selection::caret(range.end))));
                        response.events.push(event(Edit::BeginUndoGroup(selection)));
                        response.events.push(event(Edit::Enter));
                        return response;
                    }
                    Insert::Above => {
                        let indent = text
                            .byte_slice(range.start..motion::first(text, line))
                            .unwrap()
                            .to_string();
                        let eol = if text
                            .byte_slice(text.line_range(line).unwrap())
                            .unwrap()
                            .to_string()
                            .ends_with("\r\n")
                        {
                            "\r\n"
                        } else {
                            "\n"
                        };
                        let (offset, insert, caret) = if matches!(kind, Insert::Above) {
                            (
                                range.start,
                                format!("{indent}{eol}"),
                                range.start + indent.len(),
                            )
                        } else {
                            (
                                range.end,
                                format!("{eol}{indent}"),
                                range.end + eol.len() + indent.len(),
                            )
                        };
                        let mut tx = Transaction::new(
                            text.version(),
                            vec![Change::new(offset..offset, insert)],
                        );
                        tx.selection = Some(Selection::caret(caret));
                        response.events.push(event(Edit::BeginUndoGroup(selection)));
                        response.events.push(event(Edit::Apply(tx)));
                        response.events.push(event(Edit::Reindent(line)));
                        return response;
                    }
                };
                if matches!(kind, Insert::Leave) {
                    response
                        .events
                        .push(event(Edit::EndUndoGroup(Selection::caret(caret))));
                } else {
                    response
                        .events
                        .push(event(Edit::SetSelection(Selection::caret(caret))));
                    response.events.push(event(Edit::BeginUndoGroup(selection)));
                }
            }
            VimCommand::Move(motion, count) => {
                let count = if count == usize::MAX {
                    motion::lines(text)
                } else {
                    count
                };
                let Some(motion) = self.vim.resolve(motion) else {
                    return self.fail(response, "No previous find");
                };
                let Some(head) = motion::endpoint(
                    text,
                    at,
                    motion,
                    count,
                    &mut self.vim.goal,
                    document.whitespace().tab_width,
                ) else {
                    return self.fail(response, "Motion failed");
                };
                // Vim reports a vertical move that cannot leave its line,
                // which also ends a macro.
                if matches!(motion, Motion::Up | Motion::Down)
                    && text.line_of(head).unwrap() == line
                {
                    self.failed = true;
                }
                response
                    .events
                    .push(self.move_to(view.id, text, head, time));
            }
            VimCommand::Visual { linewise } => {
                let mode = if linewise {
                    EditMode::VisualLine
                } else {
                    EditMode::Visual
                };
                if self.mode == mode {
                    self.mode = EditMode::Normal;
                    self.vim.visual = None;
                    response
                        .events
                        .push(event(Edit::SetSelection(Selection::caret(at))));
                } else {
                    let anchor = self.vim.visual.map_or(at, |(anchor, _)| anchor);
                    self.mode = mode;
                    self.vim.visual = Some((anchor, at));
                    response
                        .events
                        .push(event(Edit::SetSelection(visual_selection(
                            text, anchor, at, linewise,
                        ))));
                }
            }
            VimCommand::VisualRange { anchor, head } => {
                // Visual mode holds the characters at its two ends.
                let ends = if head >= anchor {
                    (anchor, motion::prev(text, head).max(anchor))
                } else {
                    (motion::prev(text, anchor).max(head), head)
                };
                if !matches!(self.mode, EditMode::Visual | EditMode::VisualLine) {
                    self.mode = EditMode::Visual;
                }
                self.vim.visual = Some(ends);
                response
                    .events
                    .push(event(Edit::SetSelection(visual_selection(
                        text,
                        ends.0,
                        ends.1,
                        self.mode == EditMode::VisualLine,
                    ))));
            }
            VimCommand::Operate(op, target, count) => {
                let (mut operated, linewise) = if self.vim.visual.is_some() {
                    (selection.range(), self.mode == EditMode::VisualLine)
                } else {
                    match region(text, at, op, target, count, &self.vim, document) {
                        Ok(region) => region,
                        Err(error) => return self.fail(response, error),
                    }
                };
                if !matches!(op, Operator::Delete | Operator::Change | Operator::Yank) {
                    let levels = if self.vim.visual.is_some() { count } else { 1 };
                    self.mode = EditMode::Normal;
                    self.vim.visual = None;
                    self.vim.goal = None;
                    self.vim.replay.changed = true;
                    let tx = transform(text, operated, linewise, op, levels, document);
                    response.events.push(event(Edit::Apply(tx)));
                    return response;
                }
                let register = operated.clone();
                let replacement = if op == Operator::Change && linewise {
                    let firstline = text.line_of(operated.start).unwrap();
                    let indent = text
                        .byte_slice(
                            text.line_start(firstline).unwrap()..motion::first(text, firstline),
                        )
                        .unwrap()
                        .to_string();
                    let lastline = text.line_of(operated.end.saturating_sub(1)).unwrap();
                    let eol = text
                        .byte_slice(text.line_range(lastline).unwrap())
                        .unwrap()
                        .to_string();
                    format!(
                        "{indent}{}",
                        if eol.ends_with("\r\n") {
                            "\r\n"
                        } else if eol.ends_with('\n') {
                            "\n"
                        } else {
                            ""
                        }
                    )
                } else {
                    String::new()
                };
                if op == Operator::Delete
                    && linewise
                    && operated.end == text.len_bytes()
                    && operated.start > 0
                    && !text
                        .byte_slice(motion::prev(text, text.len_bytes())..text.len_bytes())
                        .unwrap()
                        .to_string()
                        .ends_with('\n')
                {
                    operated.start = text
                        .line_content_range(text.line_of(operated.start).unwrap() - 1)
                        .unwrap()
                        .end;
                }
                let caret = if op == Operator::Yank {
                    if self.vim.visual.is_some() {
                        register.start
                    } else {
                        at.min(register.start)
                    }
                } else if op == Operator::Delete && linewise {
                    if operated.start < register.start {
                        motion::first(text, text.line_of(operated.start).unwrap())
                    } else if register.end < text.len_bytes() {
                        let nextline = text.line_of(register.end).unwrap();
                        operated.start + motion::first(text, nextline) - register.end
                    } else {
                        operated.start
                    }
                } else {
                    operated.start
                        + if op == Operator::Change && linewise {
                            replacement.trim_end_matches(['\r', '\n']).len()
                        } else {
                            0
                        }
                };
                if op == Operator::Change {
                    self.vim.insert_view = Some(view.id);
                }
                self.mode = if op == Operator::Change {
                    EditMode::Insert
                } else {
                    EditMode::Normal
                };
                self.vim.visual = None;
                self.vim.goal = None;
                if op == Operator::Change {
                    response.events.push(event(Edit::BeginUndoGroup(selection)));
                }
                if !register.is_empty() || linewise {
                    response.events.push(Event::Clipboard {
                        view: view.id,
                        action: ClipboardAction::Operate {
                            range: register,
                            linewise,
                            edit: if op == Operator::Yank {
                                None
                            } else {
                                Some(Change::new(operated, replacement))
                            },
                            selection: Selection::caret(caret),
                            register: register_name,
                        },
                        time,
                    });
                } else {
                    // An empty object, as in `()`, only moves the caret.
                    response
                        .events
                        .push(event(Edit::SetSelection(Selection::caret(caret))));
                }
                self.vim.replay.changed |= op != Operator::Yank;
            }
            VimCommand::Undo { redo, count } => {
                for _ in 0..count.min(10000) {
                    response
                        .events
                        .push(event(if redo { Edit::Redo } else { Edit::Undo }));
                }
            }
            VimCommand::EraseWord => {
                let start = motion::word(text, at, Motion::BackWord, 1);
                let mut tx = Transaction::new(text.version(), vec![Change::new(start..at, "")]);
                tx.selection = Some(Selection::caret(start));
                response.events.push(event(Edit::Apply(tx)));
            }
            VimCommand::EraseLineStart => {
                let mut tx =
                    Transaction::new(text.version(), vec![Change::new(range.start..at, "")]);
                tx.selection = Some(Selection::caret(range.start));
                response.events.push(event(Edit::Apply(tx)));
            }
            VimCommand::ReplaceChar(ch, count) => {
                let mut end = at;
                for _ in 0..count {
                    if end >= range.end {
                        response.message = Message::Set("Not enough characters to replace".into());
                        return response;
                    }
                    end = motion::next(text, end);
                }
                let mut tx = Transaction::new(
                    text.version(),
                    vec![Change::new(at..end, ch.to_string().repeat(count))],
                );
                tx.selection = Some(Selection::caret(at + (count - 1) * ch.len_utf8()));
                self.vim.replay.changed = true;
                response.events.push(event(Edit::Apply(tx)));
            }
            VimCommand::DeleteChar { backward, count } => {
                let mut end = at;
                for _ in 0..count {
                    end = if backward {
                        motion::prev(text, end).max(range.start)
                    } else {
                        motion::next(text, end).min(range.end)
                    };
                }
                let range = at.min(end)..at.max(end);
                if !range.is_empty() {
                    self.vim.replay.changed = true;
                    response.events.push(Event::Clipboard {
                        view: view.id,
                        action: ClipboardAction::Operate {
                            range: range.clone(),
                            linewise: false,
                            edit: Some(Change::new(range.clone(), "")),
                            selection: Selection::caret(range.start),
                            register: register_name,
                        },
                        time,
                    });
                }
            }
            VimCommand::Put { before, count } => {
                self.vim.replay.changed = true;
                // In Visual mode the text replaces the selection.
                let replace = self.vim.visual.take().map(|_| {
                    let linewise = self.mode == EditMode::VisualLine;
                    self.mode = EditMode::Normal;
                    (selection.range(), linewise)
                });
                response.events.push(Event::Clipboard {
                    view: view.id,
                    action: ClipboardAction::Put {
                        before,
                        count,
                        register: register_name,
                        replace,
                    },
                    time,
                });
            }
            VimCommand::Search { backward } => {
                self.vim.search_backward = backward;
                response.message =
                    Message::Set("Search must be started through the command reducer".into());
            }
            VimCommand::RepeatSearch { reverse, count } => {
                let Some(query) = self.vim.last_search.clone() else {
                    return self.fail(response, "No previous search");
                };
                let backward = self.vim.search_backward ^ reverse;
                let caret = search_from(&query, text, at, backward, count);
                response
                    .events
                    .push(self.move_to(view.id, text, caret, time));
            }
            VimCommand::SearchWord { backward, count } => {
                let Some(word) = motion::keyword_at(text, at) else {
                    return self.fail(response, "No word under the caret");
                };
                let query = SearchQuery::word(text.byte_slice(word.clone()).unwrap().to_string());
                let caret = search_from(&query, text, word.start, backward, count);
                self.vim.last_search = Some(query);
                self.vim.search_backward = backward;
                response
                    .events
                    .push(self.move_to(view.id, text, caret, time));
            }
            VimCommand::Select(object, count) => {
                let Some(found) =
                    object::range(text, at, object, count).filter(|found| !found.is_empty())
                else {
                    return self.fail(response, "No text object here");
                };
                if object.linewise() {
                    self.mode = EditMode::VisualLine;
                }
                let (anchor, head) = (found.start, motion::prev(text, found.end));
                self.vim.visual = Some((anchor, head));
                response
                    .events
                    .push(event(Edit::SetSelection(visual_selection(
                        text,
                        anchor,
                        head,
                        self.mode == EditMode::VisualLine,
                    ))));
            }
            VimCommand::VisualOther => {
                if let Some((anchor, head)) = self.vim.visual {
                    self.vim.visual = Some((head, anchor));
                    response
                        .events
                        .push(event(Edit::SetSelection(visual_selection(
                            text,
                            head,
                            anchor,
                            self.mode == EditMode::VisualLine,
                        ))));
                }
            }
            VimCommand::ToggleCaseChar(count) => {
                if range.is_empty() {
                    return self.fail(response, "No character to change");
                }
                let mut end = at;
                for _ in 0..count {
                    end = motion::next(text, end).min(range.end);
                }
                let converted = convert_case(
                    &text.byte_slice(at..end).unwrap().to_string(),
                    Operator::ToggleCase,
                );
                // The caret moves past the changed characters, but not
                // past the line's last one.
                let caret = if end == range.end {
                    at + converted.len() - converted.chars().next_back().map_or(0, char::len_utf8)
                } else {
                    at + converted.len()
                };
                let mut tx =
                    Transaction::new(text.version(), vec![Change::new(at..end, converted)]);
                tx.selection = Some(Selection::caret(caret));
                self.vim.replay.changed = true;
                response.events.push(event(Edit::Apply(tx)));
            }
            VimCommand::Join(count) => {
                let (first, count) = match self.vim.visual {
                    Some((anchor, head)) => {
                        let first = text.line_of(anchor.min(head)).unwrap();
                        let last = text.line_of(anchor.max(head)).unwrap();
                        (first, last - first + 1)
                    }
                    None => (line, count),
                };
                let Some(tx) = join(text, first, count.max(2)) else {
                    return self.fail(response, "No line to join");
                };
                self.mode = EditMode::Normal;
                self.vim.visual = None;
                self.vim.replay.changed = true;
                response.events.push(event(Edit::Apply(tx)));
            }
            VimCommand::RepeatChange(count) => match self.vim.replay.last_change(count) {
                Some(keys) => response.replay = keys,
                None => return self.fail(response, "No previous change"),
            },
            VimCommand::Record(Some(register)) => {
                self.vim.replay.start(register);
            }
            VimCommand::Record(None) => self.vim.replay.stop(),
            VimCommand::Play(register, count) => match self.vim.replay.play(register) {
                Some(keys) => {
                    for _ in 0..count {
                        response.replay.extend(keys.iter().cloned());
                    }
                }
                None => return self.fail(response, "Register is empty"),
            },
            VimCommand::SetMark(mark) => self.vim.marks.set(document, mark, at),
            VimCommand::JumpMark { mark, exact } => {
                let Some(offset) = self.vim.marks.get(document, mark) else {
                    return self.fail(response, "Mark not set");
                };
                let head = if exact {
                    motion::clamp(text, offset)
                } else {
                    motion::clamp(text, motion::first(text, text.line_of(offset).unwrap()))
                };
                response
                    .events
                    .push(self.move_to(view.id, text, head, time));
            }
            VimCommand::Recenter => {
                let top = line.saturating_sub(self.page_rows / 2);
                response.events.push(Event::SetViewport {
                    view: view.id,
                    anchor: crate::core::ByteOffset(text.line_start(top).unwrap()),
                    horizontal_column: view.viewport.horizontal_column,
                });
            }
            VimCommand::HalfPage { down, count } => {
                let rows = if count > 0 {
                    count
                } else {
                    (self.page_rows / 2).max(1)
                };
                let last = motion::lines(text) - 1;
                if (down && line == last) || (!down && line == 0) {
                    return self.fail(response, "Motion reached a buffer boundary");
                }
                // The view scrolls as far as the caret moves.
                let top = text.line_of(view.viewport.anchor.offset.0).unwrap();
                let top = if down {
                    (top + rows).min(last)
                } else {
                    top.saturating_sub(rows)
                };
                response.events.push(Event::SetViewport {
                    view: view.id,
                    anchor: crate::core::ByteOffset(text.line_start(top).unwrap()),
                    horizontal_column: view.viewport.horizontal_column,
                });
                let target = if down {
                    (line + rows).min(last)
                } else {
                    line.saturating_sub(rows)
                };
                let head = motion::clamp(text, motion::first(text, target));
                self.vim.goal = None;
                response
                    .events
                    .push(self.move_to(view.id, text, head, time));
            }
        }
        response
    }
}
impl Layers {
    fn fail(&mut self, mut response: Response, message: &str) -> Response {
        self.failed = true;
        response.message = Message::Set(message.into());
        response
    }
    /// Moves the caret, or the Visual head.
    fn move_to(
        &mut self,
        view: crate::application::ViewId,
        text: &Snapshot,
        head: usize,
        time: Duration,
    ) -> Event {
        let selection = match self.vim.visual {
            Some((anchor, _)) => {
                self.vim.visual = Some((anchor, head));
                visual_selection(text, anchor, head, self.mode == EditMode::VisualLine)
            }
            None => Selection::caret(head),
        };
        Event::Edit {
            view,
            command: Edit::SetSelection(selection),
            time,
        }
    }
}
impl super::State {
    /// Replaces `;` and `,` with the find they repeat.
    fn resolve(&self, motion: Motion) -> Option<Motion> {
        match motion {
            Motion::RepeatFind { reverse } => self.last_find.map(|find| {
                Motion::Find(Find {
                    backward: find.backward ^ reverse,
                    repeat: true,
                    ..find
                })
            }),
            motion => Some(motion),
        }
    }
}
/// The range an operator covers and whether it is whole lines.
fn region(
    text: &Snapshot,
    at: usize,
    op: Operator,
    target: Target,
    count: usize,
    vim: &super::State,
    document: &crate::editor::Document,
) -> Result<(Range<usize>, bool), &'static str> {
    let line = text.line_of(at).unwrap().min(motion::lines(text) - 1);
    let range = text.line_content_range(line).unwrap();
    let lines = |first: usize, last: usize| {
        text.line_start(first).unwrap()..text.line_range(last).unwrap().end
    };
    let motion = match target {
        Target::Line => {
            // A count reaching past the end stops there, unless the caret
            // is already on the last line.
            if count > 1 && line == motion::lines(text) - 1 {
                return Err("Motion reached a buffer boundary");
            }
            let last = (line + count - 1).min(motion::lines(text) - 1);
            return Ok((lines(line, last), true));
        }
        Target::Object(object) => {
            return object::range(text, at, object, count)
                .map(|found| (found, object.linewise()))
                .ok_or("No text object here");
        }
        Target::Motion(motion) => motion,
    };
    let mut motion = vim.resolve(motion).ok_or("No previous find")?;
    // `cw` on a word changes to its end, like `ce`.
    let change_word =
        op == Operator::Change && motion == Motion::Word && !motion::is_blank(text, at);
    if change_word {
        motion = Motion::EndWord;
    }
    let count = if count == usize::MAX {
        motion::lines(text)
    } else {
        count
    };
    let end = if change_word {
        motion::change_word_end(text, at, count)
    } else {
        motion::endpoint(
            text,
            at,
            motion,
            count,
            &mut None,
            document.whitespace().tab_width,
        )
        .ok_or("Motion failed")?
    };
    if (matches!(motion, Motion::Up | Motion::Down) && text.line_of(end).unwrap() == line)
        || (matches!(motion, Motion::BackWord) && end == at)
    {
        return Err("Motion reached a buffer boundary");
    }
    let (start, stop) = (at.min(end), at.max(end));
    let (first, last) = (text.line_of(start).unwrap(), text.line_of(stop).unwrap());
    let mut kind = motion::kind(motion);
    // `}` without an empty line after it reaches the last character.
    if motion == (Motion::Paragraph { forward: true }) && !motion::is_empty_line(text, last) {
        kind = Kind::Inclusive;
    }
    Ok(match kind {
        Kind::Linewise => (lines(first, last), true),
        _ if motion == Motion::Right => {
            let mut end = at;
            for _ in 0..count {
                end = motion::next(text, end).min(range.end);
            }
            (at..end, false)
        }
        _ if motion == Motion::Word => {
            let before = if count > 1 {
                motion::word(text, at, motion, count - 1)
            } else {
                at
            };
            let mut end = motion::word(text, before, motion, 1);
            if text.line_of(end).unwrap() > text.line_of(before).unwrap() {
                end = text
                    .line_content_range(text.line_of(before).unwrap())
                    .unwrap()
                    .end
                    .max(at);
            }
            (at..end, false)
        }
        Kind::Inclusive => (
            start..motion::next(text, stop).min(text.line_content_range(last).unwrap().end),
            false,
        ),
        // An exclusive motion ending at a line start stops at the end of
        // the line before, and covers whole lines if it started before
        // the first non-blank.
        Kind::Exclusive if last > first && text.line_start(last) == Some(stop) => {
            if start <= motion::first(text, first) {
                (lines(first, last - 1), true)
            } else {
                (start..text.line_content_range(last - 1).unwrap().end, false)
            }
        }
        Kind::Exclusive => (start..stop, false),
    })
}
fn convert_case(text: &str, op: Operator) -> String {
    match op {
        Operator::Lower => text.to_lowercase(),
        Operator::Upper => text.to_uppercase(),
        _ => text
            .chars()
            .flat_map(|ch| {
                let swapped: Vec<char> = if ch.is_lowercase() {
                    ch.to_uppercase().collect()
                } else {
                    ch.to_lowercase().collect()
                };
                swapped
            })
            .collect(),
    }
}
/// Shifting and case operators: one edit, caret at the first non-blank of
/// the first line for shifts and line ranges, else at the start.
fn transform(
    text: &Snapshot,
    range: Range<usize>,
    linewise: bool,
    op: Operator,
    levels: usize,
    document: &crate::editor::Document,
) -> Transaction {
    let first = text.line_of(range.start).unwrap();
    let start = text.line_start(first).unwrap();
    let lead = motion::first(text, first) - start;
    let (changes, caret) = match op {
        Operator::Indent | Operator::Outdent => {
            let last = text
                .line_of(range.end.saturating_sub(1).max(range.start))
                .unwrap();
            let changes = crate::editor::shift_lines(
                text,
                first..=last,
                op == Operator::Outdent,
                levels,
                &document.whitespace(),
                true,
            );
            let lead = changes
                .first()
                .filter(|change| change.range.start == start)
                .map_or(lead, |change| change.insert.len());
            (changes, start + lead)
        }
        _ => {
            let original = text.byte_slice(range.clone()).unwrap().to_string();
            let converted = convert_case(&original, op);
            let caret = if linewise { start + lead } else { range.start };
            let changes = if converted == original {
                vec![]
            } else {
                vec![Change::new(range, converted)]
            };
            (changes, caret)
        }
    };
    let mut tx = Transaction::new(text.version(), changes);
    tx.selection = Some(Selection::caret(caret));
    tx
}
/// Joins `count` lines from `first` as `J` does: leading blanks of each
/// joined line become one space, or none after blanks, before `)` or
/// around an empty line. The caret goes where the last join happened.
fn join(text: &Snapshot, first: usize, count: usize) -> Option<Transaction> {
    let last_line = motion::lines(text) - 1;
    if first >= last_line {
        return None;
    }
    let end = (first + count - 1).min(last_line);
    let content = |line: usize| {
        text.byte_slice(text.line_content_range(line).unwrap())
            .unwrap()
            .to_string()
    };
    let mut joined = content(first);
    let mut changes = vec![];
    let mut caret = 0;
    let mut delta = 0isize;
    for line in first..end {
        let from = text.line_content_range(line).unwrap().end;
        let to = motion::first(text, line + 1);
        let next = text
            .byte_slice(to..text.line_content_range(line + 1).unwrap().end)
            .unwrap()
            .to_string();
        let space = !joined.is_empty()
            && !joined.ends_with([' ', '\t'])
            && !next.is_empty()
            && !next.starts_with(')');
        let separator = if space { " " } else { "" };
        caret = (from as isize + delta) as usize;
        delta += separator.len() as isize - (to - from) as isize;
        changes.push(Change::new(from..to, separator));
        joined.push_str(separator);
        joined.push_str(&next);
    }
    let mut tx = Transaction::new(text.version(), changes);
    tx.selection = Some(Selection::caret(caret));
    Some(tx)
}
/// Where `n` or `N` lands after `count` matches from `from`, wrapping
/// around the buffer.
fn search_from(
    query: &SearchQuery,
    text: &Snapshot,
    from: usize,
    backward: bool,
    count: usize,
) -> usize {
    let mut caret = from;
    for _ in 0..count.min(10000) {
        let found = if backward {
            query
                .cursor(text)
                .filter(|range| range.start < caret)
                .last()
                .or_else(|| query.cursor(text).last())
        } else {
            query
                .cursor(text)
                .find(|range| range.start > caret)
                .or_else(|| query.cursor(text).next())
        };
        if let Some(found) = found {
            caret = found.start;
        }
    }
    caret
}
pub(in crate::interaction) fn visual_selection(
    text: &crate::core::Snapshot,
    anchor: usize,
    head: usize,
    linewise: bool,
) -> Selection {
    let range = if linewise {
        text.line_start(text.line_of(anchor.min(head)).unwrap())
            .unwrap()
            ..text
                .line_range(text.line_of(anchor.max(head)).unwrap())
                .unwrap()
                .end
    } else {
        anchor.min(head)..motion::next(text, anchor.max(head))
    };
    if head >= anchor {
        Selection {
            anchor: range.start,
            head: range.end,
        }
    } else {
        Selection {
            anchor: range.end,
            head: range.start,
        }
    }
}
