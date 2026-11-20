use super::*;

pub(super) const COMMANDS: &[Builtin] = &[
    builtin!(
        "edit",
        [OPTIONAL_PATH],
        "Open a file; reload the current file without PATH",
        |a| {
            Ok(path_or(
                a,
                |value| Command::File(FileCommand::OpenPath(value)),
                Command::File(FileCommand::Reload(None)),
            ))
        }
    ),
    builtin!(
        "reload",
        [DEPARTURE[0], DEPARTURE[1]],
        "Reload the current file from disk",
        |a| departure(a).map(|value| Command::File(FileCommand::Reload(value)))
    ),
    builtin!(
        "open",
        [PATH],
        "Open a file; a new file is created when saved",
        |a| {
            Ok(path_or(
                a,
                |value| Command::File(FileCommand::OpenPath(value)),
                Command::File(FileCommand::OpenPrompt),
            ))
        }
    ),
    builtin!(
        "recent",
        [slot("FILE", SlotKind::Recent)],
        "Open a recently used file",
        |a| {
            Ok(path_or(
                a,
                |value| Command::File(FileCommand::OpenProjectFile(value)),
                interactive("recent"),
            ))
        }
    ),
    builtin!(
        "write",
        [OPTIONAL_PATH],
        "Save; save to PATH when given",
        |a| {
            Ok(path_or(
                a,
                |value| Command::File(FileCommand::SavePath(value)),
                Command::File(FileCommand::Save { choose_path: false }),
            ))
        }
    ),
    builtin!("saveas", [PATH], "Save to another path", |a| {
        Ok(path_or(
            a,
            |value| Command::File(FileCommand::SavePath(value)),
            Command::File(FileCommand::Save { choose_path: true }),
        ))
    }),
    builtin!(
        "quit",
        [DEPARTURE[0], DEPARTURE[1]],
        "Quit, deciding for each unsaved document",
        |a| departure(a).map(|value| Command::File(FileCommand::Quit(value)))
    ),
    builtin!(
        "write-quit",
        "Save the current document and quit",
        Command::File(FileCommand::WriteQuit)
    ),
    builtin!(
        "close",
        [DEPARTURE[0], DEPARTURE[1]],
        "Close the current document",
        |a| departure(a).map(|value| Command::File(FileCommand::Close(value)))
    ),
    builtin!(
        "buffer",
        [slot("NAME", SlotKind::Buffer)],
        "Switch to an open document",
        |a| Ok(if a.is_empty() {
            interactive("buffer")
        } else {
            Command::File(FileCommand::Buffer(a.into()))
        })
    ),
    builtin!(
        "kill-buffer",
        [slot("NAME", SlotKind::CurrentBuffer)],
        "Close an open document, the current one unless another is chosen",
        |a| Ok(if a.is_empty() {
            interactive("kill-buffer")
        } else {
            Command::File(FileCommand::KillBuffer(a.into()))
        })
    ),
    builtin!(
        "next-view",
        "Focus the next view",
        Command::Window(WindowCommand::NextView)
    ),
    builtin!(
        "save-some-buffers",
        [SAVE_ANSWER],
        "Ask about each unsaved file whether to save it",
        |a| {
            use crate::interaction::SaveAnswer;
            Ok(Command::File(FileCommand::SaveSome(match a.trim() {
                "" => None,
                "yes" => Some(SaveAnswer::Yes),
                "no" => Some(SaveAnswer::No),
                "all" => Some(SaveAnswer::All),
                "quit" => Some(SaveAnswer::Quit),
                other => return Err(format!("expected yes, no, all or quit, not {other}")),
            })))
        }
    ),
    builtin!(
        "previous-buffer",
        "Show the buffer used before this one; again, the one before that",
        Command::File(FileCommand::CycleBuffer { backward: true })
    ),
    builtin!(
        "next-buffer",
        "Show the buffer used least recently; after previous-buffer, go back",
        Command::File(FileCommand::CycleBuffer { backward: false })
    ),
    builtin!(
        "search-symbol",
        "Search for the symbol at the caret, from its start",
        Command::Search(SearchCommand::SearchSymbol)
    ),
    builtin!(
        "new",
        "Create an untitled document",
        Command::File(FileCommand::New)
    ),
    builtin!(
        "text-scale-increase",
        "Make the text of every window a step larger, in the graphical frontend",
        Command::TextScale(Some(1))
    ),
    builtin!(
        "text-scale-decrease",
        "Make the text of every window a step smaller, in the graphical frontend",
        Command::TextScale(Some(-1))
    ),
    builtin!(
        "text-scale-reset",
        "Give the text the size font-size sets again",
        Command::TextScale(None)
    ),
    builtin!(
        "split",
        [OPTIONAL_PATH],
        "Split the window into two above each other; open PATH in the new one",
        |a| Ok(window_split(a, Axis::Rows))
    ),
    builtin!(
        "vsplit",
        [OPTIONAL_PATH],
        "Split the window into two side by side; open PATH in the new one",
        |a| Ok(window_split(a, Axis::Columns))
    ),
    builtin!(
        "close-window",
        "Close the window; its document stays open",
        Command::Window(WindowCommand::Close)
    ),
    builtin!(
        "close-tab",
        "Take the document out of the window's tabs and show the tab beside it; it stays open",
        Command::Window(WindowCommand::CloseTab)
    ),
    builtin!(
        "only",
        "Close every other window",
        Command::Window(WindowCommand::Only)
    ),
    builtin!(
        "resize-window",
        [HOW, CELLS],
        "Resize the window by CELLS (1), or step by step: w n t s r, Ctrl doubles, Esc quits",
        window_resize
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
        |a| {
            Ok(Command::File(FileCommand::ProjectRoot(
                (!a.is_empty()).then(|| a.into()),
            )))
        }
    ),
    builtin!(
        "project",
        [slot("FILE", SlotKind::File)],
        "Open a project file; outside a project, choose a project first",
        |a| {
            Ok(path_or(
                a,
                |value| Command::File(FileCommand::OpenProjectFile(value)),
                Command::File(FileCommand::FindProjectFile),
            ))
        }
    ),
    builtin!(
        "project-switch",
        [slot("DIR", SlotKind::Project)],
        "Open a file of a remembered project, or of any directory",
        |a| {
            Ok(path_or(
                a,
                |value| Command::File(FileCommand::SwitchProject(value)),
                interactive("project-switch"),
            ))
        }
    ),
    builtin!(
        "search",
        "Search the document",
        Command::Search(SearchCommand::Search)
    ),
    builtin!(
        "visit",
        [slot("SYMBOL", SlotKind::Symbol)],
        "Select the next place of a symbol of the document, or of any text",
        |a| Ok(if a.is_empty() {
            interactive("visit")
        } else {
            Command::Search(SearchCommand::Visit(a.into()))
        })
    ),
    builtin!(
        "search-backward",
        "Search the document backward",
        Command::Search(SearchCommand::SearchBackward)
    ),
    builtin!(
        "replace",
        "Search and replace",
        Command::Search(SearchCommand::Replace)
    ),
    builtin!(
        "project-replace",
        "Search and replace in every file of the project, asking at each match",
        Command::Search(SearchCommand::ProjectReplace)
    ),
];
