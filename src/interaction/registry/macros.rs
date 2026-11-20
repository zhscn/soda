use super::*;

pub(super) const COMMANDS: &[Builtin] = &[
    builtin!(
        "macro-start",
        "Start recording keys; while recording or playing, insert the macro counter",
        macro_action(MacroAction::StartOrCounter)
    ),
    builtin!(
        "macro-record",
        "Start recording keys",
        macro_action(MacroAction::Start)
    ),
    builtin!(
        "macro-end",
        "End recording, or play the last macro",
        macro_action(MacroAction::EndOrCall)
    ),
    builtin!(
        "macro-end-repeat",
        "End recording, or play the last macro; its last key alone repeats",
        macro_action(MacroAction::EndOrCallRepeat)
    ),
    builtin!(
        "macro-stop",
        "End recording; with a count, play the macro that many times in all",
        macro_action(MacroAction::End)
    ),
    builtin!(
        "macro-end-and-call",
        "End recording and play the macro, or play the last macro",
        macro_action(MacroAction::EndAndCall)
    ),
    builtin!(
        "macro-call-second",
        "Play the second macro of the ring",
        macro_action(MacroAction::CallSecond)
    ),
    builtin!(
        "macro-ring-next",
        "Make the next macro of the ring the last one",
        macro_action(MacroAction::RingNext)
    ),
    builtin!(
        "macro-ring-previous",
        "Make the previous macro of the ring the last one",
        macro_action(MacroAction::RingPrevious)
    ),
    builtin!(
        "macro-ring-swap",
        "Swap the first two macros of the ring",
        macro_action(MacroAction::RingSwap)
    ),
    builtin!(
        "macro-ring-delete",
        "Delete the last macro; the next one of the ring takes its place",
        macro_action(MacroAction::RingDelete)
    ),
    builtin!(
        "macro-view",
        "Show the last macro",
        macro_action(MacroAction::View)
    ),
    builtin!(
        "macro-insert-counter",
        "Insert the macro counter and add the count to it",
        macro_action(MacroAction::InsertCounter)
    ),
    builtin!(
        "macro-set-counter",
        [Slot {
            required: false,
            ..slot("N", SlotKind::Word)
        }],
        "Set the macro counter",
        |a| counter(a).map(|n| macro_action(MacroAction::SetCounter(n)))
    ),
    builtin!(
        "macro-add-counter",
        [Slot {
            required: false,
            ..slot("N", SlotKind::Word)
        }],
        "Add to the macro counter",
        |a| counter(a).map(|n| macro_action(MacroAction::AddCounter(n)))
    ),
    builtin!(
        "macro-set-format",
        [Slot {
            required: false,
            ..slot("FORMAT", SlotKind::Rest)
        }],
        "Set the format the macro counter is inserted in, as %03d",
        |a| Ok(match a.trim() {
            "" => Command::Prompt(PromptCommand::Ask {
                line: "macro-set-format ".into(),
                note: "macro counter format".into(),
            }),
            format => Command::Macro(MacroCommand::MacroFormat(format.to_owned())),
        })
    ),
    builtin!(
        "macro-name",
        [Slot {
            required: false,
            ..slot("NAME", SlotKind::Word)
        }],
        "Name the last macro, making it a command",
        |a| Ok(match a.trim() {
            "" => Command::Prompt(PromptCommand::Ask {
                line: "macro-name ".into(),
                note: "name for last kbd macro".into(),
            }),
            name => Command::Macro(MacroCommand::MacroName(name.to_owned())),
        })
    ),
    builtin!(
        "macro-call",
        [slot("NAME", SlotKind::Word)],
        "Play the macro macro-name gave NAME",
        |a| Ok(Command::Macro(MacroCommand::MacroCall(
            required(a.trim())?.to_owned()
        )))
    ),
    builtin!(
        "macro-lines",
        "Play the last macro on each selected line",
        modal(Action::MacroLines)
    ),
    builtin!(
        "macro-matches",
        "Play the last macro on each match of the search",
        modal(Action::MacroMatches)
    ),
    builtin!(
        "repeat",
        "Run the last command again",
        modal(Action::Repeat)
    ),
    builtin!(
        "expand",
        [slot("N", SlotKind::Word)],
        "Extend to the Nth target or the last available one (0 means 10). With no selection, enter a count",
        |a| Ok(Command::Modal(Action::Expand(digit(a)?)))
    ),
    builtin!(
        "universal-argument",
        "Begin a count of 4, or multiply it by 4; digits and - typed next make the count",
        modal(Action::Universal)
    ),
    builtin!(
        "digit-argument",
        [slot("N", SlotKind::Word)],
        "Start or extend a count for the next command",
        |a| Ok(Command::Modal(Action::Digit(digit(a)?)))
    ),
];
