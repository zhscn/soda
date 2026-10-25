//! Static dispatch for built-in sessions. Feature reducers own interaction
//! behavior; the layer manager owns installation, removal and geometry.
use super::{
    CommandLine, HelpSession, Input, Presentation, ReplaceSession, Response, SaveWait,
    SearchSession, TextInput, session::Transition,
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
    Replace(ReplaceSession),
    Search {
        input: TextInput,
        session: SearchSession,
    },
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
            Self::Replace(session) => session.handle(input, app, time)?,
            Self::Search {
                input: field,
                session,
            } => session.handle(field, input, app, time)?,
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
            Self::Replace(session) => session.observe(app, update, time)?,
            Self::Search { session, .. } => session.observe_transition(app, update, time)?,
            Self::Help(_) => Transition::active(Response::default()),
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
            Self::Replace(session) => session.presentation(),
            Self::Search { input, session } => session.presentation(input),
        }
    }
}
