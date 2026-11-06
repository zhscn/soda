//! Jumps chosen by on-screen labels, after avy and ace-window. `jump-to`
//! reads two characters, labels where they occur in the lines every window
//! shows, and goes to the labelled one; `window-pick` labels the windows and
//! focuses one. A single candidate is taken at once. `flash` and
//! `flash-structure` label as flash.nvim does; see `flash`.
use super::{
    Command, Input, InputKey, Message, Presentation, Response,
    flash::{Flash, GROUP_LABELS, Structure},
    session::Transition,
};
use crate::{
    application::{Application, Event, ViewId},
    core::Selection,
    editor::Command as Edit,
    language::Group,
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
    /// Where the label shows, when not at `offset`.
    pub marks: Vec<usize>,
}
pub struct LabelSession {
    mode: Mode,
    view: ViewId,
    targets: Vec<Target>,
    typed: String,
}
enum Mode {
    /// The characters to find while they are still being typed, and the
    /// windows to search with their rows, the active one first so that it
    /// gets the easiest labels.
    Jump {
        query: String,
        windows: Vec<(ViewId, usize)>,
    },
    Windows,
    Flash(Box<Flash>),
    Structure(Structure),
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
    /// Starts a jump from the active view over the lines each window shows.
    pub(super) fn jump(view: ViewId, windows: Vec<(ViewId, usize)>) -> Self {
        Self {
            mode: Mode::Jump {
                query: String::new(),
                windows,
            },
            view,
            targets: vec![],
            typed: String::new(),
        }
    }
    /// Starts flash's search from the caret over the lines each window
    /// shows, the active one first.
    pub(super) fn flash(view: ViewId, caret: usize, windows: Vec<(ViewId, usize)>) -> Self {
        Self {
            mode: Mode::Flash(Box::new(Flash::new(view, caret, windows))),
            view,
            targets: vec![],
            typed: String::new(),
        }
    }
    /// Labels the groups around the caret, innermost first, and selects
    /// the innermost; the response does that.
    pub(super) fn structure(
        view: ViewId,
        groups: Vec<Group>,
        original: Selection,
        time: Duration,
    ) -> (Self, Response) {
        let targets = groups
            .iter()
            .zip(GROUP_LABELS.chars())
            .map(|(group, label)| Target {
                label: label.to_string(),
                view,
                offset: Some(group.open.start),
                marks: vec![group.open.start, group.close.start],
            })
            .collect();
        let structure = Structure {
            view,
            groups,
            current: 0,
            original,
        };
        let response = select(view, structure.selection(0), time);
        let session = Self {
            mode: Mode::Structure(structure),
            view,
            targets,
            typed: String::new(),
        };
        (session, response)
    }
    /// The search, while flash's is open.
    pub fn flash_search(&self) -> Option<&Flash> {
        match &self.mode {
            Mode::Flash(flash) => Some(flash),
            _ => None,
        }
    }
    /// Each label as it shows: in a view, at a place in its text or, for a
    /// window, at its corner, with the part still to type.
    pub fn placements(&self) -> Vec<(ViewId, Option<usize>, String)> {
        match &self.mode {
            Mode::Flash(flash) => flash
                .matches()
                .iter()
                .filter_map(|m| Some((m.view, Some(flash.mark(m)?), m.label?.to_string())))
                .collect(),
            _ => self
                .targets()
                .flat_map(|(target, rest)| {
                    let marks = match (&target.marks[..], target.offset) {
                        ([], Some(offset)) => vec![Some(offset)],
                        ([], None) => vec![None],
                        (marks, _) => marks.iter().copied().map(Some).collect(),
                    };
                    let text = match target.offset {
                        Some(_) => rest.to_owned(),
                        None => format!(" {rest} "),
                    };
                    marks
                        .into_iter()
                        .map(move |at| (target.view, at, text.clone()))
                })
                .collect(),
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
                marks: vec![],
            })
            .collect();
        Ok(Self {
            mode: Mode::Windows,
            view: active.unwrap(),
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
        let text = match &self.mode {
            Mode::Jump { query, .. } if self.targets.is_empty() => format!("jump: {query}"),
            Mode::Jump { query, .. } => format!("jump: {query} · label {}", self.typed),
            Mode::Windows => format!("window: {}", self.typed),
            Mode::Flash(flash) => format!("flash: {}", flash.query()),
            Mode::Structure(_) => "group: label, ; out, , in, RET keeps".to_owned(),
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
            Transition::Active(Response::default())
        }
    }
    pub(super) fn handle(&mut self, input: Input, app: &Application, time: Duration) -> Transition {
        match &mut self.mode {
            Mode::Flash(flash) => return flash_input(flash, self.view, input, app, time),
            Mode::Structure(structure) => {
                return structure_input(structure, &self.targets, input, app, time);
            }
            _ => {}
        }
        let ch = match input {
            Input::Text(InputKey::Char(ch)) => ch,
            Input::Text(InputKey::Delete { backward: true, .. }) if !self.typed.is_empty() => {
                self.typed.pop();
                return Transition::redraw();
            }
            Input::Cancel => return Transition::close(),
            _ => return Transition::Blocked,
        };
        if let Mode::Jump { query, windows } = &mut self.mode
            && self.targets.is_empty()
        {
            query.push(ch);
            if query.chars().count() < 2 {
                return Transition::redraw();
            }
            let query = query.clone();
            let mut found: Vec<_> = windows
                .iter()
                .flat_map(|(view, rows)| find(app, *view, *rows, &query))
                .collect();
            found.truncate(LETTERS.len() * LETTERS.len());
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
                    marks: vec![],
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
        take(self.view, view, offset, time)
    }
}
/// Goes to a target: its window, and the caret to its place.
fn take(from: ViewId, view: ViewId, offset: Option<usize>, time: Duration) -> Transition {
    let mut events = vec![];
    if view != from || offset.is_none() {
        events.push(Event::Focus(view));
    }
    if let Some(offset) = offset {
        events.push(Event::Edit {
            view,
            command: Edit::SetSelection(Selection::caret(offset)),
            time,
        });
    }
    Transition::Closed(Response {
        events,
        redraw: true,
        ..Response::default()
    })
}
/// A key in flash's search, as flash.nvim's `step`: a label goes to its
/// match, Enter to the current one; anything else goes on with the query,
/// and a query that matches nothing ends the search.
fn flash_input(
    flash: &mut Flash,
    from: ViewId,
    input: Input,
    app: &Application,
    time: Duration,
) -> Transition {
    let go = |m: &super::flash::Match| take(from, m.view, Some(m.range.start), time);
    match input {
        Input::Text(InputKey::Char(ch)) => {
            if let Some(m) = flash.labelled(ch) {
                return go(m);
            }
            flash.push(ch, app);
            if flash.matches().is_empty() {
                return Transition::close();
            }
            Transition::redraw()
        }
        Input::Text(InputKey::Delete { backward: true, .. }) => {
            flash.pop(app);
            Transition::redraw()
        }
        Input::Confirm => flash.current().map_or_else(Transition::close, go),
        Input::Cancel => Transition::close(),
        _ => Transition::Blocked,
    }
}
/// A key while the groups around the caret are labelled: `;` selects the
/// one outside, `,` the one inside, a label its group; Enter keeps the
/// selection and Esc goes back to the one before.
fn structure_input(
    structure: &mut Structure,
    targets: &[Target],
    input: Input,
    app: &Application,
    time: Duration,
) -> Transition {
    let view = structure.view;
    let last = structure.groups.len() - 1;
    let chosen = match input {
        Input::Text(InputKey::Char(';')) => {
            structure.current = (structure.current + 1).min(last);
            return Transition::Active(select(view, structure.selection(structure.current), time));
        }
        Input::Text(InputKey::Char(',')) => {
            structure.current = structure.current.saturating_sub(1);
            return Transition::Active(select(view, structure.selection(structure.current), time));
        }
        Input::Text(InputKey::Char(ch)) => {
            let label = ch.to_string();
            match targets.iter().position(|target| target.label == label) {
                Some(index) => index,
                None => return message(format!("No label {ch}")),
            }
        }
        Input::Confirm => structure.current,
        Input::Cancel => {
            let mut response = select(view, structure.original, time);
            response.redraw = true;
            return Transition::Closed(response);
        }
        _ => return Transition::Blocked,
    };
    let selection = structure.selection(chosen);
    // With modal editing the group is a block, for `o` to go on outward.
    let response = if super::modal_on(app) {
        Response {
            commands: vec![Command::Modal(super::modal::Action::Found {
                anchor: selection.anchor,
                head: selection.head,
                kind: super::modal::Kind::Block,
                expand: true,
            })],
            redraw: true,
            ..Response::default()
        }
    } else {
        select(view, selection, time)
    };
    Transition::Closed(response)
}
fn select(view: ViewId, selection: Selection, time: Duration) -> Response {
    Response {
        events: vec![Event::Edit {
            view,
            command: Edit::SetSelection(selection),
            time,
        }],
        redraw: true,
        ..Response::default()
    }
}
fn message(text: String) -> Transition {
    Transition::Closed(Response {
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
