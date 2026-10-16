//! Plans cursor changes and register operations; Application owns execution.
use super::{Insert, Motion, Operator, VimCommand, motion};
use crate::{
    application::{Application, ClipboardAction, Event},
    core::{Change, Selection, Transaction},
    editor::Command as Edit,
    interaction::{EditMode, Layers, Message, Response},
};
use std::time::Duration;
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
            | VimCommand::RepeatSearch { count: n, .. } => n,
            _ => 1,
        };
        let sentinel = count == usize::MAX
            && matches!(
                command,
                VimCommand::Move(Motion::Bottom, _)
                    | VimCommand::Operate(_, Some(Motion::Bottom), _)
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
                let head = motion::endpoint(
                    text,
                    at,
                    motion,
                    count,
                    &mut self.vim.goal,
                    document.whitespace().tab_width,
                );
                if let Some((anchor, _)) = self.vim.visual {
                    self.vim.visual = Some((anchor, head));
                    response
                        .events
                        .push(event(Edit::SetSelection(visual_selection(
                            text,
                            anchor,
                            head,
                            self.mode == EditMode::VisualLine,
                        ))));
                } else {
                    response
                        .events
                        .push(event(Edit::SetSelection(Selection::caret(head))));
                }
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
            VimCommand::Operate(op, motion, count) => {
                let linewise = if self.vim.visual.is_some() {
                    self.mode == EditMode::VisualLine
                } else {
                    motion.is_none()
                        || matches!(
                            motion,
                            Some(Motion::Up | Motion::Down | Motion::Top | Motion::Bottom)
                        )
                };
                let mut operated = if self.vim.visual.is_some() {
                    selection.range()
                } else if let Some(mut motion) = motion {
                    let change_word = op == Operator::Change
                        && motion == Motion::Word
                        && !motion::is_blank(text, at);
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
                    };
                    if (matches!(motion, Motion::Up | Motion::Down)
                        && text.line_of(end).unwrap() == line)
                        || (matches!(motion, Motion::BackWord) && end == at)
                    {
                        response.message = Message::Set("Motion reached a buffer boundary".into());
                        return response;
                    }
                    if linewise {
                        let endline = text.line_of(end).unwrap();
                        let firstline = line.min(endline);
                        let lastline = line.max(endline);
                        text.line_start(firstline).unwrap()..text.line_range(lastline).unwrap().end
                    } else if motion == Motion::Right {
                        let mut end = at;
                        for _ in 0..count {
                            end = motion::next(text, end).min(range.end);
                        }
                        at..end
                    } else if motion == Motion::Word {
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
                        at..end
                    } else {
                        at.min(end)..if matches!(motion, Motion::End | Motion::EndWord) {
                            motion::next(text, at.max(end)).min(
                                text.line_content_range(text.line_of(at.max(end)).unwrap())
                                    .unwrap()
                                    .end,
                            )
                        } else {
                            at.max(end)
                        }
                    }
                } else {
                    text.line_start(line).unwrap()
                        ..text
                            .line_range((line + count - 1).min(motion::lines(text) - 1))
                            .unwrap()
                            .end
                };
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
                        },
                        time,
                    });
                }
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
                    response.events.push(Event::Clipboard {
                        view: view.id,
                        action: ClipboardAction::Operate {
                            range: range.clone(),
                            linewise: false,
                            edit: Some(Change::new(range.clone(), "")),
                            selection: Selection::caret(range.start),
                        },
                        time,
                    });
                }
            }
            VimCommand::Put { before, count } => response.events.push(Event::Clipboard {
                view: view.id,
                action: ClipboardAction::Put { before, count },
                time,
            }),
            VimCommand::Search { backward } => {
                self.vim.search_backward = backward;
                response.message =
                    Message::Set("Search must be started through the command reducer".into());
            }
            VimCommand::RepeatSearch { reverse, count } => {
                if let Some(query) = self.vim.last_search.as_ref() {
                    let backward = self.vim.search_backward ^ reverse;
                    let mut caret = at;
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
                    response
                        .events
                        .push(event(Edit::SetSelection(Selection::caret(caret))));
                } else {
                    response.message = Message::Set("No previous search".into());
                }
            }
        }
        response
    }
}
fn visual_selection(
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
