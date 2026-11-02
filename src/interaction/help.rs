//! Read-only help. The interactive page lists the current bindings; `--help`
//! lists the defaults from the same tables.
use super::{
    Context, Input, InputKey, InputMotion, Keymap, Registry, key_notation, picker::ListMotion,
    session::Transition,
};

const MODAL: &str = "Modal editing
Normal selects first, then acts on the selection, as meow does. Unbound keys do nothing.
h j k l Move, across lines   H J K L Extend a character selection
w b / W B Select a word / symbol; again takes the next
[ ] Mark the word / symbol here, which also becomes the search
e Select the line; again extends   o Group around the selection; again its parent   O To the next group
f t + character Select through / up to it   , . + thing Select inside / around it
Things: r s c a brackets, g string, w word, e symbol, p paragraph, l line, b buffer
Digits extend a selection by as many more; hints show where. Without one, a digit is a count.
- Reverses the next command   Space and digits Give a count
; Swap the ends   z Previous selection   Z First selection   Esc Drop the selection
i a Insert at the start / end of the selection   I A Open a line above / below
r Cut, or to the line end   s Change   d Delete   y Copy   p Paste   ' Select the join to the line above
v Search   n Next match, of the search or the selection   N Forget the search
u Undo   U Redo   ` Repeat the last command
q Jump by two characters   Q Go to a line   R Replace   / Open a file

Keypad
x c start C-x and C-c: x s is C-x C-s. Each key is tried with Ctrl, then plain; Space forces plain.
Space is the leader: Space f is C-c f. m and g put M- and C-M- on the next key.

Macros and Beacon
F3 / C-x ( Record   F4 / C-x ) End, or play   C-x e Play
E Play on each selected line   V Play on each match of the search
G Grab the selection: Beacon, where each selection follows the main one's kind.
In Beacon i a s type at every selection; a macro recorded there plays at each of them.
Without a selection G leaves a marker; S swaps the selection with what was grabbed.";
const NOTES: &str = "Esc / Ctrl-[ / Ctrl-G leave Insert and cancel pending keys.
C-c C-c stops run, shell and grep; M-g n / M-g p step through their results.
Printable characters insert text in Insert and prompts.
Command lines read state with %opt{NAME} and %val{file|name|kind|line|column|selection|word|root|mode|column-limit}.
Hooks: hook open|new|save|close|mode|focus FILTER COMMAND runs COMMAND when FILTER matches.
Configuration: ~/.config/soda/init holds map, unmap, define-command, hook, set, display and highlight lines.";

/// Help generated from the effective key tables and command registry.
pub fn text(keymap: &Keymap, registry: &Registry) -> String {
    let mut out = format!("{MODAL}\n\n{NOTES}\n");
    for context in Context::ALL {
        out.push_str(&format!("\n{} keys\n", context.name()));
        // One row per target, listing every key bound to it.
        let mut rows: Vec<(String, String)> = vec![];
        for (keys, label) in keymap.bindings(context) {
            let keys = key_notation(&keys);
            match rows.iter_mut().find(|(_, existing)| *existing == label) {
                Some(row) => row.0 = format!("{} {keys}", row.0),
                None => rows.push((keys, label)),
            }
        }
        for (keys, label) in rows {
            out.push_str(&format!(
                "  {keys:<22} {label:<22} {}\n",
                registry.doc(&label)
            ));
        }
    }
    out.push_str("\nCommands (: or <space>:)\n");
    for info in registry.commands() {
        let name = format!("{} {}", info.name, info.synopsis());
        let name = name.trim_end();
        out.push_str(&format!("  {name:<38} {}\n", info.doc));
    }
    out.push('\n');
    out
}
/// Help for the default bindings, as printed by `--help`.
pub fn default_text() -> String {
    text(&Keymap::default(), &Registry::default())
}

pub struct HelpSession {
    text: String,
    first_line: usize,
    rows: usize,
}
impl Default for HelpSession {
    fn default() -> Self {
        Self::new(default_text())
    }
}
impl HelpSession {
    pub fn new(text: String) -> Self {
        Self {
            text,
            first_line: 0,
            rows: 0,
        }
    }
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
    pub fn lines(&self) -> impl Iterator<Item = &str> {
        self.text.lines().skip(self.first_line).take(self.rows)
    }
    pub fn resize(&mut self, rows: usize) {
        self.rows = rows;
        self.first_line = self
            .first_line
            .min(self.text.lines().count().saturating_sub(rows.max(1)));
    }
    pub(super) fn handle(&mut self, input: Input) -> Transition {
        let before = self.first_line;
        let page = self.rows.saturating_sub(1).max(1);
        let last = self.text.lines().count().saturating_sub(self.rows.max(1));
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
