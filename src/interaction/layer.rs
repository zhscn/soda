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
    /// Whether `M-p` and `M-n` walk a history here.
    pub(super) fn has_history(&self) -> bool {
        match self {
            Self::CommandLine(session) => session.has_history(),
            Self::Search(session) => !session.is_replacing(),
            _ => false,
        }
    }
    /// Whether the prompt is a search, which has no candidates, so Up and
    /// Down walk its history too.
    pub(super) fn searches(&self) -> bool {
        matches!(self, Self::Search(session) if !session.is_replacing())
    }
    /// Puts an older or newer entry of the field's history in the field;
    /// None when there is none that way.
    pub(super) fn recall(
        &mut self,
        histories: &super::history::Histories,
        backward: bool,
        app: &Application,
        time: Duration,
    ) -> Result<Option<Transition>, EditError> {
        Ok(match self {
            Self::CommandLine(session) => session.recall(histories, backward, app),
            Self::Search(session) => session.recall(histories, backward, app, time)?,
            _ => None,
        })
    }
    /// What a prompt that took its input adds to the histories, by name.
    pub(super) fn records(&mut self) -> Vec<(String, String)> {
        match self {
            Self::CommandLine(session) => session.take_records(),
            Self::Search(session) if !session.is_replacing() => vec![(
                super::history::SEARCH.to_owned(),
                session.input().text().to_owned(),
            )],
            _ => vec![],
        }
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
