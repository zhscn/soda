//! Read-only shortcut help. CLI and interactive help share this text.
use super::{Input, InputKey, InputMotion, picker::ListMotion};

pub const TEXT: &str = "Files
Ctrl-N New   Ctrl-O Open   Ctrl-P Find file   Ctrl-W Close buffer
Ctrl-S Save   Ctrl-Shift-S / F4 Save as   F5 Reload
Ctrl-Q Quit   Ctrl-Tab / F6 Next buffer
Unsaved changes: s save, d discard, c / Esc / Enter cancel

Editing
Ctrl-C Copy   Ctrl-X Cut   Ctrl-V Paste (internal clipboard)
Copy / cut selection, or current line when no text is selected
Ctrl-A Select all   Ctrl-Z Undo   Ctrl-Y Redo
Arrows move; Shift extends selection; Home / End move within line
Ctrl-Left / Right move by word; Ctrl-Backspace / Delete delete word
Ctrl-Home / End move to document start / end
PageUp / PageDown move by page; Shift extends selection
Ctrl-G Go to line[:column] (one-based logical columns)
Tab indent / insert indentation   Shift-Tab Outdent

Search and replacement
Ctrl-F Search   F3 / Shift-F3 Next / previous match
Ctrl-R Replace: query, replacement, then explicit confirmation
Review: Enter replaces current, F4 / Ctrl-Enter replaces all
Esc cancels search or replacement and restores the original position

Prompts and file picker
Ctrl-A Select input   Ctrl-Left / Right Move by word
Up / Down Select candidate   PageUp / PageDown Move candidate page
Enter Confirm   Esc Cancel

Help
F1 Open / close help   Arrows / PageUp / PageDown Scroll
Home / End First / last page   Enter / Esc Return to editor";

pub const HINT: &str = "F1 Help  Ctrl-O Open  Ctrl-P Files  Ctrl-S Save  Ctrl-Q Quit";

#[derive(Default)]
pub struct HelpSession {
    first_line: usize,
    rows: usize,
}
pub(super) enum HelpAction {
    Close,
    Redraw,
    Blocked,
}
impl HelpSession {
    pub fn first_line(&self) -> usize {
        self.first_line
    }
    pub fn lines(&self) -> impl Iterator<Item = &'static str> {
        TEXT.lines().skip(self.first_line).take(self.rows)
    }
    pub fn resize(&mut self, rows: usize) {
        self.rows = rows;
        self.first_line = self
            .first_line
            .min(TEXT.lines().count().saturating_sub(rows.max(1)));
    }
    pub(super) fn handle(&mut self, input: Input) -> HelpAction {
        let before = self.first_line;
        let page = self.rows.saturating_sub(1).max(1);
        let last = TEXT.lines().count().saturating_sub(self.rows.max(1));
        let motion = match input {
            Input::Cancel | Input::Confirm | Input::Help => return HelpAction::Close,
            Input::Candidate { motion, .. } => motion,
            Input::Text(InputKey::Move {
                motion: InputMotion::Start,
                ..
            }) => ListMotion::First,
            Input::Text(InputKey::Move {
                motion: InputMotion::End,
                ..
            }) => ListMotion::Last,
            _ => return HelpAction::Blocked,
        };
        self.first_line = match motion {
            ListMotion::Previous => before.saturating_sub(1),
            ListMotion::Next => before.saturating_add(1).min(last),
            ListMotion::PagePrevious => before.saturating_sub(page),
            ListMotion::PageNext => before.saturating_add(page).min(last),
            ListMotion::First => 0,
            ListMotion::Last => last,
        };
        if self.first_line != before {
            HelpAction::Redraw
        } else {
            HelpAction::Blocked
        }
    }
}
