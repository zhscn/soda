//! Search and replace: a document-bound preview session. Retained anchors
//! follow document updates; matching ranges are recomputed from the current
//! snapshot rather than mapped. Replacing is search with two more steps:
//! the replacement, then a review that asks at each match, as Emacs's
//! query-replace does; edits run only as the user answers.
use super::{
    Input, Presentation, Response, TextInput,
    session::{Transition, edit_field, field_presentation},
};
use crate::{
    application::{Application, Event, Update, ViewId, Viewport},
    core::{Association, ByteOffset, EditError, Selection},
    editor::{Command, DocumentPosition, search::SearchQuery},
};
use std::{ops::Range, time::Duration};

pub struct SearchSession {
    view: ViewId,
    anchor: DocumentPosition,
    head: DocumentPosition,
    viewport: Viewport,
    query: SearchQuery,
    backward: bool,
    results: SearchResults,
    input: TextInput,
    /// Present while replacing.
    replace: Option<Replace>,
    /// Where `M-p` has recalled to in the search history.
    recall: super::history::Recall,
}
/// Where a replacement stands: the query is being typed, then the
/// replacement, then the matches are reviewed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    Query,
    Replacement,
    Review,
}
struct Replace {
    step: Step,
    replacement: String,
    /// Matches replaced so far in the review.
    replaced: usize,
    project: Project,
}
/// Whether a replacement goes over the files of the project, as Emacs's
/// `project-query-replace-regexp`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Project {
    /// Only the document.
    No,
    /// The query and the replacement are asked here, then the Runtime
    /// finds the files with matches.
    Ask,
    /// Reviewing one of those files; ending says where the loop goes.
    Loop,
}
/// A replacement over the project, once its query and replacement are
/// typed.
#[derive(Clone, Debug)]
pub struct ProjectReplace {
    pub query: String,
    pub replacement: String,
}
/// How the review of a file in a replacement over the project ended, and
/// how many matches it replaced.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LoopStep {
    pub replaced: usize,
    pub next: LoopNext,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LoopNext {
    /// On to the next file.
    File,
    /// Every match of the files left, without asking, as `Y`.
    All,
    Stop,
}
#[derive(Default)]
pub struct SearchResults {
    pub revision: u64,
    pub count: usize,
    pub current: Option<Range<usize>>,
}
impl SearchSession {
    /// Searches backward from the selection.
    pub fn backward(mut self) -> Self {
        self.backward = true;
        self
    }
    /// Replaces matches once a query and a replacement are given.
    pub fn replacing(mut self) -> Self {
        self.replace = Some(Replace {
            step: Step::Query,
            replacement: String::new(),
            replaced: 0,
            project: Project::No,
        });
        self
    }
    /// Asks the query and the replacement for the files of the project.
    pub fn across_project(mut self) -> Self {
        self = self.replacing();
        self.replace.as_mut().unwrap().project = Project::Ask;
        self
    }
    /// Reviews the matches of a file of a replacement over the project,
    /// from its start; with none, it ends at once.
    pub(super) fn reviewing(
        app: &Application,
        view: ViewId,
        query: SearchQuery,
        replacement: String,
        time: Duration,
    ) -> Result<(Self, Transition), EditError> {
        let mut session = Self::starting_at(app, view, 0)?;
        session.input = TextInput::new(query.text());
        session.query = query;
        session.replace = Some(Replace {
            step: Step::Review,
            replacement,
            replaced: 0,
            project: Project::Loop,
        });
        let transition = session.move_on(app, 0, time)?;
        Ok((session, transition))
    }
    fn project(&self) -> Project {
        self.replace
            .as_ref()
            .map_or(Project::No, |replace| replace.project)
    }
    pub fn is_replacing(&self) -> bool {
        self.replace.is_some()
    }
    /// The field being typed: the query, or the replacement.
    pub fn input(&self) -> &TextInput {
        &self.input
    }
    fn step(&self) -> Option<Step> {
        self.replace.as_ref().map(|replace| replace.step)
    }
    pub fn view(&self) -> ViewId {
        self.view
    }
    pub fn query(&self) -> &SearchQuery {
        &self.query
    }
    pub fn results(&self) -> &SearchResults {
        &self.results
    }
    pub fn set_query(&mut self, text: &str) {
        if text != self.query.text() {
            self.query = SearchQuery::new(text);
            self.results.current = None;
        }
    }

