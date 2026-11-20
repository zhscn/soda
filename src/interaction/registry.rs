//! Named commands shared by key bindings, the command line, configuration and
//! the command palette. Built-in names are fixed; registered Rust handlers and
//! user definitions share one replaceable namespace.
use super::{
    Command, Departure, LuaCommand, ResultsCommand, WindowCommand,
    keymap::{KeypadStart, LINE_EDITS, LineEdit, PROMPT_ACTIONS},
    modal::{Action, Entry as InsertAt, MacroAction, Query, Step},
    slots::{Choice, Slot, SlotKind},
};
use crate::interaction::FileCommand;
use crate::interaction::MacroCommand;
use crate::interaction::PromptCommand;
use crate::interaction::SearchCommand;
use crate::interaction::SetupCommand;
use crate::{
    application::{Axis, ClipboardAction, Direction},
    editor::{Command as Edit, Motion},
};
use std::collections::BTreeMap;

const MAX_DEPTH: usize = 16;

pub(super) const fn word(word: &'static str, doc: &'static str) -> Choice {
    Choice {
        word,
        key: None,
        doc,
    }
}
const fn slot(name: &'static str, kind: SlotKind) -> Slot {
    Slot {
        name,
        kind,
        required: true,
    }
}
const PATH: Slot = slot("PATH", SlotKind::Path);
const OPTIONAL_PATH: Slot = Slot {
    required: false,
    ..PATH
};
const KEYMAP: Slot = slot("KEYMAP", SlotKind::Keymap);
/// How to leave a document with unsaved changes: `save [PATH]` or `discard`.
const DEPARTURE: &[Slot] = &[
    Slot {
        name: "DECISION",
        kind: SlotKind::Choice(&[
            Choice {
                key: Some('s'),
                ..word(
                    "save",
                    "Save first, then continue; Tab, then PATH, saves elsewhere",
                )
            },
            Choice {
                key: Some('d'),
                ..word("discard", "Discard the unsaved changes")
            },
        ]),
        required: false,
    },
    OPTIONAL_PATH,
];
const KEYS: Slot = slot("KEYS", SlotKind::Word);
/// save-some-buffers's question, with the keys of Emacs's.
const SAVE_ANSWER: Slot = Slot {
    name: "ANSWER",
    kind: SlotKind::Choice(&[
        Choice {
            key: Some('y'),
            ..word("yes", "Save this file")
        },
        Choice {
            key: Some('n'),
            ..word("no", "Leave it unsaved")
        },
        Choice {
            key: Some('!'),
            ..word("all", "Save it and every one after it")
        },
        Choice {
            key: Some('q'),
            ..word("quit", "Save no more")
        },
    ]),
    required: false,
};
const FACE: Slot = slot(
    "FACE",
    SlotKind::Choice(&[
        word("todo", "Bold yellow, for markers such as TODO"),
        word("error", "Red"),
        word("info", "Blue"),
        word("mark", "The next of the mark backgrounds"),
        word("mark1", "First mark background"),
        word("mark2", "Second mark background"),
        word("mark3", "Third mark background"),
        word("mark4", "Fourth mark background"),
        word("mark5", "Fifth mark background"),
        word("mark6", "Sixth mark background"),
        word("mark7", "Seventh mark background"),
        word("mark8", "Eighth mark background"),
    ]),
);
/// `flag-lines GROUP FACE SIGN LINES`: LINES are one-based numbers or
/// ranges such as `3-7`, separated by spaces.
fn flag_lines(args: &str) -> Result<Command, String> {
    let mut words = args.split_whitespace();
    let (Some(group), Some(face), Some(sign)) = (words.next(), words.next(), words.next()) else {
        return Err("flag-lines needs GROUP FACE SIGN LINES".into());
    };

    let mut lines = vec![];
    for word in words {
        let number = |text: &str| {
            text.parse::<usize>()
                .ok()
                .filter(|n| *n > 0)
                .ok_or_else(|| format!("not a line or range: {word}"))
        };
        let (first, last) = match word.split_once('-') {
            Some((first, last)) => (number(first)?, number(last)?),
            None => (number(word)?, number(word)?),
        };
        if last < first || last - first >= 1_000_000 {
            return Err(format!("not a line or range: {word}"));
        }
        lines.extend(first - 1..last);
    }
    if lines.is_empty() {
        return Err("flag-lines needs GROUP FACE SIGN LINES".into());
    }
    Ok(Command::Setup(SetupCommand::FlagLines {
        group: group.to_owned(),
        face: face.to_owned(),
        sign: sign.to_owned(),
        lines,
    }))
}
fn highlight(args: &str, local: bool) -> Result<Command, String> {
    let (face, pattern) = split(args);
    let face = face.to_owned();
    let pattern = regex::Regex::new(&required(pattern)?).map_err(|e| e.to_string())?;
    Ok(Command::Setup(SetupCommand::Highlight {
        local,
        face,
        pattern,
    }))
}
const EVENT: Slot = slot(
    "EVENT",
    SlotKind::Choice(&[
        word("open", "A file loaded into a new document; its path"),
        word(
            "new",
            "An untitled or scratch document was created; its kind",
        ),
        word("save", "A file was saved; its path"),
        word("close", "A document closed; its buffer name"),
        word("mode", "The edit mode changed; the new mode"),
        word(
            "focus",
            "The current window shows another view; its buffer name",
        ),
        word("change", "A document's text changed; its buffer name"),
        word(
            "selection",
            "The selection or caret moved without the text changing; the buffer name",
        ),
        word(
            "idle",
            "No key for idle-time milliseconds since the last one; the buffer name",
        ),
    ]),
);
const ARGUMENTS: &[Slot] = &[Slot {
    name: "ARGS",
    kind: SlotKind::Rest,
    required: false,
}];
/// Formats slots as a synopsis such as `MODE KEYS COMMAND` or `[PATH]`.
pub fn synopsis(slots: &[Slot]) -> String {
    slots
        .iter()
        .map(|slot| {
            if slot.required {
                slot.name.to_owned()
            } else {
                format!("[{}]", slot.name)
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Clone, Copy)]
pub struct Builtin {
    pub name: &'static str,
    pub slots: &'static [Slot],
    pub doc: &'static str,
    build: fn(&str) -> Result<Command, String>,
}
/// Commands with a required argument run without one open the command line
/// prefilled with their name, like an Emacs `interactive` declaration.
fn interactive(name: &str) -> Command {
    Command::Prompt(PromptCommand::Ex(format!("{name} ")))
}
fn location(text: &str) -> Result<Command, String> {
    let parse = || {
        let (line, column) = text.trim().split_once(':').unwrap_or((text.trim(), "1"));
        Some(Command::Edit(Edit::Goto {
            line: line.parse::<usize>().ok()?.checked_sub(1)?,
            column: column.parse::<usize>().ok()?.checked_sub(1)?,
        }))
    };
    parse().ok_or_else(|| "expected positive LINE[:COLUMN]".into())
}
fn bare(command: Command) -> impl Fn(&str) -> Result<Command, String> {
    move |args| {
        if args.is_empty() {
            Ok(command.clone())
        } else {
            Err("command takes no argument".into())
        }
    }
}
fn path_or(args: &str, path: fn(std::path::PathBuf) -> Command, bare: Command) -> Command {
    if args.is_empty() {
        bare
    } else {
        path(args.into())
    }
}
/// `resize-window [HOW [CELLS]]`: without HOW, the step-by-step mode.
fn window_resize(args: &str) -> Result<Command, String> {
    let (how, cells) = split(args.trim());
    let cells = match cells {
        "" => 1,
        cells => cells
            .parse::<u16>()
            .ok()
            .filter(|n| *n > 0)
            .ok_or_else(|| format!("{cells} is not a number of cells"))?,
    };
    let cells = i32::from(cells);
    Ok(Command::Window(match how {
        "" => WindowCommand::ResizeMode,
        "wider" => WindowCommand::Resize(Axis::Columns, cells),
        "narrower" => WindowCommand::Resize(Axis::Columns, -cells),
        "taller" => WindowCommand::Resize(Axis::Rows, cells),
        "shorter" => WindowCommand::Resize(Axis::Rows, -cells),
        "reset" => WindowCommand::ResetSizes,
        how => return Err(format!("unknown resize {how}")),
    }))
}
const HOW: Slot = Slot {
    name: "HOW",
    kind: SlotKind::Choice(&[
        word("wider", "More columns, from the windows beside it"),
        word("narrower", "Fewer columns, to the window beside it"),
        word("taller", "More rows, from the windows above or below it"),
        word("shorter", "Fewer rows, to the window above or below it"),
        word(
            "reset",
            "Equal splits, and side windows at their opening size",
        ),
    ]),
    required: false,
};
const CELLS: Slot = Slot {
    name: "CELLS",
    kind: SlotKind::Word,
    required: false,
};
fn window_split(args: &str, axis: Axis) -> Command {
    let path = (!args.is_empty()).then(|| args.into());
    Command::Window(WindowCommand::Split(axis, path))
}
/// `set` and `set-local`: the value is checked here, so a bad one never
/// reaches the application.
fn option(args: &str, local: bool) -> Result<Command, String> {
    let (name, value) = split(args.trim());
    let info = crate::options::info(name).ok_or_else(|| format!("unknown option {name}"))?;
    if value.is_empty() {
        return Err(format!("{name} needs a value: {}", info.values()));
    }
    Ok(Command::Setup(SetupCommand::SetOption {
        local,
        name: info.name,
        value: info.parse(value)?,
    }))
}
pub(crate) fn hook_event(name: &str) -> Result<&'static str, String> {
    let SlotKind::Choice(events) = EVENT.kind else {
        unreachable!()
    };
    events
        .iter()
        .find(|event| event.word == name)
        .map(|event| event.word)
        .ok_or_else(|| format!("unknown event {name}"))
}
fn required(args: &str) -> Result<String, String> {
    if args.is_empty() {
        Err("command requires an argument".into())
    } else {
        Ok(args.to_owned())
    }
}
fn departure(args: &str) -> Result<Option<Departure>, String> {
    match split(args) {
        ("", _) => Ok(None),
        ("save", path) => Ok(Some(Departure::Save(
            (!path.is_empty()).then(|| path.into()),
        ))),
        ("discard", "") => Ok(Some(Departure::Discard)),
        ("discard", _) => Err("discard takes no PATH".into()),
        (word, _) => Err(format!("expected save or discard, not {word}")),
    }
}
fn split(args: &str) -> (&str, &str) {
    args.split_once(char::is_whitespace)
        .map_or((args, ""), |(head, tail)| (head, tail.trim_start()))
}
/// Splits off a KEYS argument: a word, or keys apart by spaces in double
/// quotes, as Emacs's `(kbd "C-c v c")`.
fn split_keys(args: &str) -> (&str, &str) {
    if let Some(quoted) = args.strip_prefix('"') {
        return match quoted.split_once('"') {
            Some((keys, rest)) => (keys, rest.trim_start()),
            None => (quoted, ""),
        };
    }
    split(args)
}
fn keys(text: &str) -> Result<Vec<super::KeyStroke>, String> {
    super::KeyStroke::parse_sequence(text)
}
fn digit(text: &str) -> Result<usize, String> {
    text.trim()
        .parse()
        .map_err(|_| format!("not a digit: {text}"))
}
fn typed(text: &str) -> Result<Vec<super::UserInput>, String> {
    Ok(keys(text)?.into_iter().map(super::UserInput::Key).collect())
}
fn modal(action: Action) -> Command {
    Command::Modal(action)
}
fn macro_action(action: MacroAction) -> Command {
    Command::Modal(Action::Macro(action))
}
/// An optional whole number for a macro counter.
fn counter(argument: &str) -> Result<Option<i64>, String> {
    match argument.trim() {
        "" => Ok(None),
        text => text
            .parse()
            .map(Some)
            .map_err(|_| format!("not a number: {text}")),
    }
}
const fn step(step: Step, extend: bool) -> Action {
    Action::Move { step, extend }
}
const fn thing(symbol: bool, backward: bool) -> Action {
    Action::Thing { symbol, backward }
}
fn move_line(backward: bool, extend: bool) -> Command {
    Command::Edit(Edit::Move {
        motion: if backward { Motion::Up } else { Motion::Down },
        extend,
    })
}

macro_rules! builtin {
    ($name:literal, [$($slot:expr),*], $doc:literal, $build:expr) => {
        Builtin {
            name: $name,
            slots: &[$($slot),*],
            doc: $doc,
            build: $build,
        }
    };
    ($name:literal, $doc:literal, $command:expr) => {
        builtin!($name, [], $doc, |args| bare($command)(args))
    };
}
mod configuration;
mod editing;
mod integration;
mod macros;
mod modal;
mod navigation;
mod workspace;

const GROUPS: &[&[Builtin]] = &[
    workspace::COMMANDS,
    editing::COMMANDS,
    modal::COMMANDS,
    macros::COMMANDS,
    configuration::COMMANDS,
    navigation::COMMANDS,
    integration::COMMANDS,
];

const fn catalog_size() -> usize {
    let mut count = 0;
    let mut group = 0;
    while group < GROUPS.len() {
        count += GROUPS[group].len();
        group += 1;
    }
    count
}

const fn catalog() -> [Builtin; catalog_size()] {
    let mut entries = [GROUPS[0][0]; catalog_size()];
    let mut index = 0;
    let mut group = 0;
    while group < GROUPS.len() {
        let mut command = 0;
        while command < GROUPS[group].len() {
            entries[index] = GROUPS[group][command];
            index += 1;
            command += 1;
        }
        group += 1;
    }
    entries
}

pub static BUILTINS: &[Builtin] = &catalog();

/// A user command: a body of command lines and what help shows for it;
/// without a description help shows the body.
struct Entry {
    body: String,
    doc: Option<String>,
    slots: Option<&'static [Slot]>,
}
/// A command name with its signature and documentation, for help and the
/// command line.
#[derive(Clone)]
pub struct CommandInfo {
    pub name: String,
    pub slots: &'static [Slot],
    pub doc: String,
    builtin: Option<&'static Builtin>,
}
impl CommandInfo {
    pub fn synopsis(&self) -> String {
        synopsis(self.slots)
    }
}
pub enum CheckError {
    /// A required slot is empty; the command line can continue with it.
    Missing(&'static str),
    Invalid(String),
}
impl std::fmt::Display for CheckError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Missing(slot) => write!(f, "needs {slot}"),
            Self::Invalid(error) => f.write_str(error),
        }
    }
}
/// Checks a command line against a catalog without running it: the name must
/// exist, required slots must be filled and built-in arguments must parse.
pub fn check(catalog: &[CommandInfo], line: &str) -> Result<(), CheckError> {
    let line = line.trim();
    if line.parse::<usize>().is_ok_and(|n| n > 0) {
        return Ok(());
    }
    let (name, args) = split(line);
    let info = catalog
        .iter()
        .find(|info| info.name == name)
        .ok_or_else(|| CheckError::Invalid(format!("unknown command: {name}")))?;
    let mut rest = args;
    for (index, slot) in info.slots.iter().enumerate() {
        let (word, tail) = if index + 1 == info.slots.len() {
            (rest, "")
        } else {
            split(rest)
        };
        if word.is_empty() && slot.required {
            return Err(CheckError::Missing(slot.name));
        }
        rest = tail;
    }
    match info.builtin {
        // Arguments that read state are checked once they are expanded.
        Some(_) if super::expand::has_expansions(args) && !holds_commands(line) => Ok(()),
        Some(builtin) => (builtin.build)(args)
            .map(|_| ())
            .map_err(CheckError::Invalid),
        None => Ok(()),
    }
}

