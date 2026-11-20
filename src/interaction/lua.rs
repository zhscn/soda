//! Lua commands and the prompt state they share with the command line.
use super::{Command, InputResult, Layers, Message, Response, SlotKind, slots};
use crate::interaction::PromptCommand;
use crate::{application::Application, core::EditError};
use std::{path::Path, time::Duration};

#[derive(Clone, Debug)]
pub enum LuaCommand {
    /// Asks in the command line, as `completing-read` and `read-string`
    /// do; the Lua function under `id` gets the answer.
    Question {
        id: u64,
        title: String,
        asked: super::slots::Asked,
        /// The history the answer is recalled from and added to; a kind
        /// has its own otherwise.
        history: Option<String>,
    },
    /// Answers `Question` with an item, from one.
    Choose(usize),
    /// Answers `Question` with text.
    Answer(String),
    /// Runs Lua code.
    Chunk(String),
    /// Calls a Lua function registered under an id, with one argument.
    Call { id: u64, argument: String },
}

#[derive(Default)]
pub(super) struct LuaInteraction {
    /// The Lua function of the question last asked, with its items when
    /// it offers some.
    pub(super) question: Option<(u64, Vec<slots::Item>)>,
    /// What kind of answer the next question Lua asks completes, when it
    /// is one the command line knows.
    pub(super) asked_kind: Option<SlotKind>,
    /// The history named for the next question Lua asks.
    pub(super) asked_history: Option<String>,
    /// The parameter of the event whose hooks are running, `%val{hook}`.
    pub(super) hook: Option<String>,
}

impl Layers {
    pub(super) fn execute_lua(
        &mut self,
        command: LuaCommand,
        mut response: Response,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<InputResult, EditError> {
        match command {
            LuaCommand::Chunk(code) => response.lua.push(super::LuaRequest::Chunk {
                origin: "lua".into(),
                code,
            }),
            LuaCommand::Call { id, argument } => {
                response.lua.push(super::LuaRequest::Call { id, argument })
            }
            LuaCommand::Question {
                id,
                title,
                asked,
                history,
            } => {
                use slots::Asked;
                let (line, items, kind) = match asked {
                    Asked::Text(initial) => (format!("answer {initial}"), vec![], None),
                    Asked::Items(items) => ("choose ".to_owned(), items, None),
                    Asked::Kind(kind) => ("answer ".to_owned(), vec![], Some(kind)),
                    Asked::KindInitial(kind, initial) => {
                        (format!("answer {initial}"), vec![], Some(kind))
                    }
                };
                self.lua_interaction.question = Some((id, items));
                self.lua_interaction.asked_history = history.or_else(|| {
                    let kind = kind?;
                    slots::behavior(kind).history.map(str::to_owned)
                });
                self.lua_interaction.asked_kind = kind;
                let ask = Command::Prompt(PromptCommand::Ask { line, note: title });
                return self.execute(ask, app, time, file_root);
            }
            LuaCommand::Answer(text) => match self.lua_interaction.question.take() {
                Some((id, _)) => response.lua.push(super::LuaRequest::Answer {
                    id,
                    text,
                    index: None,
                }),
                None => response.message = Message::Set("Nothing to answer".into()),
            },
            LuaCommand::Choose(index) => match self.lua_interaction.question.take() {
                Some((id, items)) if (1..=items.len()).contains(&index) => {
                    let text = items[index - 1].text.clone();
                    let index = Some(index);
                    response
                        .lua
                        .push(super::LuaRequest::Answer { id, text, index });
                }
                _ => response.message = Message::Set("Nothing to choose".into()),
            },
        }
        Ok(InputResult::Handled(response))
    }
}