    /// A session whose origin, and the place cancelling restores, is the
    /// caret at `offset`.
    pub fn starting_at(app: &Application, view: ViewId, offset: usize) -> Result<Self, EditError> {
        let mut session = Self::new(app, view)?;
        let editor = app
            .workspace()
            .editor(app.view(view).ok_or(EditError::UnknownSession)?.document_id)
            .unwrap();
        let position = editor
            .model()
            .document()
            .position(ByteOffset(offset), Association::After)?;
        session.anchor = position;
        session.head = position;
        Ok(session)
    }
    /// Starts with a query given rather than typed, and the response that
    /// previews its first match.
    pub fn seeded(
        mut self,
        query: SearchQuery,
        app: &Application,
        time: Duration,
    ) -> Result<(Self, Response), EditError> {
        self.input = TextInput::new(query.text());
        self.query = query;
        let response = self.preview_response(app, self.backward, false, time)?;
        Ok((self, response))
    }
    pub fn new(app: &Application, view: ViewId) -> Result<Self, EditError> {
        let view_state = app.view(view).ok_or(EditError::UnknownSession)?;
        let editor = app.workspace().editor(view_state.document_id).unwrap();
        let selection = editor
            .model()
            .session(view_state.session_id)
            .unwrap()
            .selection();
        let document = editor.model().document();
        let anchor_association = if selection.anchor < selection.head {
            Association::Before
        } else {
            Association::After
        };
        let head_association = if selection.anchor > selection.head {
            Association::Before
        } else {
            Association::After
        };
        Ok(Self {
            view,
            anchor: document.position(ByteOffset(selection.anchor), anchor_association)?,
            head: document.position(ByteOffset(selection.head), head_association)?,
            viewport: view_state.viewport,
            query: SearchQuery::new(""),
            backward: false,
            results: SearchResults::default(),
            input: TextInput::default(),
            replace: None,
            recall: Default::default(),
        })
    }
    /// Returns false when the owning view closes. Missing revisions return an error.
    pub fn observe(&mut self, app: &Application, update: &Update) -> Result<bool, EditError> {
        if app.view(self.view).is_none() {
            return Ok(false);
        }
        if let Some(document) = update.edit.as_ref().and_then(|edit| edit.document.as_ref())
            && document.document_id == self.anchor.document_id
        {
            let anchor = self.anchor.map(document, false)?.unwrap();
            let head = self.head.map(document, false)?.unwrap();
            let viewport = self.viewport.anchor.map(document, false)?.unwrap();
            self.anchor = anchor;
            self.head = head;
            self.viewport.anchor = viewport;
            self.results.current = None;
        }
        Ok(true)
    }
    /// Query changes always search from the session origin. Navigation searches
    /// from the current match and wraps without changing that origin.
    pub fn preview(
        &mut self,
        app: &Application,
        backward: bool,
        advance: bool,
    ) -> Result<Command, EditError> {
        let view = app.view(self.view).ok_or(EditError::UnknownSession)?;
        let document = app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .document();
        let origin = self.head.resolve(document)?.0;
        let snapshot = document.snapshot();
        let boundary = if advance {
            self.results
                .current
                .as_ref()
                .map(|r| if backward { r.start } else { r.end })
                .unwrap_or(origin)
        } else {
            origin
        };
        let mut count = 0;
        let mut first = None;
        let mut last = None;
        let mut chosen = None;
        for range in self.query.cursor(snapshot) {
            count += 1;
            if first.is_none() {
                first = Some(range.clone());
            }
            if backward {
                if range.end <= boundary {
                    chosen = Some(range.clone());
                }
            } else if chosen.is_none() && range.start >= boundary {
                chosen = Some(range.clone());
            }
            last = Some(range);
        }
        let current = chosen.or(if backward { last } else { first });
        self.results = SearchResults {
            revision: snapshot.version(),
            count,
            current: current.clone(),
        };
        let selection = match current {
            Some(range) => Selection {
                anchor: range.start,
                head: range.end,
            },
            None => self.original_selection(app)?,
        };
        Ok(Command::SetSelection(selection))
    }
    fn original_selection(&self, app: &Application) -> Result<Selection, EditError> {
        let document = app
            .workspace()
            .editor(self.anchor.document_id)
            .ok_or(EditError::WrongDocument)?
            .model()
            .document();
        Ok(Selection {
            anchor: self.anchor.resolve(document)?.0,
            head: self.head.resolve(document)?.0,
        })
    }
    pub fn cancel(&self, app: &Application, time: Duration) -> Result<Vec<Event>, EditError> {
        let view = app.view(self.view).ok_or(EditError::UnknownSession)?;
        let document = app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .document();
        Ok(vec![
            Event::Edit {
                view: self.view,
                command: Command::SetSelection(self.original_selection(app)?),
                time,
            },
            Event::SetViewport {
                view: self.view,
                anchor: self.viewport.anchor.resolve(document)?,
                horizontal_scroll: self.viewport.horizontal_scroll,
            },
        ])
    }
}

