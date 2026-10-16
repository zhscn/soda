//! Read-only shortcut help. CLI and interactive help share this text.
use super::{Input, InputKey, InputMotion, picker::ListMotion, session::Transition};

pub const TEXT: &str = "Vim editing
Normal is the initial mode. Esc / Ctrl-[ / Ctrl-C leave Insert or Visual.
i / a Insert before / after cursor   I / A Insert at line start / end
o / O Open a line below / above, using language indentation
h j k l / arrows Move   w b e Word start / back / end
0 / ^ / $ Line start / first nonblank / end   gg / G First / last line
Counts: 3w, 2dd, 2d3w, 3gg, 3G (maximum 10000)
d / c / y + motion Delete / change / yank   dd / cc / yy Whole lines
D / C Delete / change to line end   s / S Substitute characters / lines
x / X Delete characters forward / backward   r + character Replace
p / P Put after / before cursor   u Undo   Ctrl-R Redo
v / V Characterwise / linewise Visual; motions extend; d/c/y operate
/ / ? Search forward / backward   n / N Repeat / reverse search

Insert
Text and paste insert normally; Enter uses language indentation
Backspace / Ctrl-H Delete backward   Ctrl-W Delete word backward
Ctrl-U Delete to line start   Delete Delete forward
Arrows / Home / End move; Shift extends selection
Ctrl-Left / Right Move by word   Ctrl-Backspace / Delete Delete word
Tab Insert indentation / indent selection   Shift-Tab Outdent

Commands
:e PATH Open file   :e Reload   :open Open path dialog
:w Save   :w PATH Save as   :saveas Choose save path
:q Quit   :wq Write current buffer and quit
:bd Close buffer   :b / :buffers Choose buffer   :bn Next view
:enew New buffer   :project Project file picker   :help / F1 Help
Unsaved changes use save / discard / cancel confirmation

Prompts and pickers
Left / Right Move   Ctrl-B / Home Beginning   Ctrl-E / End End
Ctrl-W Delete word backward   Ctrl-U Delete to beginning
Up / Down or Ctrl-P / Ctrl-N Select candidate
PageUp / PageDown Move candidate page
Enter Confirm   Esc / Ctrl-C Cancel
Path dialogs: Tab lists / fills; typing refreshes an expanded list
Trailing / browses directory; Esc hides candidates, then cancels
Replacement review: Enter current, F4 / Ctrl-Enter all

Scope
Supported Vim commands form a fixed subset. Unsupported Normal input is consumed.
Text objects, dot repeat, named registers, macros and block Visual are not implemented.
Search is literal and case-sensitive. Unicode movement uses editor graphemes.
File and buffer commands use Soda workflows, not a general Ex interpreter.

Help
F1 Open / close help   Arrows / PageUp / PageDown Scroll
Home / End First / last page   Enter / Esc Return to editor";

pub const HINT: &str = "i Insert  / Search  : Commands  F1 Help";

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
