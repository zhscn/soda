//! A document-bound preview session. Retained anchors follow document updates;
//! matching ranges are recomputed from the current snapshot rather than mapped.
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
}
#[derive(Default)]
pub struct SearchResults {
    pub revision: u64,
    pub count: usize,
    pub current: Option<Range<usize>>,
}
impl SearchSession {
    pub(super) fn set_direction(&mut self, backward: bool) {
        self.backward = backward;
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
    pub(super) fn presentation(&self, field: &super::TextInput) -> super::Presentation {
        let label = format!("Find [{}]: ", self.results().count);
        let mut presentation = super::session::field_presentation(label, field);
        if let Some(error) = self.query.error() {
            presentation.text.push_str(&format!("  ({error})"));
        }
        presentation
    }
    pub(super) fn cancel_response(
        &self,
        app: &Application,
        time: Duration,
    ) -> Result<super::Response, EditError> {
        Ok(super::Response {
            events: if app.view(self.view()).is_some() {
                self.cancel(app, time)?
            } else {
                vec![]
            },
            redraw: true,
            ..super::Response::default()
        })
    }
    pub(super) fn preview_response(
        &mut self,
        app: &Application,
        backward: bool,
        advance: bool,
        time: Duration,
    ) -> Result<super::Response, EditError> {
        let command = self.preview(app, backward, advance)?;
        if self.results().current.is_none() {
            return self.cancel_response(app, time);
        }
        Ok(super::Response {
            events: vec![Event::Edit {
                view: self.view(),
                command,
                time,
            }],
            redraw: true,
            ..super::Response::default()
        })
    }
    pub(super) fn recall(
        &mut self,
        field: &mut super::TextInput,
        text: &str,
        app: &Application,
        time: Duration,
    ) -> Result<super::session::Transition, EditError> {
        let end = field.text().len();
        field.replace_range(0..end, text);
        self.set_query(text);
        Ok(super::session::Transition::active(self.preview_response(
            app,
            self.backward,
            false,
            time,
        )?))
    }
    pub(super) fn handle(
        &mut self,
        field: &mut super::TextInput,
        input: super::Input,
        app: &Application,
        time: Duration,
    ) -> Result<super::session::Transition, EditError> {
        use super::{
            Input, Response,
            session::{Transition, edit_field},
        };
        Ok(match input {
            Input::Cancel => Transition::finished(self.cancel_response(app, time)?),
            Input::Confirm => Transition::finished(Response {
                events: vec![Event::Edit {
                    view: self.view(),
                    command: Command::SetSearchQuery(self.query().clone()),
                    time,
                }],
                redraw: true,
                ..Response::default()
            }),
            Input::Navigate { backward } => {
                Transition::active(self.preview_response(app, backward, true, time)?)
            }
            input => match edit_field(field, input) {
                Some(update) if update.text_changed => {
                    self.set_query(field.text());
                    Transition::active(self.preview_response(app, self.backward, false, time)?)
                }
                Some(update) if update.selection_changed => Transition::redraw(),
                _ => Transition::Blocked,
            },
        })
    }
    pub(super) fn observe_transition(
        &mut self,
        app: &Application,
        update: &Update,
        time: Duration,
    ) -> Result<super::session::Transition, EditError> {
        use super::{Response, session::Transition};
        if !self.observe(app, update)? {
            return Ok(Transition::close());
        }
        if app.active_view() != Some(self.view()) {
            return Ok(Transition::finished(self.cancel_response(app, time)?));
        }
        if update.edit.as_ref().is_some_and(|edit| {
            edit.text_changed && edit.document_id == app.view(self.view()).unwrap().document_id
        }) {
            return Ok(Transition::active(self.preview_response(
                app,
                self.backward,
                false,
                time,
            )?));
        }
        Ok(Transition::active(Response::default()))
    }
}
