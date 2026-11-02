//! Named commands shared by key bindings, the command line, configuration and
//! the command palette. Built-in names are fixed; registered Rust handlers and
//! user definitions share one replaceable namespace.
use super::{
    Command, Departure, EditMode, WindowCommand,
    keymap::{Context, LINE_EDITS, LineEdit, PROMPT_ACTIONS},
    vim::{Insert, VimCommand},
};
use crate::{
    application::{Application, Axis, ClipboardAction, Direction},
    core::EditError,
    editor::{Command as Edit, Motion},
};
use std::collections::BTreeMap;

pub type CommandHandler = fn(&Application) -> Result<Command, EditError>;
const MAX_DEPTH: usize = 16;

/// How the command line completes an argument and whether Enter requires
/// one of the candidates.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SlotKind {
    Path,
    File,
    Buffer,
    /// One of fixed words.
    Choice(&'static [Choice]),
    /// The name of an option.
    Option,
    /// A recently used file.
    Recent,
    /// One of the items of the question being asked.
    Item,
    Word,
    Rest,
}
impl SlotKind {
    pub fn requires_match(self) -> bool {
        matches!(
            self,
            Self::File | Self::Buffer | Self::Choice(_) | Self::Option | Self::Recent | Self::Item
        )
    }
}
/// A word of a `Choice` slot. A key makes the slot's keymap: typed while
/// the slot is empty, it chooses the word and confirms at once.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Choice {
    pub word: &'static str,
    pub key: Option<char>,
    pub doc: &'static str,
}
const fn word(word: &'static str, doc: &'static str) -> Choice {
    Choice {
        word,
        key: None,
        doc,
    }
}
/// A positional argument. Every slot but the last is one word; the last
/// takes the rest of the line.
#[derive(Clone, Copy, Debug)]
pub struct Slot {
    pub name: &'static str,
    pub kind: SlotKind,
    pub required: bool,
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
const MODE: Slot = slot(
    "MODE",
    SlotKind::Choice(&[
        word("normal", "Normal mode keys"),
        word("visual", "Visual mode keys"),
        word("insert", "Insert mode keys"),
        word("completion", "Keys while the completion list shows"),
        word("snippet", "Keys while a snippet has places left"),
        word("prompt", "Command line and prompt keys"),
    ]),
);
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
    ]),
);
/// `flag-lines GROUP FACE SIGN LINES`: LINES are one-based numbers or
/// ranges such as `3-7`, separated by spaces.
fn flag_lines(args: &str) -> Result<Command, String> {
    let mut words = args.split_whitespace();
    let (Some(group), Some(face), Some(sign)) = (words.next(), words.next(), words.next()) else {
        return Err("flag-lines needs GROUP FACE SIGN LINES".into());
    };
    let flag = crate::application::Flag::new(face, sign)?;
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
    Ok(Command::FlagLines {
        group: group.to_owned(),
        flag,
        lines,
    })
}
fn highlight(args: &str, local: bool) -> Result<Command, String> {
    let (face, pattern) = split(args);
    let face = crate::application::Face::parse(face)?;
    let pattern = regex::Regex::new(&required(pattern)?).map_err(|e| e.to_string())?;
    Ok(Command::Highlight {
        local,
        face,
        pattern,
    })
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

pub struct Builtin {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    pub slots: &'static [Slot],
    pub doc: &'static str,
    build: fn(&str) -> Result<Command, String>,
}
/// Commands with a required argument run without one open the command line
/// prefilled with their name, like an Emacs `interactive` declaration.
fn interactive(name: &str) -> Command {
    Command::Ex(format!("{name} "))
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
    Ok(Command::SetOption {
        local,
        name: info.name,
        value: info.parse(value)?,
    })
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
fn context(name: &str) -> Result<Context, String> {
    Context::parse(name).ok_or_else(|| format!("unknown mode: {name}"))
}
fn keys(text: &str) -> Result<Vec<super::KeyStroke>, String> {
    super::KeyStroke::parse_sequence(text)
}
fn move_line(backward: bool, extend: bool) -> Command {
    Command::Edit(Edit::Move {
        motion: if backward { Motion::Up } else { Motion::Down },
        extend,
    })
}

macro_rules! builtin {
    ($name:literal $(| $alias:literal)*, [$($slot:expr),*], $doc:literal, $build:expr) => {
        Builtin {
            name: $name,
            aliases: &[$($alias),*],
            slots: &[$($slot),*],
            doc: $doc,
            build: $build,
        }
    };
    ($name:literal $(| $alias:literal)*, $doc:literal, $command:expr) => {
        builtin!($name $(| $alias)*, [], $doc, |args| bare($command)(args))
    };
}
pub static BUILTINS: &[Builtin] = &[
    builtin!(
        "edit" | "e",
        [OPTIONAL_PATH],
        "Open a file; reload the current file without PATH",
        |a| { Ok(path_or(a, Command::OpenPath, Command::Reload(None))) }
    ),
    builtin!(
        "reload",
        [DEPARTURE[0], DEPARTURE[1]],
        "Reload the current file from disk",
        |a| departure(a).map(Command::Reload)
    ),
    builtin!(
        "open" | "o",
        [PATH],
        "Open a file; a new file is created when saved",
        |a| { Ok(path_or(a, Command::OpenPath, Command::OpenPrompt)) }
    ),
    builtin!(
        "recent",
        [slot("FILE", SlotKind::Recent)],
        "Open a recently used file",
        |a| { Ok(path_or(a, Command::OpenProjectFile, interactive("recent"))) }
    ),
    builtin!(
        "write" | "w",
        [OPTIONAL_PATH],
        "Save; save to PATH when given",
        |a| {
            Ok(path_or(
                a,
                Command::SavePath,
                Command::Save { choose_path: false },
            ))
        }
    ),
    builtin!("saveas", [PATH], "Save to another path", |a| {
        Ok(path_or(
            a,
            Command::SavePath,
            Command::Save { choose_path: true },
        ))
    }),
    builtin!(
        "quit" | "q",
        [DEPARTURE[0], DEPARTURE[1]],
        "Quit, deciding for each unsaved document",
        |a| departure(a).map(Command::Quit)
    ),
    builtin!(
        "write-quit" | "wq" | "x",
        "Save the current document and quit",
        Command::WriteQuit
    ),
    builtin!(
        "close" | "bd" | "bdelete",
        [DEPARTURE[0], DEPARTURE[1]],
        "Close the current document",
        |a| departure(a).map(Command::Close)
    ),
    builtin!(
        "buffer" | "b" | "buffers" | "ls" | "files",
        [slot("NAME", SlotKind::Buffer)],
        "Switch to an open document",
        |a| Ok(if a.is_empty() {
            interactive("buffer")
        } else {
            Command::Buffer(a.into())
        })
    ),
    builtin!(
        "next-view" | "bn" | "bnext",
        "Focus the next view",
        Command::NextView
    ),
    builtin!("new" | "enew", "Create an untitled document", Command::New),
    builtin!(
        "split" | "sp",
        [OPTIONAL_PATH],
        "Split the window into two above each other; open PATH in the new one",
        |a| Ok(window_split(a, Axis::Rows))
    ),
    builtin!(
        "vsplit" | "vs",
        [OPTIONAL_PATH],
        "Split the window into two side by side; open PATH in the new one",
        |a| Ok(window_split(a, Axis::Columns))
    ),
    builtin!(
        "close-window" | "clo",
        "Close the window; its document stays open",
        Command::Window(WindowCommand::Close)
    ),
    builtin!(
        "only" | "on",
        "Close every other window",
        Command::Window(WindowCommand::Only)
    ),
    builtin!(
        "window-left",
        "Focus the window to the left",
        Command::Window(WindowCommand::Focus(Direction::Left))
    ),
    builtin!(
        "window-right",
        "Focus the window to the right",
        Command::Window(WindowCommand::Focus(Direction::Right))
    ),
    builtin!(
        "window-up",
        "Focus the window above",
        Command::Window(WindowCommand::Focus(Direction::Up))
    ),
    builtin!(
        "window-down",
        "Focus the window below",
        Command::Window(WindowCommand::Focus(Direction::Down))
    ),
    builtin!(
        "window-next",
        "Focus the next window",
        Command::Window(WindowCommand::Cycle { backward: false })
    ),
    builtin!(
        "window-previous",
        "Focus the previous window",
        Command::Window(WindowCommand::Cycle { backward: true })
    ),
    builtin!(
        "project-root",
        [OPTIONAL_PATH],
        "Show the project, or make a directory the project of this document",
        |a| { Ok(Command::ProjectRoot((!a.is_empty()).then(|| a.into()))) }
    ),
    builtin!(
        "project",
        [slot("FILE", SlotKind::File)],
        "Open a project file",
        |a| { Ok(path_or(a, Command::OpenProjectFile, interactive("project"))) }
    ),
    builtin!("search", "Search the document", Command::Search),
    builtin!(
        "search-backward",
        "Search the document backward",
        Command::Vim(VimCommand::Search { backward: true })
    ),
    builtin!("replace", "Search and replace", Command::Replace),
    builtin!(
        "goto",
        [slot("LINE[:COLUMN]", SlotKind::Word)],
        "Go to a line and logical column",
        |a| if a.is_empty() {
            Ok(interactive("goto"))
        } else {
            location(a)
        }
    ),
    builtin!("help", "Show key bindings and commands", Command::Help),
    builtin!(
        "commands" | "command-line",
        "Open the command line to choose a command",
        Command::Ex(String::new())
    ),
    builtin!(
        "undo",
        "Undo",
        Command::Vim(VimCommand::Undo {
            redo: false,
            count: 1
        })
    ),
    builtin!(
        "redo",
        "Redo",
        Command::Vim(VimCommand::Undo {
            redo: true,
            count: 1
        })
    ),
    builtin!(
        "completion-trigger",
        "List candidates for the word at the caret",
        Command::Completion(super::completion::Action::Trigger)
    ),
    builtin!(
        "completion-dismiss",
        "Close the completion list",
        Command::Completion(super::completion::Action::Dismiss)
    ),
    builtin!(
        "completion-next",
        "Select the next candidate",
        Command::Completion(super::completion::Action::Move { backward: false })
    ),
    builtin!(
        "completion-previous",
        "Select the previous candidate",
        Command::Completion(super::completion::Action::Move { backward: true })
    ),
    builtin!(
        "completion-accept",
        "Take the selected candidate, keeping the text after the caret",
        Command::Completion(super::completion::Action::Accept)
    ),
    builtin!(
        "completion-replace",
        "Take the selected or first candidate, replacing to the end of the word",
        Command::Completion(super::completion::Action::Replace)
    ),
    builtin!(
        "snippet",
        [slot("BODY", SlotKind::Rest)],
        "Insert a snippet at the caret; $1, ${1:text} and $0 are its places",
        |a| Ok(Command::Snippet(required(a)?))
    ),
    builtin!(
        "snippet-next",
        "Go to the next place of the snippet",
        Command::SnippetStep { backward: false }
    ),
    builtin!(
        "snippet-previous",
        "Go to the previous place of the snippet",
        Command::SnippetStep { backward: true }
    ),
    builtin!(
        "recenter",
        "Scroll so the caret's line is in the middle of the window",
        Command::Vim(VimCommand::Recenter)
    ),
    builtin!(
        "half-page-down",
        "Move down half a page and scroll with it",
        Command::Vim(VimCommand::HalfPage {
            down: true,
            count: 0
        })
    ),
    builtin!(
        "half-page-up",
        "Move up half a page and scroll with it",
        Command::Vim(VimCommand::HalfPage {
            down: false,
            count: 0
        })
    ),
    builtin!(
        "copy",
        "Copy the selection or line",
        Command::Clipboard(ClipboardAction::Copy)
    ),
    builtin!(
        "cut",
        "Cut the selection or line",
        Command::Clipboard(ClipboardAction::Cut)
    ),
    builtin!("paste", "Paste", Command::Clipboard(ClipboardAction::Paste)),
    builtin!(
        "page-up",
        "Scroll one page up",
        Command::Page {
            backward: true,
            extend: false
        }
    ),
    builtin!(
        "page-down",
        "Scroll one page down",
        Command::Page {
            backward: false,
            extend: false
        }
    ),
    builtin!("move-up", "Move one line up", move_line(true, false)),
    builtin!("move-down", "Move one line down", move_line(false, false)),
    builtin!(
        "extend-move-up",
        "Extend the selection one line up",
        move_line(true, true)
    ),
    builtin!(
        "extend-move-down",
        "Extend the selection one line down",
        move_line(false, true)
    ),
    builtin!(
        "document-start",
        "Move to the document start",
        Command::Edit(Edit::Move {
            motion: Motion::DocumentStart,
            extend: false,
        })
    ),
    builtin!(
        "document-end",
        "Move to the document end",
        Command::Edit(Edit::Move {
            motion: Motion::DocumentEnd,
            extend: false,
        })
    ),
    builtin!(
        "select-all",
        "Select the whole document",
        Command::Edit(Edit::SelectAll)
    ),
    builtin!(
        "newline",
        "Insert a line break with language indentation",
        Command::Edit(Edit::Enter)
    ),
    builtin!(
        "insert-tab",
        "Insert indentation, or indent selected lines",
        Command::Edit(Edit::InsertTab)
    ),
    builtin!(
        "insert-literal-tab",
        "Insert a tab character",
        Command::Edit(Edit::InsertLiteralTab)
    ),
    builtin!(
        "indent",
        "Indent the current or selected lines",
        Command::Edit(Edit::IndentSelection { outdent: false })
    ),
    builtin!(
        "outdent",
        "Outdent the current or selected lines",
        Command::Edit(Edit::IndentSelection { outdent: true })
    ),
    builtin!(
        "normal-mode",
        "Leave Insert or Visual",
        Command::Vim(VimCommand::Insert(Insert::Leave))
    ),
    builtin!(
        "insert-mode",
        "Insert before the cursor",
        Command::Vim(VimCommand::Insert(Insert::Before))
    ),
    builtin!(
        "visual-mode",
        "Characterwise Visual",
        Command::SetMode(EditMode::Visual)
    ),
    builtin!(
        "map",
        [MODE, KEYS, slot("COMMAND", SlotKind::Rest)],
        "Bind keys in normal, visual, insert or prompt",
        |a| {
            let (mode, rest) = split(a);
            let (sequence, target) = split(rest);
            Ok(Command::Map {
                context: context(mode)?,
                keys: keys(sequence)?,
                target: required(target)?,
            })
        }
    ),
    builtin!("unmap", [MODE, KEYS], "Remove a user binding", |a| {
        let (mode, sequence) = split(a);
        Ok(Command::Unmap {
            context: context(mode)?,
            keys: keys(&required(sequence)?)?,
        })
    }),
    builtin!(
        "define-command",
        [slot("NAME", SlotKind::Word), slot("BODY", SlotKind::Rest)],
        "Define a command from ;-separated commands",
        |a| {
            let (name, body) = split(a);
            Ok(Command::Define {
                name: required(name)?,
                body: required(body)?,
            })
        }
    ),
    builtin!(
        "hook",
        [
            EVENT,
            slot("FILTER", SlotKind::Word),
            slot("COMMAND", SlotKind::Rest)
        ],
        "Run a command when an event's parameter matches FILTER in full",
        |a| {
            let (event, rest) = split(a);
            let (filter, command) = split(rest);
            let event = hook_event(event)?;
            let filter = required(filter)?;
            super::hooks::Hook::new(event, &filter, String::new())?;
            Ok(Command::Hook {
                event,
                filter,
                command: required(command)?,
            })
        }
    ),
    builtin!(
        "unhook",
        [
            EVENT,
            Slot {
                required: false,
                ..slot("FILTER", SlotKind::Word)
            }
        ],
        "Remove an event's hooks, or only those with FILTER",
        |a| {
            let (event, filter) = split(a);
            Ok(Command::Unhook {
                event: hook_event(event)?,
                filter: (!filter.is_empty()).then(|| filter.to_owned()),
            })
        }
    ),
    builtin!(
        "set",
        [
            slot("OPTION", SlotKind::Option),
            slot("VALUE", SlotKind::Rest)
        ],
        "Set an option for every document",
        |a| option(a, false)
    ),
    builtin!(
        "set-local",
        [
            slot("OPTION", SlotKind::Option),
            slot("VALUE", SlotKind::Rest)
        ],
        "Set an option for the current document only",
        |a| option(a, true)
    ),
    builtin!(
        "unset-local",
        [slot("OPTION", SlotKind::Option)],
        "Let the current document use the global value of an option again",
        |a| {
            let info = crate::options::info(a.trim())
                .ok_or_else(|| format!("unknown option {}", a.trim()))?;
            Ok(Command::UnsetOption(info.name))
        }
    ),
    builtin!(
        "grep",
        [slot("PATTERN", SlotKind::Rest)],
        "Search project files for a regular expression; lowercase ignores case",
        |a| Ok(if a.is_empty() {
            interactive("grep")
        } else {
            Command::Grep(a.into())
        })
    ),
    builtin!(
        "jump",
        "Open the location on the caret line, as in search results",
        Command::Jump
    ),
    builtin!(
        "jump-back",
        "Go back to where the caret jumped from",
        Command::JumpBack
    ),
    builtin!(
        "jump-forward",
        "Go forward again after jump-back",
        Command::JumpForward
    ),
    builtin!(
        "next-result" | "cn" | "cnext",
        "Open the next location in the latest search or run output",
        Command::ResultStep { backward: false }
    ),
    builtin!(
        "previous-result" | "cp" | "cprevious",
        "Open the previous location in the latest search or run output",
        Command::ResultStep { backward: true }
    ),
    builtin!(
        "run" | "make",
        [slot("SHELL-COMMAND", SlotKind::Rest)],
        "Run a command in the background; its output streams into *run*",
        |a| { Ok(Command::Run(required(a)?)) }
    ),
    builtin!(
        "check-files" | "checktime",
        "Reload files changed on disk without unsaved edits; report the others",
        Command::CheckFiles
    ),
    builtin!(
        "echo",
        [Slot {
            required: false,
            ..slot("TEXT", SlotKind::Rest)
        }],
        "Show TEXT in the message line",
        |a| Ok(Command::Echo(a.to_owned()))
    ),
    builtin!(
        "highlight",
        [FACE, slot("PATTERN", SlotKind::Rest)],
        "Highlight a regular expression in every document",
        |a| highlight(a, false)
    ),
    builtin!(
        "highlight-local",
        [FACE, slot("PATTERN", SlotKind::Rest)],
        "Highlight a regular expression in the current document",
        |a| highlight(a, true)
    ),
    builtin!(
        "unhighlight",
        [Slot {
            required: false,
            ..slot("PATTERN", SlotKind::Rest)
        }],
        "Remove the highlights of PATTERN, or all, here and everywhere",
        |a| Ok(Command::Unhighlight((!a.is_empty()).then(|| a.to_owned())))
    ),
    builtin!(
        "flag-lines",
        [
            slot("GROUP", SlotKind::Word),
            FACE,
            slot("SIGN", SlotKind::Word),
            slot("LINES", SlotKind::Rest)
        ],
        "Put a one-character SIGN in the gutter of LINES (3 or 3-7) of the current document",
        flag_lines
    ),
    builtin!(
        "unflag-lines",
        [Slot {
            required: false,
            ..slot("GROUP", SlotKind::Rest)
        }],
        "Remove the flags of GROUP, or all, from the current document",
        |a| Ok(Command::UnflagLines((!a.is_empty()).then(|| a.to_owned())))
    ),
    builtin!(
        "each-line",
        [slot("KEYS", SlotKind::Rest)],
        "Type KEYS in Normal mode at the start of each selected line, as Vim's :normal",
        |a| Ok(Command::EachLine(keys(&required(a)?)?))
    ),
    builtin!(
        "each-match",
        [
            slot("PATTERN", SlotKind::Word),
            slot("KEYS", SlotKind::Rest)
        ],
        "Type KEYS in Normal mode at each match in the selected lines, or everywhere",
        |a| {
            let (pattern, rest) = split(a);
            Ok(Command::EachMatch {
                pattern: regex::Regex::new(&required(pattern)?).map_err(|e| e.to_string())?,
                keys: keys(&required(rest)?)?,
            })
        }
    ),
    builtin!(
        "jump-to",
        "Type two characters, then the label of where on screen to go",
        Command::JumpTo
    ),
    builtin!(
        "window-pick",
        "Focus a window by its label; with two windows, the other one",
        Command::WindowPick
    ),
    builtin!(
        "messages",
        "Show recent messages, including every configuration error",
        Command::Messages
    ),
    builtin!(
        "stop",
        "Stop the running run, shell command and search",
        Command::Stop
    ),
    builtin!(
        "lua",
        [slot("CODE", SlotKind::Rest)],
        "Run Lua code, with the soda table for the editor",
        |a| Ok(Command::Lua(required(a)?))
    ),
    builtin!(
        "choose",
        [slot("ITEM", SlotKind::Item)],
        "Answer the question a Lua extension asked",
        |a| {
            let index = required(a)?;
            let index = index
                .trim()
                .parse()
                .map_err(|_| format!("not one of the items: {index}"))?;
            Ok(Command::Choose(index))
        }
    ),
    builtin!(
        "lua-call",
        [
            slot("ID", SlotKind::Word),
            Slot {
                required: false,
                ..slot("ARGUMENT", SlotKind::Rest)
            }
        ],
        "Call the Lua function a hook or command registered under ID",
        |a| {
            let (id, argument) = split(a);
            let id = id
                .parse()
                .map_err(|_| format!("not a Lua function id: {id}"))?;
            Ok(Command::LuaCall {
                id,
                argument: argument.to_owned(),
            })
        }
    ),
    builtin!(
        "suspend",
        "Return to the shell; resume the editor with fg",
        Command::Suspend
    ),
    builtin!(
        "display",
        [
            slot("KIND", SlotKind::Word),
            slot("PLACEMENT", SlotKind::Rest)
        ],
        "Show documents of a kind (file, grep) in the same, other, auto, bottom [ROWS] or right [COLUMNS] window",
        |a| {
            let (kind, placement) = a
                .split_once(' ')
                .ok_or("display needs KIND and PLACEMENT")?;
            Ok(Command::Display {
                kind: kind.to_owned(),
                placement: crate::application::Placement::parse(placement)?,
            })
        }
    ),
    builtin!(
        "pipe",
        [slot("SHELL-COMMAND", SlotKind::Rest)],
        "Replace the selection or document with command output",
        |a| Ok(if a.is_empty() {
            interactive("pipe")
        } else {
            Command::Pipe(a.into())
        })
    ),
    builtin!(
        "shell",
        [slot("SHELL-COMMAND", SlotKind::Rest)],
        "Run a shell command and show its status",
        |a| Ok(if a.is_empty() {
            interactive("shell")
        } else {
            Command::Shell(a.into())
        })
    ),
    builtin!("nop", "Do nothing; hides a default binding", Command::Nop),
];

enum Entry {
    Native(CommandHandler),
    User(String),
}
/// A command name with its signature and documentation, for help and the
/// command line.
#[derive(Clone)]
pub struct CommandInfo {
    pub name: String,
    pub aliases: &'static [&'static str],
    pub slots: &'static [Slot],
    pub doc: String,
    builtin: Option<&'static Builtin>,
}
impl CommandInfo {
    pub fn synopsis(&self) -> String {
        synopsis(self.slots)
    }
    pub fn named(&self, name: &str) -> bool {
        self.name == name || self.aliases.contains(&name)
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
        .find(|info| info.named(name))
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
    BUILTINS
        .iter()
        .find(|b| b.name == name || b.aliases.contains(&name))
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
    pub fn register(
        &mut self,
        name: impl Into<String>,
        handler: CommandHandler,
    ) -> Result<(), String> {
        let name = name.into();
        if reserved(&name) || name.is_empty() || name.contains(char::is_whitespace) {
            return Err(format!("cannot define command {name:?}"));
        }
        self.entries.insert(name, Entry::Native(handler));
        Ok(())
    }
    pub fn define(&mut self, name: String, body: String) -> Result<(), String> {
        if reserved(&name) {
            return Err(format!("{name} is a built-in command"));
        }
        self.entries.insert(name, Entry::User(body));
        Ok(())
    }
    /// Parses a line naming only built-in commands; used for default tables.
    pub(super) fn parse_builtin(&self, line: &str) -> Result<Command, String> {
        let (name, args) = split(line.trim());
        if let Some((edit, extend)) = LineEdit::parse(name) {
            return bare(Command::Line { edit, extend })(args);
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
    /// `%val`, and registered handlers, stay named and run when reached.
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
            Some(Entry::User(body)) => {
                if depth == MAX_DEPTH {
                    return Err(format!(
                        "{name} recursively expands more than {MAX_DEPTH} levels"
                    ));
                }
                for statement in statements(&substitute(body, args)) {
                    self.expand_into(&statement, depth + 1, out)?;
                }
            }
            Some(Entry::Native(_)) if args.is_empty() => out.push(Command::Named(name.into())),
            Some(Entry::Native(_)) => return Err(format!("{name} takes no argument")),
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
    pub(super) fn handler(&self, name: &str) -> Option<CommandHandler> {
        match self.entries.get(name) {
            Some(Entry::Native(handler)) => Some(*handler),
            _ => None,
        }
    }
    /// Every command, built-ins first, then registered and user commands.
    pub fn commands(&self) -> Vec<CommandInfo> {
        let builtins = BUILTINS.iter().map(|b| CommandInfo {
            name: b.name.into(),
            aliases: b.aliases,
            slots: b.slots,
            doc: b.doc.into(),
            builtin: Some(b),
        });
        let edits = LINE_EDITS.iter().map(|(name, _, doc)| CommandInfo {
            name: (*name).into(),
            aliases: &[],
            slots: &[],
            doc: (*doc).into(),
            builtin: None,
        });
        let custom = self.entries.iter().map(|(name, entry)| match entry {
            Entry::Native(_) => CommandInfo {
                name: name.clone(),
                aliases: &[],
                slots: &[],
                doc: "Registered command".into(),
                builtin: None,
            },
            Entry::User(body) => CommandInfo {
                name: name.clone(),
                aliases: &[],
                slots: ARGUMENTS,
                doc: body.clone(),
                builtin: None,
            },
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
        match self.entries.get(name) {
            Some(Entry::User(body)) => body.clone(),
            Some(Entry::Native(_)) => "Registered command".into(),
            None => String::new(),
        }
    }
}
