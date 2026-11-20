use super::*;

pub(super) const COMMANDS: &[Builtin] = &[
    builtin!("normal-mode", "Leave Insert", modal(Action::Leave)),
    builtin!(
        "left",
        "Move left, keeping a character selection",
        modal(step(Step::Left, false))
    ),
    builtin!(
        "right",
        "Move right, keeping a character selection",
        modal(step(Step::Right, false))
    ),
    builtin!(
        "up",
        "Move up, keeping a character selection",
        modal(step(Step::Up, false))
    ),
    builtin!(
        "down",
        "Move down, keeping a character selection",
        modal(step(Step::Down, false))
    ),
    builtin!(
        "left-expand",
        "Extend a character selection left",
        modal(step(Step::Left, true))
    ),
    builtin!(
        "right-expand",
        "Extend a character selection right",
        modal(step(Step::Right, true))
    ),
    builtin!(
        "up-expand",
        "Extend a character selection up",
        modal(step(Step::Up, true))
    ),
    builtin!(
        "down-expand",
        "Extend a character selection down",
        modal(step(Step::Down, true))
    ),
    builtin!(
        "next-word",
        "Select to the end of the next word",
        modal(thing(false, false))
    ),
    builtin!(
        "back-word",
        "Select to the start of the previous word",
        modal(thing(false, true))
    ),
    builtin!(
        "next-symbol",
        "Select to the end of the next symbol",
        modal(thing(true, false))
    ),
    builtin!(
        "back-symbol",
        "Select to the start of the previous symbol",
        modal(thing(true, true))
    ),
    builtin!(
        "mark-word",
        "Select the word here and search for it",
        modal(Action::Mark { symbol: false })
    ),
    builtin!(
        "mark-symbol",
        "Select the symbol here and search for it",
        modal(Action::Mark { symbol: true })
    ),
    builtin!(
        "select-line",
        "Select the line; again extends",
        modal(Action::Line)
    ),
    builtin!(
        "block",
        "Select the group around the selection; again takes its parent",
        modal(Action::Query(Query::Block))
    ),
    builtin!(
        "to-block",
        "Extend to the end of the next group",
        modal(Action::Query(Query::ToBlock))
    ),
    builtin!(
        "find",
        "Select through the next occurrence of a character",
        modal(Action::Find { till: false })
    ),
    builtin!(
        "till",
        "Select up to the next occurrence of a character",
        modal(Action::Find { till: true })
    ),
    builtin!(
        "inner-of-thing",
        "Select inside a thing: r s c brackets, g string, e w symbol word, p l b",
        modal(Action::ThingAt { inner: true })
    ),
    builtin!(
        "bounds-of-thing",
        "Select around a thing",
        modal(Action::ThingAt { inner: false })
    ),
    builtin!(
        "reverse",
        "Swap the ends of the selection",
        modal(Action::Reverse)
    ),
    builtin!("cancel", "Drop the selection", modal(Action::Cancel)),
    builtin!(
        "pop-selection",
        "Go back to the previous selection",
        modal(Action::PopSelection { all: false })
    ),
    builtin!(
        "pop-all-selection",
        "Go back to the first selection",
        modal(Action::PopSelection { all: true })
    ),
    builtin!(
        "negative-argument",
        "Reverse the next command",
        modal(Action::Negative)
    ),
    builtin!(
        "insert",
        "Insert at the start of the selection",
        modal(Action::Insert(InsertAt::Before))
    ),
    builtin!(
        "append",
        "Insert at the end of the selection",
        modal(Action::Insert(InsertAt::After))
    ),
    builtin!(
        "open-below",
        "Open a line below and insert",
        modal(Action::Insert(InsertAt::Below))
    ),
    builtin!(
        "open-above",
        "Open a line above and insert",
        modal(Action::Insert(InsertAt::Above))
    ),
    builtin!(
        "kill",
        "Cut the selection, or to the line end",
        modal(Action::Kill)
    ),
    builtin!(
        "change",
        "Delete the selection, or a character, and insert",
        modal(Action::Change)
    ),
    builtin!(
        "delete",
        "Delete the selection or a character, leaving the clipboard alone",
        modal(Action::Delete)
    ),
    builtin!(
        "backward-delete",
        "Delete the selection or the character before the caret",
        modal(Action::BackwardDelete)
    ),
    builtin!("save", "Copy the selection", modal(Action::Save)),
    builtin!(
        "kill-region",
        "Cut the selection; without one, say so",
        modal(Action::KillRegion)
    ),
    builtin!(
        "kill-ring-save",
        "Copy the selection; without one, say so",
        modal(Action::KillRingSave)
    ),
    builtin!(
        "put",
        "Paste at the caret, leaving the selection in place",
        modal(Action::Yank)
    ),
    builtin!(
        "join",
        "Select the blanks between this line and the one above",
        modal(Action::Join)
    ),
    builtin!(
        "search-next",
        "Select the next match of the search, or of the selection",
        modal(Action::Search)
    ),
    builtin!(
        "search-pop",
        "Forget the search for the one before it",
        modal(Action::PopSearch)
    ),
    builtin!(
        "set-mark",
        "Start a character selection at the caret",
        modal(Action::SetMark)
    ),
    builtin!(
        "grab",
        "Enter Beacon inside the selection, or leave a marker",
        modal(Action::Grab)
    ),
    builtin!(
        "swap-grab",
        "Swap the selection with what was grabbed",
        modal(Action::SwapGrab)
    ),
];
