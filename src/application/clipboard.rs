//! Application-local clipboard. Copying preserves selections; cutting commits
//! text before replacing clipboard contents, so a failed edit cannot lose them.
use super::{Application, Error, Update, ViewId};
use crate::{
    core::{Change, Selection, Transaction},
    editor::Command,
};
use std::time::Duration;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug)]
pub enum ClipboardAction {
    Copy,
    Operate {
        range: std::ops::Range<usize>,
        linewise: bool,
        edit: Option<Change>,
        selection: Selection,
    },
    Put {
        before: bool,
        count: usize,
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

    pub(super) fn clipboard_action(
        &mut self,
        view: ViewId,
        action: ClipboardAction,
        time: Duration,
        update: &mut Update,
    ) -> Result<(), Error> {
        let state = self.views.get(&view).ok_or(Error::UnknownView)?;
        let document_id = state.document_id;
        let editor = self.workspace.editor(state.document_id).unwrap();
        let selection = editor
            .model()
            .session(state.session_id)
            .unwrap()
            .selection();
        let snapshot = editor.model().document().snapshot();
        if let ClipboardAction::Operate {
            ref range,
            linewise,
            ref edit,
            selection: after,
        } = action
        {
            let mut value = snapshot
                .byte_slice(range.clone())
                .ok_or(crate::core::EditError::InvalidRange)?
                .to_string();
            if linewise && !value.ends_with('\n') {
                value.push_str(line_ending(snapshot));
            }
            if let Some(change) = edit {
                let mut tx = Transaction::new(snapshot.version(), vec![change.clone()]);
                tx.selection = Some(after);
                self.edit(view, Command::Apply(tx), time, update)?;
            } else {
                self.edit(view, Command::SetSelection(after), time, update)?;
            }
            if edit.is_none() {
                self.workspace
                    .editor_mut(document_id)
                    .unwrap()
                    .checkpoint_history();
            }
            self.clipboard = value;
            self.clipboard_linewise = linewise;
            return Ok(());
        }
        if let ClipboardAction::Put { before, count } = action {
            if self.clipboard.is_empty() {
                return Ok(());
            }
            if count == 0
                || count > 10000
                || self.clipboard.len().saturating_mul(count) > 8 * 1024 * 1024
            {
                return Err(crate::core::EditError::InvalidRange.into());
            }
            let line = snapshot.line_of(selection.head).unwrap();
            let mut value = self.clipboard.repeat(count);
            let offset = if self.clipboard_linewise {
                if before {
                    snapshot.line_start(line).unwrap()
                } else {
                    snapshot.line_range(line).unwrap().end
                }
            } else if before {
                selection.head
            } else {
                crate::core::step_grapheme(snapshot, crate::core::ByteOffset(selection.head), true)?
                    .0
                    .min(snapshot.line_content_range(line).unwrap().end)
            };
            let mut prefix_len = 0;
            if self.clipboard_linewise && !before && offset > 0 {
                let previous =
                    crate::core::step_grapheme(snapshot, crate::core::ByteOffset(offset), false)?.0;
                if !snapshot
                    .byte_slice(previous..offset)
                    .unwrap()
                    .to_string()
                    .ends_with('\n')
                {
                    let eol = line_ending(snapshot);
                    value.insert_str(0, eol);
                    prefix_len = eol.len();
                    let suffix = if value.ends_with("\r\n") { 2 } else { 1 };
                    value.truncate(value.len() - suffix);
                }
            }
            let caret = if self.clipboard_linewise {
                let prefix = prefix_len;
                let first = value[prefix..].split('\n').next().unwrap_or("");
                offset + prefix + first.len() - first.trim_start_matches([' ', '\t']).len()
            } else if value.contains('\n') {
                offset
            } else {
                offset + value.len() - value.graphemes(true).next_back().unwrap().len()
            };
            let mut tx =
                Transaction::new(snapshot.version(), vec![Change::new(offset..offset, value)]);
            tx.selection = Some(Selection::caret(caret));
            self.edit(view, Command::Apply(tx), time, update)?;
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
        self.clipboard = text;
        self.clipboard_linewise = false;
        Ok(())
    }
}

fn line_ending(snapshot: &crate::core::Snapshot) -> &'static str {
    if snapshot.line_range(0).unwrap().end - snapshot.line_content_range(0).unwrap().end == 2 {
        "\r\n"
    } else {
        "\n"
    }
}