impl SearchSession {
    pub(super) fn presentation(&self) -> Presentation {
        let label = match &self.replace {
            None => format!("Find [{}]: ", self.results.count),
            Some(Replace {
                step: Step::Query, ..
            }) => format!("Replace query [{}]: ", self.results.count),
            Some(Replace {
                step: Step::Replacement,
                ..
            }) => "Replacement: ".to_owned(),
            Some(Replace {
                step: Step::Review,
                replacement,
                ..
            }) => {
                let keys = if self.project() == Project::Loop {
                    "y/SPC replace, n/DEL skip, ! rest of file, N next file, Y all files, . last, q/RET quit"
                } else {
                    "y/SPC replace, n/DEL skip, ! rest, . last, q/RET quit, F4 all"
                };
                return Presentation {
                    text: format!(
                        "Query replacing {:?} with {:?} [{} matches]: {keys}",
                        self.query.text(),
                        replacement,
                        self.results.count
                    ),
                    cursor: None,
                    selection: 0..0,
                };
            }
        };
        let mut presentation = field_presentation(label, &self.input);
        if let Some(error) = self.query.error()
            && self.step() != Some(Step::Replacement)
        {
            presentation.text.push_str(&format!("  ({error})"));
        }
        presentation
    }
    fn cancel_response(&self, app: &Application, time: Duration) -> Result<Response, EditError> {
        Ok(Response {
            events: if app.view(self.view).is_some() {
                self.cancel(app, time)?
            } else {
                vec![]
            },
            redraw: true,
            ..Response::default()
        })
    }
    fn preview_response(
        &mut self,
        app: &Application,
        backward: bool,
        advance: bool,
        time: Duration,
    ) -> Result<Response, EditError> {
        let command = self.preview(app, backward, advance)?;
        if self.results.current.is_none() {
            return self.cancel_response(app, time);
        }
        Ok(Response {
            events: vec![Event::Edit {
                view: self.view,
                command,
                time,
            }],
            redraw: true,
            ..Response::default()
        })
    }
    /// Replaces the query with an older or newer search; None when there
    /// is none that way.
    pub(super) fn recall(
        &mut self,
        histories: &super::history::Histories,
        backward: bool,
        app: &Application,
        time: Duration,
    ) -> Result<Option<Transition>, EditError> {
        let name = super::history::SEARCH;
        let entries = histories.entries(name);
        let Some(text) = self
            .recall
            .step((name, 0), entries, self.input.text(), backward)
        else {
            return Ok(None);
        };
        let end = self.input.text().len();
        self.input.replace_range(0..end, &text);
        self.set_query(&text);
        Ok(Some(Transition::Active(self.preview_response(
            app,
            self.backward,
            false,
            time,
        )?)))
    }
    pub(super) fn handle(
        &mut self,
        input: Input,
        app: &Application,
        time: Duration,
    ) -> Result<Transition, EditError> {
        let set_query = |query: SearchQuery| Event::Edit {
            view: self.view,
            command: Command::SetSearchQuery(query),
            time,
        };
        Ok(match (self.step(), input) {
            (step, Input::Cancel) if step != Some(Step::Review) || self.replaced() == 0 => {
                let mut response = self.cancel_response(app, time)?;
                if self.project() == Project::Loop {
                    response
                        .commands
                        .push(effect(super::modal::Effect::FileLoop(LoopStep {
                            replaced: 0,
                            next: LoopNext::Stop,
                        })));
                }
                Transition::Closed(response)
            }
            (None, Input::Confirm) => Transition::Closed(Response {
                events: vec![set_query(self.query.clone())],
                redraw: true,
                ..Response::default()
            }),
            (Some(Step::Query), Input::Confirm) => {
                if !self.query.is_valid() {
                    return Ok(Transition::Active(Response::default()));
                }
                self.replace.as_mut().unwrap().step = Step::Replacement;
                self.input = TextInput::default();
                Transition::redraw()
            }
            (Some(Step::Replacement), Input::Confirm) if self.project() == Project::Ask => {
                // The files are reviewed one by one once they are found;
                // this document is left as it was.
                let mut response = self.cancel_response(app, time)?;
                response.message = super::Message::Keep;
                response
                    .commands
                    .push(effect(super::modal::Effect::ProjectReplace(
                        ProjectReplace {
                            query: self.query.text().to_owned(),
                            replacement: self.input.text().to_owned(),
                        },
                    )));
                Transition::Closed(response)
            }
            (Some(Step::Replacement), Input::Confirm) => {
                let replace = self.replace.as_mut().unwrap();
                replace.replacement = self.input.text().to_owned();
                replace.step = Step::Review;
                Transition::redraw()
            }
            (Some(Step::Review), input) if review(&input, self.project()).is_some() => {
                self.answer(review(&input, self.project()).unwrap(), app, time)?
            }
            (Some(Step::Replacement), Input::Navigate { .. }) => Transition::Blocked,
            // Leaving after replacing keeps what was replaced, and the
            // caret where the review stopped, as quitting query-replace.
            (Some(Step::Review), Input::Cancel) if self.replaced() > 0 => {
                self.answer(Answer::Quit, app, time)?
            }
            (_, Input::Navigate { backward }) => {
                Transition::Active(self.preview_response(app, backward, true, time)?)
            }
            (Some(Step::Review), _) => Transition::Blocked,
            (step, input) => match edit_field(&mut self.input, input) {
                Some(update) if update.text_changed && step != Some(Step::Replacement) => {
                    let text = self.input.text().to_owned();
                    self.set_query(&text);
                    Transition::Active(self.preview_response(app, self.backward, false, time)?)
                }
                Some(update) if update.text_changed || update.selection_changed => {
                    Transition::redraw()
                }
                _ => Transition::Blocked,
            },
        })
    }
    /// Follows a document update: closes with the view, gives up when
    /// another view takes focus, and searches again when the text changed.
    pub(super) fn follow(
        &mut self,
        app: &Application,
        update: &Update,
        time: Duration,
    ) -> Result<Transition, EditError> {
        if !self.observe(app, update)? {
            return Ok(Transition::close());
        }
        if app.active_view() != Some(self.view) {
            return Ok(Transition::Closed(self.cancel_response(app, time)?));
        }
        let changed = update.edit.as_ref().is_some_and(|edit| {
            edit.text_changed && edit.document_id == app.view(self.view).unwrap().document_id
        });
        // In the review the next match is after the caret, which the
        // replacement left after its text, so the text put in is never
        // asked about again.
        if changed && self.step() == Some(Step::Review) {
            let caret = self.caret(app)?;
            return self.move_on(app, caret, time);
        }
        if changed {
            return Ok(Transition::Active(self.preview_response(
                app,
                self.backward,
                false,
                time,
            )?));
        }
        Ok(Transition::Active(Response::default()))
    }
}

