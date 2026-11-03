//! Application-local clipboard: a kill ring, as in Emacs, whose newest
//! entry is the clipboard. Copying preserves selections; cutting commits
//! text before replacing clipboard contents, so a failed edit cannot lose
//! them. Kills one after another join into one entry; `yank-pop` replaces
//! what a yank just put in with an older entry.
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
    /// Replaces the text the last yank put in with the next older entry.
    YankPop,
    Kill {
        backward: bool,
        word: bool,
    },
}

/// Entries the kill ring keeps, as Emacs's `kill-ring-max`.
const KILL_RING_MAX: usize = 120;

/// Where a view's caret rested, in which version of its text: a kill or a
/// yank is still the last thing done there while both are the same.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct Rest {
    view: ViewId,
    version: u64,
    head: usize,
}
/// What the last yank put in: the bytes before the caret, and which entry.
#[derive(Clone, Copy, Debug)]
pub(super) struct Yanked {
    rest: Rest,
    len: usize,
    index: usize,
}

impl Application {
    pub fn clipboard(&self) -> &str {
        self.kill_ring.front().map_or("", String::as_str)
    }
    /// The kill ring, newest first.
    pub fn kill_ring(&self) -> impl Iterator<Item = &str> {
        self.kill_ring.iter().map(String::as_str)
    }
    pub fn clipboard_revision(&self) -> u64 {
        self.clipboard_revision
    }
    /// A new newest entry; the same text as the newest is not repeated.
    pub(super) fn set_clipboard(&mut self, text: String) {
        if self.kill_ring.front() != Some(&text) {
            self.kill_ring.push_front(text);
            self.kill_ring.truncate(KILL_RING_MAX);
        }
        self.killed = None;
        self.yanked = None;
        self.clipboard_revision += 1;
    }
    fn rest(&self, view: ViewId) -> Option<Rest> {
        let state = self.views.get(&view)?;
        let editor = self.workspace.editor(state.document_id)?;
        let head = editor.model().session(state.session_id)?.selection().head;
        let version = editor.model().document().snapshot().version();
        Some(Rest {
            view,
            version,
            head,
        })
    }
    /// Takes `range` of `text` out of `view`: right after another kill
    /// that left the caret at one of its ends, it joins that kill's entry,
    /// after it when killing forward and before it when killing backward.
    /// Call before the edit; `finish_kill` after it.
    fn kill_join(&self, view: ViewId, range: &std::ops::Range<usize>) -> Option<bool> {
        let killed = self
            .killed
            .filter(|killed| Some(*killed) == self.rest(view))?;
        if self.kill_ring.is_empty() {
            return None;
        }
        if range.start == killed.head {
            Some(true)
        } else if range.end == killed.head {
            Some(false)
        } else {
            None
        }
    }
    fn finish_kill(&mut self, view: ViewId, text: String, join: Option<bool>) {
        match (join, self.kill_ring.front_mut()) {
            (Some(after), Some(newest)) => {
                if after {
                    newest.push_str(&text);
                } else {
                    newest.insert_str(0, &text);
                }
                self.clipboard_revision += 1;
            }
            _ => self.set_clipboard(text),
        }
        self.killed = self.rest(view);
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
            let join = self.kill_join(view, range);
            let mut tx = Transaction::new(snapshot.version(), vec![edit.clone()]);
            tx.selection = Some(after);
            self.edit(view, Command::Apply(tx), time, update)?;
            self.finish_kill(view, value, join);
            return Ok(());
        }
        if matches!(action, ClipboardAction::Paste) {
            let text = self.clipboard().to_owned();
            if !text.is_empty() {
                let len = text.len();
                self.edit(view, Command::InsertText(text), time, update)?;
                self.yanked = self.rest(view).map(|rest| Yanked {
                    rest,
                    len,
                    index: 0,
                });
            }
            return Ok(());
        }
        if matches!(action, ClipboardAction::YankPop) {
            let Some(yanked) = self
                .yanked
                .filter(|yanked| Some(yanked.rest) == self.rest(view))
            else {
                return Err(Error::NotAfterYank);
            };
            // The yanked text ends at the caret.
            let end = yanked.rest.head;
            let start = end
                .checked_sub(yanked.len)
                .filter(|start| {
                    snapshot
                        .byte_slice(*start..end)
                        .map(|text| text.to_string())
                        .as_deref()
                        == self.kill_ring.get(yanked.index).map(String::as_str)
                })
                .ok_or(Error::NotAfterYank)?;
            let index = (yanked.index + 1) % self.kill_ring.len();
            let text = self.kill_ring[index].clone();
            let mut tx = Transaction::new(
                snapshot.version(),
                vec![Change::new(start..end, text.as_str())],
            );
            tx.selection = Some(Selection::caret(start + text.len()));
            self.edit(view, Command::Apply(tx), time, update)?;
            self.yanked = self.rest(view).map(|rest| Yanked {
                rest,
                len: text.len(),
                index,
            });
            return Ok(());
        }
        // A kill goes from the caret, as Emacs's `kill-line` and
        // `kill-word` ignore the region; copying and cutting take the
        // selection, or else the line.
        let range = if let ClipboardAction::Kill { backward, word } = action {
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
        } else if !selection.range().is_empty() {
            selection.range()
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
        let cut = matches!(action, ClipboardAction::Cut | ClipboardAction::Kill { .. });
        let join = cut.then(|| self.kill_join(view, &range)).flatten();
        if cut {
            let mut tx = Transaction::new(snapshot.version(), vec![Change::new(range.clone(), "")]);
            tx.selection = Some(Selection::caret(range.start));
            self.edit(view, Command::Apply(tx), time, update)?;
        }
        self.workspace
            .editor_mut(document)
            .unwrap()
            .checkpoint_history();
        if cut {
            self.finish_kill(view, text, join);
        } else {
            self.set_clipboard(text);
        }
        Ok(())
    }
}
