//! Static dispatch for built-in sessions. Feature reducers own interaction
//! behavior; the layer manager owns installation, removal and geometry.
use super::{
    CommandLine, HelpSession, Input, Presentation, Response, SaveWait, SearchSession,
    labels::LabelSession, session::Transition,
};
use crate::{
    application::{Application, Update},
    core::EditError,
};
use std::time::Duration;

pub enum Layer {
    CommandLine(Box<CommandLine>),
    Saving(SaveWait),
    Help(HelpSession),
    /// Search, or search and replace.
    Search(Box<SearchSession>),
    Labels(LabelSession),
    Resize(super::resize::ResizeSession),
}
impl Layer {
    pub(super) fn handle(
        &mut self,
        input: Input,
        app: &Application,
        time: Duration,
    ) -> Result<Transition, EditError> {
        Ok(match self {
            Self::CommandLine(session) => session.handle(input, app),
            Self::Saving(wait) => wait.handle(input),
            Self::Help(session) => session.handle(input),
            Self::Labels(session) => session.handle(input, app, time),
            // Keys reach it unconverted, through `Layers::route`.
            Self::Resize(_) => Transition::Blocked,
            Self::Search(session) => session.handle(input, app, time)?,
        })
    }
    pub(super) fn observe(
        &mut self,
        app: &Application,
        update: &Update,
        time: Duration,
    ) -> Result<Transition, EditError> {
        Ok(match self {
            Self::CommandLine(session) => session.observe(app),
            Self::Saving(wait) => wait.observe(app, update),
            Self::Search(session) => session.follow(app, update, time)?,
            Self::Help(_) => Transition::Active(Response::default()),
            Self::Labels(session) => session.observe(update),
            Self::Resize(session) => session.observe(app, update),
        })
    }
    /// Whether the layer is a command line asking a question.
    pub(super) fn asks(&self) -> bool {
        matches!(self, Self::CommandLine(session) if session.asking())
    }
    /// The history a prompt uses and its text, for prompts that have one.
    pub(super) fn history(&self) -> Option<(usize, &str)> {
        match self {
            Self::CommandLine(session) if !session.asking() => {
                Some((super::history::COMMAND, session.text()))
            }
            Self::Search(session) if !session.is_replacing() => {
                Some((super::history::SEARCH, session.input().text()))
            }
            _ => None,
        }
    }
    /// Replaces the prompt's text with a recalled line.
    pub(super) fn recall(
        &mut self,
        text: &str,
        app: &Application,
        time: Duration,
    ) -> Result<Transition, EditError> {
        Ok(match self {
            Self::CommandLine(session) => session.recall(text, app),
            Self::Search(session) => session.recall(text, app, time)?,
            _ => Transition::Blocked,
        })
    }
    pub(super) fn resize(&mut self, help_rows: usize, picker_rows: usize) {
        match self {
            Self::Help(session) => session.resize(help_rows),
            Self::CommandLine(session) => session.resize(picker_rows),
            _ => {}
        }
    }
    pub fn presentation(&self) -> Presentation {
        match self {
            Self::CommandLine(session) => session.presentation(),
            Self::Saving(wait) => wait.presentation(),
            Self::Help(session) => session.presentation(),
            Self::Search(session) => session.presentation(),
            Self::Labels(session) => session.presentation(),
            Self::Resize(session) => session.presentation(),
        }
    }
}
