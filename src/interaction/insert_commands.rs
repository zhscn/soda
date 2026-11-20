//! Insertion through completions and snippets.
use super::{Layers, Response};
use crate::{
    application::{Application, Event},
    editor::Command as EditCommand,
};
use std::time::Duration;

#[derive(Clone, Debug)]
pub enum InsertCommand {
    Completion(super::completion::Action),
    /// Inserts a snippet at the caret.
    Snippet(String),
    SnippetStep {
        backward: bool,
    },
}

impl Layers {
    pub(super) fn execute_insert(
        &mut self,
        command: InsertCommand,
        app: &Application,
        time: Duration,
        response: &mut Response,
    ) {
        match command {
            InsertCommand::Completion(action) => {
                use super::completion::Action;
                match action {
                    Action::Trigger => self.completion.trigger(),
                    Action::Dismiss => self.completion.dismiss(app),
                    Action::Move { backward } => self.completion.step(backward),
                    Action::Accept | Action::Replace => {
                        let replace = action == Action::Replace;
                        if let Some(accepted) = self.completion.accept(replace, app) {
                            self.accept(accepted, app, time, response);
                        }
                    }
                }
            }
            InsertCommand::Snippet(body) => {
                if let Some(view) = app.active_view()
                    && let Some(session) = app.view(view)
                {
                    let editor = app.workspace().editor(session.document_id).unwrap();
                    let selection = editor
                        .model()
                        .session(session.session_id)
                        .unwrap()
                        .selection();
                    let range = selection.range();
                    let selected = !range.is_empty();
                    // Its places are filled in Insert.
                    if self.mode == super::EditMode::Normal && !self.modal.active() {
                        self.modal.insert_view = Some(view);
                        self.mode = super::EditMode::Insert;
                        self.modal.tag = None;
                        response.events.push(Event::Edit {
                            view,
                            command: EditCommand::BeginUndoGroup(selection),
                            time,
                        });
                    }
                    self.expand_snippet(view, range, vec![], &body, selected, app, time, response);
                }
            }
            InsertCommand::SnippetStep { backward } => {
                if let Some((view, selection)) = self.snippet.step(backward)
                    && let Some(state) = app.view(view)
                {
                    // Not a move of its own: filling a snippet is one undo step.
                    let version = app
                        .workspace()
                        .editor(state.document_id)
                        .unwrap()
                        .model()
                        .document()
                        .snapshot()
                        .version();
                    let mut tx = crate::core::Transaction::new(version, vec![]);
                    tx.selection = Some(selection);
                    response.events.push(Event::Edit {
                        view,
                        command: EditCommand::Apply(tx),
                        time,
                    });
                }
            }
        }
    }
}

/// How far changes before `at` move it: in bytes, and in lines.
fn shift(text: &str, changes: &[crate::core::Change], at: usize) -> (isize, isize) {
    let mut bytes = 0isize;
    let mut lines = 0isize;
    for change in changes.iter().filter(|change| change.range.end <= at) {
        let removed = &text[change.range.clone()];
        bytes += change.insert.len() as isize - removed.len() as isize;
        lines +=
            change.insert.matches('\n').count() as isize - removed.matches('\n').count() as isize;
    }
    (bytes, lines)
}
impl Layers {
    /// Puts a candidate in the document, and records for `.` and macros the
    /// keys that would have typed it: their replays do not complete.
    fn accept(
        &mut self,
        accepted: super::completion::Accepted,
        app: &Application,
        time: Duration,
        response: &mut Response,
    ) {
        use super::{Key, KeyStroke, UserInput};
        use crate::core::{Change, Selection, Transaction};
        let super::completion::Accepted {
            view,
            edits,
            range,
            caret,
            selected,
            text,
            snippet,
        } = accepted;
        let document = app.view(view).unwrap().document_id;
        let editor = app.workspace().editor(document).unwrap();
        let snapshot = editor.model().document().snapshot();
        let whole = snapshot.text();
        let before = whole[range.start..caret].chars().count();
        let after = whole[selected..range.end].chars().count();
        for key in std::iter::repeat_n(Key::Backspace, before)
            .chain(std::iter::repeat_n(Key::Delete, after))
        {
            self.modal
                .replay
                .record(UserInput::Key(KeyStroke::plain(key)));
        }
        // A snippet replays as one, so that its places are filled again.
        let typed = if snippet {
            let snippet = text.clone();
            self.expand_snippet(view, range, edits, &text, false, app, time, response);
            UserInput::Snippet(snippet)
        } else {
            let start = range
                .start
                .saturating_add_signed(shift(whole, &edits, range.start).0);
            let mut changes = edits;
            changes.push(Change::new(range, text.clone()));
            let mut tx = Transaction::new(snapshot.version(), changes);
            tx.selection = Some(Selection::caret(start + text.len()));
            response.events.push(Event::Edit {
                view,
                command: EditCommand::Apply(tx),
                time,
            });
            UserInput::Paste(text)
        };
        self.modal.replay.record(typed);
    }
    /// Expands a snippet in place of a range as one undoable step, with
    /// other edits. Lines after the first get the language's indentation.
    /// `selected` says the range is the selection, for `TM_SELECTED_TEXT`.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn expand_snippet(
        &mut self,
        view: crate::application::ViewId,
        range: std::ops::Range<usize>,
        edits: Vec<crate::core::Change>,
        body: &str,
        selected: bool,
        app: &Application,
        time: Duration,
        response: &mut Response,
    ) {
        use crate::core::{Change, Selection, Transaction};
        let document = app.view(view).unwrap().document_id;
        let model = app.workspace().editor(document).unwrap().model().document();
        let snapshot = model.snapshot();
        let line = snapshot.line_of(range.start).unwrap();
        let indent = snapshot.leading_whitespace(line).unwrap().to_string();
        let style = model.whitespace();
        let unit = crate::language::materialize(style.indent_width, 0, style.indent_width, &style);
        let values = super::snippet::variables(app, document, range.clone(), selected);
        let parsed = super::snippet::parse_with(body, &|name| values.get(name).cloned())
            .indented(&indent, &unit);
        let depth = model.history_depth();
        let first = parsed.stops[0].range.clone();
        // Where the snippet lands once the edits before it are made.
        let (bytes, lines) = shift(snapshot.text(), &edits, range.start);
        let start = range.start.saturating_add_signed(bytes);
        let line = line.saturating_add_signed(lines);
        let mut changes = edits;
        changes.push(Change::new(range.clone(), parsed.text.clone()));
        let mut tx = Transaction::new(snapshot.version(), changes);
        tx.selection = Some(Selection {
            anchor: start + first.start,
            head: start + first.end,
        });
        let lines = parsed.lines();
        let event = |command| Event::Edit {
            view,
            command,
            time,
        };
        response.events.push(event(EditCommand::Apply(tx)));
        if lines > 0 {
            for line in line..=line + lines {
                response.events.push(event(EditCommand::Reindent(line)));
            }
            response
                .events
                .push(event(EditCommand::SquashHistory(depth)));
        }
        self.snippet.pending = Some(super::snippet::Pending {
            view,
            document,
            offset: start,
            stops: parsed.stops,
        });
    }
}
