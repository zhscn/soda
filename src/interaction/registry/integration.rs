use super::*;

pub(super) const COMMANDS: &[Builtin] = &[
    builtin!(
        "lua",
        [slot("CODE", SlotKind::Rest)],
        "Run Lua code, with the soda table for the editor",
        |a| Ok(Command::Lua(LuaCommand::Chunk(required(a)?)))
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
            Ok(Command::Lua(LuaCommand::Choose(index)))
        }
    ),
    builtin!(
        "answer",
        [Slot {
            required: false,
            ..slot("TEXT", SlotKind::Rest)
        }],
        "Answer the line of text a Lua extension asked for",
        |a| Ok(Command::Lua(LuaCommand::Answer(a.to_owned())))
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
            Ok(Command::Lua(LuaCommand::Call {
                id,
                argument: argument.to_owned(),
            }))
        }
    ),
    builtin!(
        "restart",
        "Start soda again, keeping the documents, windows and unsaved text",
        Command::Restart
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
            Ok(Command::Setup(SetupCommand::Display {
                kind: kind.to_owned(),
                placement: crate::application::Placement::parse(placement)?,
            }))
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
