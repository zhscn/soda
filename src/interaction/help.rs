//! Read-only help. The interactive page lists the current bindings; `--help`
//! lists the defaults from the same tables.
use super::{
    Context, Input, InputKey, InputMotion, Keymap, Registry, key_notation, picker::ListMotion,
    session::Transition,
};

const EDITING: &str = "Editing
Keys work as in Emacs. C-f C-b C-n C-p move; C-Space sets the mark, and moves extend from it.
C-w cuts the selection, M-w copies it, C-y pastes and M-y cycles what was cut; C-g drops the selection.
Plugins add more, each with require(NAME).setup(): meow for modal editing, puni, symbol-overlay and others.";
const MODAL: &str = "Modal editing
Normal selects first, then acts on the selection, as meow does; its keys come from a layout,
listed under normal keys below. Unbound keys do nothing.
A digit extends a selection by as many more, and hints show where; without one it is a count.
The keypad reads C-x and C-c sequences without modifiers: each key is tried with Ctrl, then plain.
Grab enters Beacon, where each selection follows the main one's kind and typing goes to every one;
a macro recorded there plays at each of them.";
const NOTES: &str = "Esc / Ctrl-[ / Ctrl-G cancel pending keys and drop the selection; with modal editing they leave Insert.
F3 / C-x ( record a macro; F4 / C-x ) end it, or play it; C-x e plays it.
C-c C-c stops run, shell and grep; M-g n / M-g p step through their results.
Command lines read state with %opt{NAME} and %val{file|name|kind|line|column|selection|word|root|mode|column-limit}.
Hooks: hook open|new|save|close|mode|focus FILTER COMMAND runs COMMAND when FILTER matches.
Configuration: ~/.config/soda/init.lua, with soda.map, soda.set, soda.hook and soda.command(LINE).";

/// Help generated from the effective key tables and command registry.
pub fn text(keymap: &Keymap, registry: &Registry, modal: bool) -> String {
    let mut out = if modal {
        format!("{EDITING}\n\n{MODAL}\n\n{NOTES}\n")
    } else {
        format!("{EDITING}\n\n{NOTES}\n")
    };
    let contexts = Context::ALL
        .into_iter()
        .map(|context| (format!("{} keys", context.name()), keymap.bindings(context)));
    // Keymaps that hold in some documents only, with what they are for.
    let documents = keymap
        .document_bindings()
        .into_iter()
        .map(|(name, doc, bindings)| (format!("{name} keys: {doc}"), bindings));
    for (heading, bindings) in contexts.chain(documents) {
        out.push_str(&format!("\n{heading}\n"));
        // One row per target, listing every key bound to it.
        let mut rows: Vec<(String, String)> = vec![];
        for (keys, label) in bindings {
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
    out.push_str("\nCommands (M-x)\n");
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
    text(&Keymap::default(), &Registry::default(), false)
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
