//! Application-local clipboard. Copying preserves selections; cutting commits
//! text before replacing clipboard contents, so a failed edit cannot lose them.
use super::{Application, Error, Update, ViewId};
use crate::{
    core::{Change, Selection, Transaction},
    editor::Command,
};
use std::time::Duration;

#[derive(Clone, Debug)]
pub enum ClipboardAction {
    Copy,
    /// Takes `range` into the clipboard, applies `edit` and sets `selection`.
    Operate {
        range: std::ops::Range<usize>,
        edit: Change,
        selection: Selection,
    },
    Cut,
    Paste,
    Kill {
        backward: bool,
        word: bool,
    },
}

impl Application {
    pub fn clipboard(&self) -> &str {
        &self.clipboard
    }
    pub fn clipboard_revision(&self) -> u64 {
        self.clipboard_revision
    }
    pub(super) fn set_clipboard(&mut self, text: String) {
        self.clipboard = text;
        self.clipboard_revision += 1;
    }

    pub(super) fn clipboard_action(
        &mut self,
        view: ViewId,
        action: ClipboardAction,
        time: Duration,
        update: &mut Update,
    ) -> Result<(), Error> {
        let state = self.views.get(&view).ok_or(Error::UnknownView)?;
        let editor = self.workspace.editor(state.document_id).unwrap();
        let selection = editor
            .model()
            .session(state.session_id)
            .unwrap()
            .selection();
        let snapshot = editor.model().document().snapshot();
        if let ClipboardAction::Operate {
            ref range,
            ref edit,
            selection: after,
        } = action
        {
            let value = snapshot
                .byte_slice(range.clone())
                .ok_or(crate::core::EditError::InvalidRange)?
                .to_string();
            let mut tx = Transaction::new(snapshot.version(), vec![edit.clone()]);
            tx.selection = Some(after);
            self.edit(view, Command::Apply(tx), time, update)?;
            self.set_clipboard(value);
            return Ok(());
        }
        if matches!(action, ClipboardAction::Paste) {
            if !self.clipboard.is_empty() {
                self.edit(
                    view,
                    Command::InsertText(self.clipboard.clone()),
                    time,
                    update,
                )?;
            }
            return Ok(());
        }
        let range = if !selection.range().is_empty() {
            selection.range()
        } else if let ClipboardAction::Kill { backward, word } = action {
            let head = selection.head;
            let line = snapshot.line_of(head).unwrap();
            let other = if word {
                crate::core::word_boundary(snapshot, crate::core::ByteOffset(head), backward)?.0
            } else if backward {
                snapshot.line_start(line).unwrap()
            } else {
                let end = snapshot.line_content_range(line).unwrap().end;
                if end == head {
                    snapshot.line_range(line).unwrap().end
                } else {
                    end
                }
            };
            head.min(other)..head.max(other)
        } else {
            snapshot
                .line_range(snapshot.line_of(selection.head).unwrap())
                .unwrap()
        };
        if range.is_empty() {
            return Ok(());
        }
        let document = state.document_id;
        let text = snapshot.byte_slice(range.clone()).unwrap().to_string();
        if matches!(action, ClipboardAction::Cut | ClipboardAction::Kill { .. }) {
            let mut tx = Transaction::new(snapshot.version(), vec![Change::new(range.clone(), "")]);
            tx.selection = Some(Selection::caret(range.start));
            self.edit(view, Command::Apply(tx), time, update)?;
        }
        self.workspace
            .editor_mut(document)
            .unwrap()
            .checkpoint_history();
        self.set_clipboard(text);
        Ok(())
    }
}