#[derive(Default)]
pub struct Registry {
    entries: BTreeMap<String, Entry>,
}
fn builtin(name: &str) -> Option<&'static Builtin> {
    BUILTINS.iter().find(|b| b.name == name)
}
/// Commands whose arguments are command lines run later; expansions in them
/// wait until then.
pub(super) fn holds_commands(line: &str) -> bool {
    let name = split(line.trim()).0;
    builtin(name).is_some_and(|b| matches!(b.name, "define-command" | "map" | "hook"))
}
fn reserved(name: &str) -> bool {
    builtin(name).is_some() || LineEdit::parse(name).is_some()
}
fn substitute(body: &str, args: &str) -> String {
    let words: Vec<_> = args.split_whitespace().collect();
    let mut out = body.replace("%arg{@}", args);
    for (index, word) in words.iter().enumerate().take(9) {
        out = out.replace(&format!("%arg{{{}}}", index + 1), word);
    }
    for index in words.len().min(9)..9 {
        out = out.replace(&format!("%arg{{{}}}", index + 1), "");
    }
    out
}
/// Splits a body at unescaped `;`; `\;` is a literal semicolon.
fn statements(body: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut chars = body.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\\' if chars.peek() == Some(&';') => {
                out.last_mut().unwrap().push(chars.next().unwrap())
            }
            ';' => out.push(String::new()),
            ch => out.last_mut().unwrap().push(ch),
        }
    }
    out.into_iter()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect()
}
impl Registry {
    pub fn define(
        &mut self,
        name: String,
        body: String,
        doc: Option<String>,
        slots: Option<&'static [Slot]>,
    ) -> Result<(), String> {
        if reserved(&name) {
            return Err(format!("{name} is a built-in command"));
        }
        self.entries.insert(name, Entry { body, doc, slots });
        Ok(())
    }
    /// Parses a line naming only built-in commands; used for default tables.
    pub(super) fn parse_builtin(&self, line: &str) -> Result<Command, String> {
        let (name, args) = split(line.trim());
        if let Some((edit, extend)) = LineEdit::parse(name) {
            return bare(edit.command(extend))(args);
        }
        let builtin = builtin(name).ok_or_else(|| format!("unknown command: {name}"))?;
        (builtin.build)(args)
    }
    pub(super) fn knows(&self, line: &str) -> bool {
        let name = split(line.trim()).0;
        reserved(name) || self.entries.contains_key(name)
    }
    /// Expands a command line into commands executed in order. User
    /// definitions expand eagerly so that unknown commands and bad arguments
    /// stop the line before any part runs; statements reading `%opt` or
    /// `%val`, stay named and run when reached.
    pub(super) fn expand(&self, line: &str) -> Result<Vec<Command>, String> {
        let mut out = vec![];
        self.expand_into(line, 0, &mut out)?;
        Ok(out)
    }
    fn expand_into(&self, line: &str, depth: usize, out: &mut Vec<Command>) -> Result<(), String> {
        let line = line.trim();
        if let Some(target) = line.parse::<usize>().ok().filter(|n| *n > 0) {
            out.push(Command::Edit(Edit::Goto {
                line: target - 1,
                column: 0,
            }));
            return Ok(());
        }
        let (name, args) = split(line);
        match self.entries.get(name) {
            Some(Entry { body, .. }) => {
                if depth == MAX_DEPTH {
                    return Err(format!(
                        "{name} recursively expands more than {MAX_DEPTH} levels"
                    ));
                }
                for statement in statements(&substitute(body, args)) {
                    self.expand_into(&statement, depth + 1, out)?;
                }
            }
            // A statement reading state is expanded when its turn comes.
            None if depth > 0 && super::expand::has_expansions(line) && !holds_commands(line) => {
                if !self.knows(name) {
                    return Err(format!("unknown command: {name}"));
                }
                out.push(Command::Named(line.into()));
            }
            None => out.push(
                self.parse_builtin(line)
                    .map_err(|e| format!("{name}: {e}"))?,
            ),
        }
        Ok(())
    }
    /// Every command, built-ins first, then user commands.
    pub fn commands(&self) -> Vec<CommandInfo> {
        let builtins = BUILTINS.iter().map(|b| CommandInfo {
            name: b.name.into(),
            slots: b.slots,
            doc: b.doc.into(),
            builtin: Some(b),
        });
        let edits = LINE_EDITS.iter().map(|(name, _, doc)| CommandInfo {
            name: (*name).into(),
            slots: &[],
            doc: (*doc).into(),
            builtin: None,
        });
        let custom = self.entries.iter().map(|(name, entry)| CommandInfo {
            name: name.clone(),
            slots: entry.slots.unwrap_or(ARGUMENTS),
            doc: entry.doc.clone().unwrap_or_else(|| entry.body.clone()),
            builtin: None,
        });
        builtins.chain(edits).chain(custom).collect()
    }
    pub fn doc(&self, line: &str) -> String {
        let name = split(line.trim()).0;
        if let Some(builtin) = builtin(name) {
            return builtin.doc.into();
        }
        if let Some((_, _, doc)) = LINE_EDITS.iter().find(|(n, ..)| *n == name) {
            return (*doc).into();
        }
        if let Some((edit, _)) = LineEdit::parse(name) {
            let doc = LINE_EDITS.iter().find(|(_, e, _)| *e == edit).unwrap().2;
            return format!("{doc}, extending the selection");
        }
        if let Some((_, _, doc)) = PROMPT_ACTIONS.iter().find(|(n, ..)| *n == name) {
            return (*doc).into();
        }
        self.entries.get(name).map_or_else(String::new, |entry| {
            entry.doc.clone().unwrap_or_else(|| entry.body.clone())
        })
    }
}
