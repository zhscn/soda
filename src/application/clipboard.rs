//! Application-local clipboard. Copying preserves selections; cutting commits
//! text before replacing clipboard contents, so a failed edit cannot lose them.
use super::{Application, Error, Update, ViewId};
use crate::{
    core::{Change, Selection, Transaction},
    editor::Command,
};
use std::time::Duration;

#[derive(Clone, Copy, Debug)]
pub enum ClipboardAction {
    Copy,
    Cut,
    Paste,
}

impl Application {
    pub fn clipboard(&self) -> &str {
        &self.clipboard
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
        let range = if selection.range().is_empty() {
            snapshot
                .line_range(snapshot.line_of(selection.head).unwrap())
                .unwrap()
        } else {
            selection.range()
        };
        if range.is_empty() {
            return Ok(());
        }
        let document = state.document_id;
        let text = snapshot.byte_slice(range.clone()).unwrap().to_string();
        if matches!(action, ClipboardAction::Cut) {
            let mut tx = Transaction::new(snapshot.version(), vec![Change::new(range.clone(), "")]);
            tx.selection = Some(Selection::caret(range.start));
            self.edit(view, Command::Apply(tx), time, update)?;
        }
        self.workspace
            .editor_mut(document)
            .unwrap()
            .checkpoint_history();
        self.clipboard = text;
        Ok(())
    }
}
