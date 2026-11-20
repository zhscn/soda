use super::*;

pub(super) const COMMANDS: &[Builtin] = &[
    builtin!(
        "grep",
        [slot("PATTERN", SlotKind::Rest)],
        "Search project files for a regular expression; lowercase ignores case",
        |a| Ok(if a.is_empty() {
            interactive("grep")
        } else {
            Command::Results(ResultsCommand::Grep(a.into()))
        })
    ),
    builtin!(
        "jump",
        "Open the location on the caret line, as in search results",
        Command::Results(ResultsCommand::Jump)
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
        "next-result",
        "Open the next location in the latest search or run output",
        Command::Results(ResultsCommand::ResultStep { backward: false })
    ),
    builtin!(
        "previous-result",
        "Open the previous location in the latest search or run output",
        Command::Results(ResultsCommand::ResultStep { backward: true })
    ),
    builtin!(
        "run",
        [slot("SHELL-COMMAND", SlotKind::Rest)],
        "Run a command in the background; its output streams into *run*",
        |a| { Ok(Command::Results(ResultsCommand::Run(required(a)?))) }
    ),
    builtin!(
        "check-files",
        "Reload files changed on disk without unsaved edits; report the others",
        Command::File(FileCommand::CheckFiles)
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
        "language-map",
        [
            slot("NAME", SlotKind::Word),
            slot("LANGUAGE", SlotKind::Language)
        ],
        "Open files of this name, or extension such as .h, in LANGUAGE (an id, or text)",
        |a| {
            let (name, language) = split(a.trim());
            let language = required(language)?;
            if crate::language::catalog().by_id(&language).is_none() {
                return Err(format!("unknown language {language}"));
            }
            Ok(Command::Setup(SetupCommand::MapLanguage {
                name: name.into(),
                language,
            }))
        }
    ),
    builtin!(
        "theme",
        [slot("NAME", SlotKind::Theme)],
        "Switch to a theme: dark, light, auto, or one soda.theme defined",
        |a| option(&format!("theme {}", a.trim()), false)
    ),
    builtin!(
        "face",
        [
            slot("NAME", SlotKind::Face),
            Slot {
                name: "SPEC",
                kind: SlotKind::Rest,
                required: false,
            }
        ],
        "Set a face: fg:#rrggbb bg:#rrggbb bold italic underline dim reverse; without SPEC, the theme's",
        |a| {
            let (name, spec) = split(a.trim());
            let spec = match spec {
                "" => None,
                spec => Some(crate::application::faces::FaceSpec::parse(spec)?),
            };
            Ok(Command::Setup(SetupCommand::Face {
                name: name.into(),
                spec,
            }))
        }
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
        |a| Ok(Command::Setup(SetupCommand::Unhighlight(
            (!a.is_empty()).then(|| a.to_owned())
        )))
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
        |a| Ok(Command::Setup(SetupCommand::UnflagLines(
            (!a.is_empty()).then(|| a.to_owned())
        )))
    ),
    builtin!(
        "keypad",
        [slot("START", SlotKind::Word)],
        "Read keys through the keypad: leader, meta, ctrl-meta or a prefix key",
        |a| Ok(Command::Keypad(match required(a)?.as_str() {
            "leader" => KeypadStart::Leader,
            "meta" => KeypadStart::Modifier { control: false },
            "ctrl-meta" => KeypadStart::Modifier { control: true },
            prefix => match keys(prefix)?[..] {
                [key] => KeypadStart::Prefix(key),
                _ => return Err("keypad starts from one key".into()),
            },
        }))
    ),
    builtin!(
        "each-line",
        [slot("KEYS", SlotKind::Rest)],
        "Type KEYS in Normal mode at the start of each selected line",
        |a| Ok(Command::Macro(MacroCommand::EachLine(typed(&required(
            a
        )?)?)))
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
            Ok(Command::Macro(MacroCommand::EachMatch {
                pattern: regex::Regex::new(&required(pattern)?).map_err(|e| e.to_string())?,
                keys: typed(&required(rest)?)?,
            }))
        }
    ),
    builtin!(
        "jump-to",
        "Type two characters, then the label of where on screen to go",
        Command::Search(SearchCommand::JumpTo)
    ),
    builtin!(
        "flash",
        "Type to search the screen, then a match's label to go there; RET goes to the next match",
        Command::Search(SearchCommand::Flash)
    ),
    builtin!(
        "flash-structure",
        "Select a group around the caret by its label; ; and , go out and in",
        Command::Search(SearchCommand::FlashStructure)
    ),
    builtin!(
        "window-pick",
        "Focus a window by its label; with two windows, the other one",
        Command::Window(WindowCommand::WindowPick)
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
];
