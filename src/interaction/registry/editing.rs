use super::*;
use crate::interaction::InsertCommand;

pub(super) const COMMANDS: &[Builtin] = &[
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
        "commands",
        "Open the command line to choose a command",
        Command::Prompt(PromptCommand::Ex(String::new()))
    ),
    builtin!("undo", "Undo", modal(Action::Undo { redo: false })),
    builtin!("redo", "Redo", modal(Action::Undo { redo: true })),
    builtin!(
        "completion-trigger",
        "List candidates for the word at the caret",
        Command::Insert(InsertCommand::Completion(
            crate::interaction::completion::Action::Trigger
        ))
    ),
    builtin!(
        "completion-dismiss",
        "Close the completion list",
        Command::Insert(InsertCommand::Completion(
            crate::interaction::completion::Action::Dismiss
        ))
    ),
    builtin!(
        "completion-next",
        "Select the next candidate",
        Command::Insert(InsertCommand::Completion(
            crate::interaction::completion::Action::Move { backward: false }
        ))
    ),
    builtin!(
        "completion-previous",
        "Select the previous candidate",
        Command::Insert(InsertCommand::Completion(
            crate::interaction::completion::Action::Move { backward: true }
        ))
    ),
    builtin!(
        "tree-toggle",
        "Open or close the node of a tree on the caret's line",
        Command::Effect(Box::new(crate::interaction::modal::Effect::Tree(
            crate::interaction::modal::TreeAction::Toggle
        )))
    ),
    builtin!(
        "tree-open",
        "Go to what the node of a tree on the caret's line stands for",
        Command::Effect(Box::new(crate::interaction::modal::Effect::Tree(
            crate::interaction::modal::TreeAction::Open
        )))
    ),
    builtin!(
        "tree-collapse",
        "Close the node of a tree on the caret's line, or go to its parent",
        Command::Effect(Box::new(crate::interaction::modal::Effect::Tree(
            crate::interaction::modal::TreeAction::Collapse
        )))
    ),
    builtin!(
        "completion-accept",
        "Take the selected candidate, keeping the text after the caret",
        Command::Insert(InsertCommand::Completion(
            crate::interaction::completion::Action::Accept
        ))
    ),
    builtin!(
        "completion-replace",
        "Take the selected or first candidate, replacing to the end of the word",
        Command::Insert(InsertCommand::Completion(
            crate::interaction::completion::Action::Replace
        ))
    ),
    builtin!(
        "snippet",
        [slot("BODY", SlotKind::Rest)],
        "Insert a snippet at the caret; $1, ${1:text} and $0 are its places",
        |a| Ok(Command::Insert(InsertCommand::Snippet(required(a)?)))
    ),
    builtin!(
        "snippet-next",
        "Go to the next place of the snippet",
        Command::Insert(InsertCommand::SnippetStep { backward: false })
    ),
    builtin!(
        "snippet-previous",
        "Go to the previous place of the snippet",
        Command::Insert(InsertCommand::SnippetStep { backward: true })
    ),
    builtin!(
        "recenter",
        "Scroll the caret's line to the middle; again, to the top, then the bottom",
        modal(Action::Recenter)
    ),
    builtin!(
        "half-page-down",
        "Move down half a page and scroll with it",
        modal(Action::HalfPage { down: true })
    ),
    builtin!(
        "half-page-up",
        "Move up half a page and scroll with it",
        modal(Action::HalfPage { down: false })
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
        "yank-pop",
        "Replace the text just yanked with the older killed text",
        Command::Clipboard(ClipboardAction::YankPop)
    ),
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
        "indent-for-tab",
        "Indent the line, or the selected lines, as the language would; else insert indentation",
        Command::Edit(Edit::IndentForTab)
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
];
