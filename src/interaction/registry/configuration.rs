use super::*;

pub(super) const COMMANDS: &[Builtin] = &[
    builtin!(
        "map",
        [KEYMAP, KEYS, slot("COMMAND", SlotKind::Rest)],
        "Bind keys in a context, a document keymap or a language's keymap",
        |a| {
            let (keymap, rest) = split(a);
            let (sequence, target) = split_keys(rest);
            Ok(Command::Setup(SetupCommand::Map {
                keymap: required(keymap)?,
                keys: keys(sequence)?,
                target: required(target)?,
                label: None,
                default: false,
            }))
        }
    ),
    builtin!("unmap", [KEYMAP, KEYS], "Remove a user binding", |a| {
        let (keymap, rest) = split(a);
        let (sequence, _) = split_keys(rest);
        Ok(Command::Setup(SetupCommand::Unmap {
            keymap: required(keymap)?,
            keys: keys(&required(sequence)?)?,
        }))
    }),
    builtin!(
        "define-command",
        [slot("NAME", SlotKind::Word), slot("BODY", SlotKind::Rest)],
        "Define a command from ;-separated commands",
        |a| {
            let (name, body) = split(a);
            Ok(Command::Setup(SetupCommand::Define {
                name: required(name)?,
                body: required(body)?,
                doc: None,
                slots: None,
            }))
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
            crate::interaction::hooks::Hook::new(event, &filter, String::new())?;
            Ok(Command::Setup(SetupCommand::Hook {
                event,
                filter,
                command: required(command)?,
            }))
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
            Ok(Command::Setup(SetupCommand::Unhook {
                event: hook_event(event)?,
                filter: (!filter.is_empty()).then(|| filter.to_owned()),
            }))
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
            Ok(Command::Setup(SetupCommand::UnsetOption(info.name)))
        }
    ),
];
