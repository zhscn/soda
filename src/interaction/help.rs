//! Read-only shortcut help. CLI and interactive help share this text.
use super::{Input, InputKey, InputMotion, picker::ListMotion, session::Transition};

pub const TEXT: &str = "Files
C-x C-f Open   C-x C-s Save   C-x C-w / F4 Save as
C-x n New   C-x k Close buffer   C-x C-c Quit
C-x b Switch buffer   C-x p f Find project file
C-x r / F5 Reload   Ctrl-Tab / F6 Next view
Unsaved changes: s save, d discard, c / Esc / Enter cancel
Path prompts: Tab lists / fills; arrows select; Enter uses input
Trailing / browses directory; Esc hides candidates, then cancels

Readline editing (C = Ctrl, M = Alt)
C-b / C-f Back / forward   C-a / C-e Line start / end
M-b / M-f Word back / forward   C-p / C-n Previous / next line
C-h / Backspace Delete backward   C-d / Delete Delete forward
C-k Kill to line end (at end, kill newline)   C-u Kill to line start
C-w / M-Backspace Kill word backward   M-d Kill word forward
C-y Yank   M-w Copy selection / current line (document)
C-_ / C-/ Undo   M-_ Redo (document)
M-a Select all   C-x h Select document
Arrows / Home / End move; Shift extends selection
C-Left / Right Move by word   C-Home / End Document start / end
C-v / M-v / PageDown / PageUp Move by page
C-x g Go to line[:column]
Tab Indent selected lines / insert indentation   Shift-Tab Outdent

Normal layer
Esc enters Normal; i enters Insert; a moves forward and enters Insert
h j k l Move; b / w Move by word; uppercase extends selection
0 / $ Line start / end   d Delete   s Change selection and enter Insert
y Copy   r Cut   p Yank   u Undo   / Open file
SPC f Project files   SPC b Buffers   SPC s Save   SPC q Quit
C-s searches in either mode; prompts always accept text

Search and replacement
C-s Search   M-% Replace
Search prompt: C-s / C-r Next / previous match
F3 / Shift-F3 Next / previous match
Review: Enter replaces current, F4 / Ctrl-Enter replaces all
Esc / C-g cancel search or replacement and restore the original position

Prompts and file picker
Readline character / word / line editing; M-a selects input
Each field keeps its last killed text for C-y
Up / Down or C-p / C-n Select candidate
PageUp / PageDown Move candidate page
Enter Confirm   Esc / C-g Cancel

Key sequences
C-x sequences work in Insert and Normal; SPC sequences work in Normal
C-g / Esc cancel a prefix; undefined sequences are consumed
Prefixes wait until completed or cancelled

Help
F1 Open / close help   Arrows / PageUp / PageDown Scroll
Home / End First / last page   Enter / Esc Return to editor";

pub const HINT: &str = "F1 Help  C-x C-f Open  C-x b Buffers  C-x C-s Save  C-x C-c Quit";

#[derive(Default)]
pub struct HelpSession {
    first_line: usize,
    rows: usize,
}
impl HelpSession {
    pub(super) fn presentation(&self) -> super::Presentation {
        super::Presentation {
            text: "Help — arrows / PageUp / PageDown scroll; Esc returns".into(),
            cursor: None,
            selection: 0..0,
        }
    }
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
    pub(super) fn handle(&mut self, input: Input) -> Transition {
        let before = self.first_line;
        let page = self.rows.saturating_sub(1).max(1);
        let last = TEXT.lines().count().saturating_sub(self.rows.max(1));
        let motion = match input {
            Input::Cancel | Input::Confirm | Input::Help => return Transition::close(),
            Input::Candidate { motion, .. } => motion,
            Input::Text(InputKey::Move {
                motion: InputMotion::Start,
                ..
            }) => ListMotion::First,
            Input::Text(InputKey::Move {
                motion: InputMotion::End,
                ..
            }) => ListMotion::Last,
            _ => return Transition::Blocked,
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
            Transition::redraw()
        } else {
            Transition::Blocked
        }
    }
}
