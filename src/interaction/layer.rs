//! Static dispatch for built-in sessions. Feature reducers own interaction
//! behavior; the layer manager owns installation, removal and geometry.
use super::{
    BufferSession, ExitSession, GotoSession, HelpSession, Input, Presentation, ReplaceSession,
    Response, SearchSession, TextInput,
    path::PathInput,
    picker::PickerSession,
    prompt::{self, PathTarget},
    session::Transition,
};
use crate::{
    application::{Application, Update},
    core::EditError,
    editor::DocumentId,
};
use std::time::Duration;

pub enum Layer {
    Goto(GotoSession),
    Ex(super::ExSession),
    Buffer(BufferSession),
    Palette(super::PaletteSession),
    Open(PathInput),
    Save(DocumentId, PathInput),
    Exit(ExitSession),
    Help(HelpSession),
    Replace(ReplaceSession),
    Picker(PickerSession),
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
            Self::Goto(session) => session.handle(input, app, time),
            Self::Ex(session) => session.handle(input),
            Self::Buffer(session) => session.handle(input, app),
            Self::Palette(session) => session.handle(input),
            Self::Open(field) => prompt::path_input(PathTarget::Open, field, input),
            Self::Save(document, field) => {
                prompt::path_input(PathTarget::Save(*document), field, input)
            }
            Self::Exit(session) => session.handle(input, app),
            Self::Help(session) => session.handle(input),
            Self::Replace(session) => session.handle(input, app, time)?,
            Self::Picker(session) => session.handle(input),
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
            Self::Goto(session) => session.observe(app),
            Self::Buffer(session) => session.observe(app),
            Self::Open(_) => prompt::path_observe(PathTarget::Open, app),
            Self::Save(document, _) => prompt::path_observe(PathTarget::Save(*document), app),
            Self::Exit(session) => session.observe(app, update),
            Self::Replace(session) => session.observe(app, update, time)?,
            Self::Search { session, .. } => session.observe_transition(app, update, time)?,
            _ => Transition::active(Response::default()),
        })
    }
    pub(super) fn resize(&mut self, help_rows: usize, picker_rows: usize) {
        match self {
            Self::Help(session) => session.resize(help_rows),
            Self::Buffer(session) => session.resize(picker_rows),
            Self::Palette(session) => session.resize(picker_rows),
            Self::Picker(session) => {
                session.resize(picker_rows);
            }
            Self::Open(field) | Self::Save(_, field) => field.resize(picker_rows),
            Self::Exit(session) => session.resize(picker_rows),
            _ => {}
        }
    }
    pub fn presentation(&self) -> Presentation {
        match self {
            Self::Goto(session) => session.presentation(),
            Self::Ex(session) => session.presentation(),
            Self::Buffer(session) => session.presentation(),
            Self::Palette(session) => session.presentation(),
            Self::Open(field) => prompt::path_presentation(PathTarget::Open, field),
            Self::Save(document, field) => {
                prompt::path_presentation(PathTarget::Save(*document), field)
            }
            Self::Exit(session) => session.presentation(),
            Self::Help(session) => session.presentation(),
            Self::Replace(session) => session.presentation(),
            Self::Picker(session) => session.presentation(),
            Self::Search { input, session } => session.presentation(input),
        }
    }
}
