//! Defines and replays keyboard macros.
use super::{Command, Layers, Response, commands::active};
use crate::interaction::SetupCommand;
use crate::{application::Application, editor::Command as EditCommand};

#[derive(Clone, Debug)]
pub enum MacroCommand {
    /// Replays keys in Normal mode from the start of each selected line,
    /// or of the caret's line.
    EachLine(Vec<super::UserInput>),
    /// Replays keys in Normal mode from each match of a pattern in the
    /// selected lines, or in the whole document.
    EachMatch {
        pattern: regex::Regex,
        keys: Vec<super::UserInput>,
    },
    /// Replays input in Normal mode from each of these offsets, last first,
    /// as one undo step.
    EachAt {
        targets: Vec<usize>,
        keys: Vec<super::UserInput>,
    },
    /// Routes input as if typed, for `each-line` and `each-match`.
    Replay(Vec<super::UserInput>),
    /// Names the last keyboard macro, making it a command.
    MacroName(String),
    /// Sets the format the macro counter is inserted in.
    MacroFormat(String),
    /// Plays a macro by its name.
    MacroCall(String),
}

impl Layers {
    pub(super) fn execute_macro(
        &mut self,
        command: MacroCommand,
        mut response: Response,
        app: &Application,
    ) -> Response {
        match command {
            MacroCommand::EachLine(_)
            | MacroCommand::EachMatch { .. }
            | MacroCommand::EachAt { .. } => {
                if let Some(view) = active(app) {
                    response.commands = self.each(app, view, command);
                }
            }
            MacroCommand::Replay(keys) => {
                response.replay = keys;
            }
            MacroCommand::MacroName(name) => {
                if let Err(message) = self.modal.replay.name(&name) {
                    response = response.modal_failure(message);
                } else {
                    response.commands.push(Command::Setup(SetupCommand::Define {
                        body: format!("macro-call {name}"),
                        name,
                        doc: Some("A keyboard macro".into()),
                        slots: None,
                    }));
                }
            }
            MacroCommand::MacroFormat(format) => {
                let replay = &mut self.modal.replay;
                replay.format = format;
                // Outside a macro it holds for those defined from now on.
                if !replay.recording() && !self.keys.command.executing {
                    replay.default_format = replay.format.clone();
                }
            }
            MacroCommand::MacroCall(name) => response = self.call_named(&name, response),
        }
        response
    }
}
impl Layers {
    /// The commands that replay keys at each target, bottom first so that
    /// edits leave the targets above in place, then merge the edits into one
    /// undo step.
    fn each(
        &self,
        app: &Application,
        view: &crate::application::View,
        command: MacroCommand,
    ) -> Vec<Command> {
        let editor = app.workspace().editor(view.document_id).unwrap();
        let document = editor.model().document();
        let snapshot = document.snapshot();
        let selection = editor.model().session(view.session_id).unwrap().selection();
        let range = Some(selection.range()).filter(|range| !range.is_empty());
        let lines = range.map(|range| {
            snapshot.line_of(range.start).unwrap()..=snapshot.line_of(range.end).unwrap()
        });
        let (targets, keys): (Vec<usize>, _) = match command {
            MacroCommand::EachLine(keys) => {
                let caret = snapshot.line_of(selection.head).unwrap();
                let lines = lines.unwrap_or(caret..=caret);
                (
                    lines
                        .map(|line| snapshot.line_start(line).unwrap())
                        .collect(),
                    keys,
                )
            }
            MacroCommand::EachMatch { pattern, keys } => {
                let lines = lines.unwrap_or(0..=snapshot.text_lines() - 1);
                let mut targets = vec![];
                for line in lines {
                    let start = snapshot.line_start(line).unwrap();
                    let text = snapshot.line(line).unwrap_or_default();
                    targets.extend(pattern.find_iter(&text).map(|m| start + m.start()));
                }
                (targets, keys)
            }
            MacroCommand::EachAt { targets, keys } => (targets, keys),
            _ => unreachable!(),
        };
        // The last 10,000, which go first.
        let skip = targets.len().saturating_sub(10_000);
        let carets = targets.into_iter().skip(skip);
        let carets = carets.map(crate::core::Selection::caret);
        replay_each(carets, None, &keys, document.history_depth())
    }
}

/// Replays keys in Normal at each selection, last first so that earlier
/// places hold, as one undoable step. With `kind`, each selection is of
/// that kind, so that keys which extend it extend it the same way.
pub(super) fn replay_each(
    selections: impl DoubleEndedIterator<Item = crate::core::Selection>,
    kind: Option<(super::modal::Kind, bool)>,
    keys: &[super::UserInput],
    depth: usize,
) -> Vec<Command> {
    let mut commands = vec![];
    for selection in selections.rev() {
        let select = match kind {
            Some((kind, expand)) => Command::Modal(super::modal::Action::Found {
                anchor: selection.anchor,
                head: selection.head,
                kind,
                expand,
            }),
            None => Command::Edit(EditCommand::SetSelection(selection)),
        };
        commands.extend([
            Command::SetMode(super::EditMode::Normal),
            select,
            Command::Macro(MacroCommand::Replay(keys.to_vec())),
        ]);
    }
    commands.extend([
        Command::SetMode(super::EditMode::Normal),
        Command::Edit(EditCommand::SquashHistory(depth)),
    ]);
    commands
}
