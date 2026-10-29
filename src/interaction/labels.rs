//! Jumps chosen by on-screen labels, after avy and ace-window. `jump-to`
//! reads two characters, labels where they occur in the lines the window
//! shows, and moves the caret to the labelled one; `window-pick` labels the
//! windows and focuses one. A single candidate is taken at once.
use super::{Input, InputKey, Message, Presentation, Response, session::Transition};
use crate::{
    application::{Application, Event, ViewId},
    core::Selection,
    editor::Command as Edit,
};
use std::time::Duration;

/// Label letters, home row first.
const LETTERS: &str = "asdfghjklqwertyuiopzxcvbnm";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Target {
    pub label: String,
    pub view: ViewId,
    /// Where the caret goes; none for a window.
    pub offset: Option<usize>,
}
pub struct LabelSession {
    /// The characters to find while they are still being typed.
    query: Option<String>,
    view: ViewId,
    rows: usize,
    targets: Vec<Target>,
    typed: String,
}
/// Labels of one length, enough for `count` targets; two letters beyond
/// the alphabet, so no label is a prefix of another.
fn labels(count: usize) -> Vec<String> {
    let letters: Vec<char> = LETTERS.chars().collect();
    if count <= letters.len() {
        return letters.iter().take(count).map(char::to_string).collect();
    }
    letters
        .iter()
        .flat_map(|a| letters.iter().map(move |b| format!("{a}{b}")))
        .take(count)
        .collect()
}
impl LabelSession {
    /// Starts a jump in the active view over `rows` shown lines.
    pub(super) fn jump(view: ViewId, rows: usize) -> Self {
        Self {
            query: Some(String::new()),
            view,
            rows,
            targets: vec![],
            typed: String::new(),
        }
    }
    /// Labels every window. With two, the error is the other one to take
    /// at once; with one, there is none.
    pub(super) fn windows(app: &Application) -> Result<Self, Option<ViewId>> {
        let views = app.windows().views();
        let active = app.active_view();
        let others: Vec<_> = views.iter().filter(|v| Some(**v) != active).collect();
        if others.len() <= 1 {
            return Err(others.first().map(|view| **view));
        }
        let targets = views
            .iter()
            .zip(labels(views.len()))
            .map(|(view, label)| Target {
                label,
                view: *view,
                offset: None,
            })
            .collect();
        Ok(Self {
            query: None,
            view: active.unwrap(),
            rows: 0,
            targets,
            typed: String::new(),
        })
    }
    /// Labels not yet ruled out, with the part still to type.
    pub fn targets(&self) -> impl Iterator<Item = (&Target, &str)> {
        self.targets
            .iter()
            .filter(|target| target.label.starts_with(&self.typed))
            .map(|target| (target, &target.label[self.typed.len()..]))
    }
    pub(super) fn presentation(&self) -> Presentation {
        let text = match &self.query {
            Some(query) if self.targets.is_empty() => format!("jump: {query}"),
            Some(query) => format!("jump: {query} · label {}", self.typed),
            None => format!("window: {}", self.typed),
        };
        Presentation {
            cursor: Some(text.len()),
            selection: 0..0,
            text,
        }
    }
    /// Labels point into the text and the windows as they were.
    pub(super) fn observe(&self, update: &crate::application::Update) -> Transition {
        if update.active_changed
            || update.windows_changed
            || update.edit.as_ref().is_some_and(|edit| edit.text_changed)
        {
            Transition::close()
        } else {
            Transition::active(Response::default())
        }
    }
    pub(super) fn handle(&mut self, input: Input, app: &Application, time: Duration) -> Transition {
        let ch = match input {
            Input::Text(InputKey::Char(ch)) => ch,
            Input::Text(InputKey::Delete { backward: true, .. }) if !self.typed.is_empty() => {
                self.typed.pop();
                return Transition::redraw();
            }
            Input::Cancel => return Transition::close(),
            _ => return Transition::Blocked,
        };
        if let Some(query) = self.query.as_mut().filter(|_| self.targets.is_empty()) {
            query.push(ch);
            if query.chars().count() < 2 {
                return Transition::redraw();
            }
            let query = query.clone();
            let found = find(app, self.view, self.rows, &query);
            match found.len() {
                0 => return message(format!("No {query} on screen")),
                1 => return self.take(found[0].0, Some(found[0].1), time),
                _ => {}
            }
            self.targets = found
                .iter()
                .zip(labels(found.len()))
                .map(|((view, offset), label)| Target {
                    label,
                    view: *view,
                    offset: Some(*offset),
                })
                .collect();
            return Transition::redraw();
        }
        self.typed.push(ch);
        let left: Vec<_> = self.targets().map(|(t, _)| t.clone()).collect();
        match left.as_slice() {
            [] => message(format!("No label {}", self.typed)),
            [target] if target.label == self.typed => self.take(target.view, target.offset, time),
            _ => Transition::redraw(),
        }
    }
    fn take(&self, view: ViewId, offset: Option<usize>, time: Duration) -> Transition {
        let mut events = vec![];
        if Some(view) != Some(self.view) || offset.is_none() {
            events.push(Event::Focus(view));
        }
        if let Some(offset) = offset {
            events.push(Event::Edit {
                view,
                command: Edit::SetSelection(Selection::caret(offset)),
                time,
            });
        }
        Transition::finished(Response {
            events,
            redraw: true,
            ..Response::default()
        })
    }
}
fn message(text: String) -> Transition {
    Transition::finished(Response {
        message: Message::Set(text),
        redraw: true,
        ..Response::default()
    })
}
/// Where `query` starts in the lines a view shows, top to bottom; case is
/// ignored unless the query has capitals.
fn find(app: &Application, view: ViewId, rows: usize, query: &str) -> Vec<(ViewId, usize)> {
    let Some(state) = app.view(view) else {
        return vec![];
    };
    let editor = app.workspace().editor(state.document_id).unwrap();
    let snapshot = editor.model().document().snapshot();
    let top = snapshot
        .line_of(state.viewport.anchor.offset.0)
        .unwrap_or(0);
    let bottom = top.saturating_add(rows.max(1)).min(snapshot.text_lines());
    let fold = !query.chars().any(char::is_uppercase);
    let query = if fold {
        query.to_lowercase()
    } else {
        query.to_owned()
    };
    let mut found = vec![];
    for line in top..bottom {
        let start = snapshot.line_start(line).unwrap();
        let text = snapshot.line(line).unwrap_or_default();
        let text = if fold {
            text.to_lowercase()
        } else {
            text.into_owned()
        };
        // Lowercasing can change lengths; offsets are taken only where it
        // did not.
        if text.len() != snapshot.line_range(line).unwrap().len()
            && text.len() != snapshot.line_content_range(line).unwrap().len()
        {
            continue;
        }
        found.extend(text.match_indices(&query).map(|(at, _)| (view, start + at)));
    }
    found.truncate(LETTERS.len() * LETTERS.len());
    found
}

#[cfg(test)]
mod tests {
    #[test]
    fn labels_grow_to_two_letters_without_prefixes() {
        assert_eq!(super::labels(3), ["a", "s", "d"]);
        let many = super::labels(30);
        assert_eq!(many.len(), 30);
        assert!(many.iter().all(|label| label.len() == 2));
        assert_eq!(many[0], "aa");
    }
}