/// What the user answers at a match of the review.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Answer {
    /// `y`, `SPC`: replace it and go on.
    Replace,
    /// `n`, `DEL`: leave it and go on.
    Skip,
    /// `!`: replace it and every match after it.
    Rest,
    /// `.`: replace it and stop.
    Last,
    /// `q`, `RET`: stop.
    Quit,
    /// `F4`, `C-RET`: replace every match of the document.
    All,
    /// `N`, over the project: leave the rest of the file.
    NextFile,
    /// `Y`, over the project: replace every match left in every file.
    AllFiles,
}
fn review(input: &Input, project: Project) -> Option<Answer> {
    use super::InputKey;
    let across = project == Project::Loop;
    Some(match input {
        Input::Text(InputKey::Char('N')) if across => Answer::NextFile,
        Input::Text(InputKey::Char('Y')) if across => Answer::AllFiles,
        Input::Text(InputKey::Char('y' | ' ')) => Answer::Replace,
        Input::Text(InputKey::Char('n')) => Answer::Skip,
        Input::Text(InputKey::Delete { backward: true, .. }) => Answer::Skip,
        Input::Text(InputKey::Char('!')) => Answer::Rest,
        Input::Text(InputKey::Char('.')) => Answer::Last,
        Input::Text(InputKey::Char('q')) | Input::Confirm => Answer::Quit,
        Input::ReplaceAll => Answer::All,
        _ => return None,
    })
}
impl SearchSession {
    fn replaced(&self) -> usize {
        self.replace.as_ref().map_or(0, |replace| replace.replaced)
    }
    /// The caret of the session's view.
    fn caret(&self, app: &Application) -> Result<usize, EditError> {
        let view = app.view(self.view).ok_or(EditError::UnknownSession)?;
        let editor = app.workspace().editor(view.document_id).unwrap();
        let session = editor.model().session(view.session_id).unwrap();
        Ok(session.selection().head)
    }
    fn answer(
        &mut self,
        answer: Answer,
        app: &Application,
        time: Duration,
    ) -> Result<Transition, EditError> {
        let replacement = self.replace.as_ref().unwrap().replacement.clone();
        let current = self.results.current.clone();
        // With no match in hand only stopping is left to do.
        if current.is_none() && !matches!(answer, Answer::All) {
            return self.finish(vec![], LoopNext::File);
        }
        let edit = |command| Event::Edit {
            view: self.view,
            command,
            time,
        };
        let set_query = edit(Command::SetSearchQuery(self.query.clone()));
        let replace = self.replace.as_mut().unwrap();
        match answer {
            Answer::Replace => {
                replace.replaced += 1;
                // Following the edit moves on to the next match.
                Ok(Transition::Active(Response {
                    events: vec![set_query, edit(Command::ReplaceCurrent(replacement))],
                    redraw: true,
                    ..Response::default()
                }))
            }
            Answer::Skip => {
                let Some(current) = current else {
                    return self.finish(vec![], LoopNext::File);
                };
                // An empty match is passed by a character, so it is not
                // found again where it is.
                let from = if current.is_empty() {
                    next_char(app, self.view, current.end)
                } else {
                    current.end
                };
                self.move_on(app, from, time)
            }
            Answer::Last => {
                replace.replaced += 1;
                let events = vec![set_query, edit(Command::ReplaceCurrent(replacement))];
                self.finish(events, LoopNext::Stop)
            }
            Answer::Rest => {
                let rest = current.map_or(0, |current| self.count_from(app, current.start));
                self.replace.as_mut().unwrap().replaced += rest;
                let events = vec![set_query, edit(Command::ReplaceRest(replacement))];
                self.finish(events, LoopNext::File)
            }
            Answer::AllFiles => {
                let rest = current.map_or(0, |current| self.count_from(app, current.start));
                self.replace.as_mut().unwrap().replaced += rest;
                let events = vec![set_query, edit(Command::ReplaceRest(replacement))];
                self.finish(events, LoopNext::All)
            }
            Answer::All => {
                replace.replaced += self.results.count;
                let events = vec![set_query, edit(Command::ReplaceAll(replacement))];
                self.finish(events, LoopNext::File)
            }
            Answer::NextFile => {
                let caret = self.caret(app)?;
                let stay = edit(Command::SetSelection(Selection {
                    anchor: caret,
                    head: caret,
                }));
                self.finish(vec![set_query, stay], LoopNext::File)
            }
            Answer::Quit => {
                let caret = self.caret(app)?;
                let stay = edit(Command::SetSelection(Selection {
                    anchor: caret,
                    head: caret,
                }));
                self.finish(vec![set_query, stay], LoopNext::Stop)
            }
        }
    }
    /// Goes to the first match at `from` or after it; past the last one the
    /// review ends, as query-replace stops at the end of the buffer.
    fn move_on(
        &mut self,
        app: &Application,
        from: usize,
        time: Duration,
    ) -> Result<Transition, EditError> {
        let view = app.view(self.view).ok_or(EditError::UnknownSession)?;
        let document = app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .document();
        let snapshot = document.snapshot();
        let mut count = 0;
        let mut next = None;
        for range in self.query.cursor(snapshot) {
            count += 1;
            if next.is_none() && range.start >= from {
                next = Some(range);
            }
        }
        self.results = SearchResults {
            revision: snapshot.version(),
            count,
            current: next.clone(),
        };
        let Some(next) = next else {
            let stay = Event::Edit {
                view: self.view,
                command: Command::SetSelection(Selection {
                    anchor: from,
                    head: from,
                }),
                time,
            };
            return self.finish(vec![stay], LoopNext::File);
        };
        Ok(Transition::Active(Response {
            events: vec![Event::Edit {
                view: self.view,
                command: Command::SetSelection(Selection {
                    anchor: next.start,
                    head: next.end,
                }),
                time,
            }],
            redraw: true,
            ..Response::default()
        }))
    }
    /// Matches that start at `from` or after it.
    fn count_from(&self, app: &Application, from: usize) -> usize {
        let Some(view) = app.view(self.view) else {
            return 0;
        };
        let editor = app.workspace().editor(view.document_id).unwrap();
        let snapshot = editor.model().document().snapshot();
        self.query
            .cursor(snapshot)
            .filter(|range| range.start >= from)
            .count()
    }
    /// Ends the review, saying how many matches were replaced; over the
    /// project, the Runtime says it for all the files, and goes `next`.
    fn finish(&self, events: Vec<Event>, next: LoopNext) -> Result<Transition, EditError> {
        let replaced = self.replaced();
        if self.project() == Project::Loop {
            return Ok(Transition::Closed(Response {
                events,
                redraw: true,
                commands: vec![effect(super::modal::Effect::FileLoop(LoopStep {
                    replaced,
                    next,
                }))],
                ..Response::default()
            }));
        }
        let noun = if replaced == 1 {
            "occurrence"
        } else {
            "occurrences"
        };
        Ok(Transition::Closed(Response {
            events,
            redraw: true,
            message: super::Message::Set(format!("Replaced {replaced} {noun}")),
            ..Response::default()
        }))
    }
}
/// The offset after the character at `at`, or `at` at the end.
fn next_char(app: &Application, view: ViewId, at: usize) -> usize {
    let Some(view) = app.view(view) else {
        return at;
    };
    let editor = app.workspace().editor(view.document_id).unwrap();
    let text = editor.model().document().snapshot().text();
    text[at..].chars().next().map_or(at, |c| at + c.len_utf8())
}
/// A command that asks the Runtime for `effect`.
fn effect(effect: super::modal::Effect) -> super::Command {
    super::Command::Effect(Box::new(effect))
}
