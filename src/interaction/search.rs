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
    results: SearchResults,
}
#[derive(Default)]
pub struct SearchResults {
    pub revision: u64,
    pub count: usize,
    pub current: Option<Range<usize>>,
}
impl SearchSession {
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
                horizontal_column: self.viewport.horizontal_column,
            },
        ])
    }
}
