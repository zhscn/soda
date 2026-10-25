//! Named commands shared by key bindings, the command line, configuration and
//! the command palette. Built-in names are fixed; registered Rust handlers and
//! user definitions share one replaceable namespace.
use super::{
    Command, EditMode,
    keymap::{Context, LINE_EDITS, LineEdit, PROMPT_ACTIONS},
    vim::{Insert, VimCommand},
};
use crate::{
    application::{Application, ClipboardAction},
    core::EditError,
    editor::{Command as Edit, Motion},
};
use std::collections::BTreeMap;

pub type CommandHandler = fn(&Application) -> Result<Command, EditError>;
const MAX_DEPTH: usize = 16;

pub struct Builtin {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    /// Argument synopsis; empty when the command takes no argument.
    pub args: &'static str,
    pub doc: &'static str,
    build: fn(&str) -> Result<Command, String>,
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
fn required(args: &str) -> Result<String, String> {
    if args.is_empty() {
        Err("command requires an argument".into())
    } else {
        Ok(args.to_owned())
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
    ($name:literal $(| $alias:literal)*, $args:literal, $doc:literal, $build:expr) => {
        Builtin {
            name: $name,
            aliases: &[$($alias),*],
            args: $args,
            doc: $doc,
            build: $build,
        }
    };
    ($name:literal $(| $alias:literal)*, $doc:literal, $command:expr) => {
        builtin!($name $(| $alias)*, "", $doc, |args| bare($command)(args))
    };
}
pub static BUILTINS: &[Builtin] = &[
    builtin!(
        "edit" | "e",
        "[PATH]",
        "Open a file; reload the current file without PATH",
        |a| { Ok(path_or(a, Command::OpenPath, Command::Reload)) }
    ),
    builtin!("open", "Open a path with completion", Command::Open),
    builtin!(
        "write" | "w",
        "[PATH]",
        "Save; save to PATH when given",
        |a| {
            Ok(path_or(
                a,
                Command::SavePath,
                Command::Save { choose_path: false },
            ))
        }
    ),
    builtin!("saveas", "[PATH]", "Save to PATH, or choose a path", |a| {
        Ok(path_or(
            a,
            Command::SavePath,
            Command::Save { choose_path: true },
        ))
    }),
    builtin!(
        "quit" | "q",
        "Quit, confirming unsaved documents",
        Command::Quit
    ),
    builtin!(
        "write-quit" | "wq" | "x",
        "Save the current document and quit",
        Command::WriteQuit
    ),
    builtin!(
        "close" | "bd" | "bdelete",
        "Close the current document",
        Command::Close
    ),
    builtin!(
        "buffers" | "b" | "buffer" | "ls" | "files",
        "Choose an open document",
        Command::SwitchBuffer
    ),
    builtin!(
        "next-view" | "bn" | "bnext",
        "Focus the next view",
        Command::NextView
    ),
    builtin!("new" | "enew", "Create an untitled document", Command::New),
    builtin!("project", "Pick a project file", Command::PickFiles),
    builtin!("search", "Search the document", Command::Search),
    builtin!("replace", "Search and replace", Command::Replace),
    builtin!("goto", "Go to line[:column]", Command::Goto),
    builtin!("help", "Show key bindings and commands", Command::Help),
    builtin!("commands", "Choose a command to run", Command::Palette),
    builtin!(
        "command-line",
        "Open the : command line",
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
        "MODE KEYS COMMAND",
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
    builtin!("unmap", "MODE KEYS", "Remove a user binding", |a| {
        let (mode, sequence) = split(a);
        Ok(Command::Unmap {
            context: context(mode)?,
            keys: keys(&required(sequence)?)?,
        })
    }),
    builtin!(
        "define-command",
        "NAME BODY",
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
        "pipe",
        "SHELL-COMMAND",
        "Replace the selection or document with command output",
        |a| { Ok(Command::Pipe(required(a)?)) }
    ),
    builtin!(
        "shell",
        "SHELL-COMMAND",
        "Run a shell command and show its status",
        |a| { Ok(Command::Shell(required(a)?)) }
    ),
    builtin!("nop", "Do nothing; hides a default binding", Command::Nop),
];

enum Entry {
    Native(CommandHandler),
    User(String),
}
/// A command name with its documentation, for help and the palette.
pub struct CommandInfo {
    pub name: String,
    pub args: &'static str,
    pub doc: String,
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
    /// definitions expand eagerly so that errors stop the line before any
    /// part runs; registered handlers stay named and run when reached.
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
            args: b.args,
            doc: b.doc.into(),
        });
        let edits = LINE_EDITS.iter().map(|(name, _, doc)| CommandInfo {
            name: (*name).into(),
            args: "",
            doc: (*doc).into(),
        });
        let custom = self.entries.iter().map(|(name, entry)| CommandInfo {
            name: name.clone(),
            args: "",
            doc: match entry {
                Entry::Native(_) => "Registered command".into(),
                Entry::User(body) => body.clone(),
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
