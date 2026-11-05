//! Mouse input after the frontend has resolved screen cells to positions in
//! the active view. A click places the caret, a drag selects.
use super::{InputResult, Layers, Message, Response};
use crate::{
    application::{Application, Event, ViewId},
    core::Selection,
    editor::{Command as Edit, DocumentId},
};
use std::time::Duration;

#[derive(Clone, Copy, Debug)]
pub enum Pointer {
    /// Places the caret at a byte offset.
    Click(usize),
    /// Selects from where the button went down to where it is now.
    Drag { anchor: usize, head: usize },
    /// Moves the head of the selection back into view after scrolling.
    Reveal(usize),
    /// Shows a document in the focused window, as a tab of its row does
    /// in Emacs's `tab-line-mode`: even one another window shows.
    Document(DocumentId),
    /// Focuses the window showing a view.
    Window(ViewId),
    /// Moves the right or bottom edge of a window by cells.
    Edge {
        view: ViewId,
        axis: crate::application::Axis,
        delta: i32,
    },
}

impl Layers {
    pub(super) fn pointer(
        &mut self,
        pointer: Pointer,
        app: &Application,
        time: Duration,
    ) -> InputResult {
        // Modal layers own the screen; the editor below does not take clicks.
        if self.active.is_some() {
            return InputResult::Blocked;
        }
        let Some(view) = app.active_view().and_then(|id| app.view(id)) else {
            return InputResult::Blocked;
        };
        self.sequence.clear();
        self.modal.clear();
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        let editor = app.workspace().editor(view.document_id).unwrap();
        let current = editor.model().session(view.session_id).unwrap().selection();
        let selection = match pointer {
            Pointer::Document(document) => {
                let shown = app.windows().views();
                let here = app
                    .active_view()
                    .and_then(|view| app.view(view))
                    .is_some_and(|view| view.document_id == document);
                if !here {
                    // A view no window shows comes back; else a new one.
                    let hidden = app
                        .views()
                        .find(|view| view.document_id == document && !shown.contains(&view.id));
                    response.events.push(match hidden {
                        Some(view) => Event::Focus(view.id),
                        None => Event::AddView(document),
                    });
                }
                return InputResult::Handled(response);
            }
            Pointer::Window(view) => {
                response.events.push(Event::Focus(view));
                return InputResult::Handled(response);
            }
            Pointer::Edge { view, axis, delta } => {
                response
                    .events
                    .push(Event::MoveWindowEdge { view, axis, delta });
                return InputResult::Handled(response);
            }
            Pointer::Click(offset) => Selection::caret(offset),
            Pointer::Drag { anchor, head } => Selection { anchor, head },
            Pointer::Reveal(offset) => Selection {
                anchor: if current.range().is_empty() {
                    offset
                } else {
                    current.anchor
                },
                head: offset,
            },
        };
        response.events.push(Event::Edit {
            view: view.id,
            command: Edit::SetSelection(selection),
            time,
        });
        InputResult::Handled(response)
    }
}
