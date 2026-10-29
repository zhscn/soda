//! Mouse input after the frontend has resolved screen cells to positions in
//! the active view. Clicks and drags follow Vim's `mouse=a`: a click places
//! the caret and leaves Visual mode, a drag selects in Visual mode.
use super::{EditMode, InputResult, Layers, Message, Response, vim::visual_selection};
use crate::{
    application::{Application, Event},
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
    /// Moves the caret, or the Visual head, back into view after scrolling.
    Reveal(usize),
    /// Shows a document, as `buffer` does.
    Document(DocumentId),
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
        let snapshot = app
            .workspace()
            .editor(view.document_id)
            .unwrap()
            .model()
            .document()
            .snapshot();
        self.sequence.clear();
        self.vim.clear();
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        let visual = matches!(self.mode, EditMode::Visual | EditMode::VisualLine);
        let selection = match pointer {
            Pointer::Document(document) => {
                response.events.push(super::commands::show(app, document));
                return InputResult::Handled(response);
            }
            Pointer::Click(offset) => {
                if visual {
                    self.mode = EditMode::Normal;
                }
                self.vim.reset();
                Selection::caret(offset)
            }
            Pointer::Drag { anchor, head } => {
                response.events.extend(self.end_insert_group(app, time));
                if !visual {
                    self.mode = EditMode::Visual;
                }
                self.vim.reset();
                self.vim.visual = Some((anchor, head));
                visual_selection(snapshot, anchor, head, self.mode == EditMode::VisualLine)
            }
            Pointer::Reveal(offset) => match self.vim.visual {
                Some((anchor, _)) => {
                    self.vim.visual = Some((anchor, offset));
                    visual_selection(snapshot, anchor, offset, self.mode == EditMode::VisualLine)
                }
                None => Selection::caret(offset),
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
