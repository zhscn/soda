//! Read-only help. The interactive page lists the current bindings; `--help`
//! lists the defaults from the same tables.
use super::{
    Context, Input, InputKey, InputMotion, Keymap, Registry, key_notation, picker::ListMotion,
    session::Transition,
};

const VIM: &str = "Vim editing
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
/ / ? Search forward / backward   n / N Repeat / reverse search";
const SCOPE: &str = "Scope
Supported Vim commands form a fixed subset. Unsupported Normal input is consumed.
Text objects, dot repeat, named registers, macros and block Visual are not implemented.
Search is literal and case-sensitive. Unicode movement uses editor graphemes.
File and buffer commands use Soda workflows, not a general Ex interpreter.";
const NOTES: &str = "Esc / Ctrl-[ / Ctrl-C leave Insert and Visual and cancel pending keys.
Printable characters insert text in Insert and prompts.
Unbound Normal and Visual keys use the Vim grammar above.
Configuration: ~/.config/soda/init holds map, unmap and define-command lines.";

/// Help generated from the effective key tables and command registry.
pub fn text(keymap: &Keymap, registry: &Registry) -> String {
    let mut out = format!("{VIM}\n\n{NOTES}\n");
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
        let name = if info.args.is_empty() {
            info.name
        } else {
            format!("{} {}", info.name, info.args)
        };
        out.push_str(&format!("  {name:<38} {}\n", info.doc));
    }
    out.push('\n');
    out.push_str(SCOPE);
    out
}
/// Help for the default bindings, as printed by `--help`.
pub fn default_text() -> String {
    text(&Keymap::default(), &Registry::default())
}

pub const HINT: &str = "i Insert  / Search  : Commands  F1 Help";

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
