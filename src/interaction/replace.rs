//! Search-backed replacement dialog. Query preview and cancellation reuse the
//! search session; replacement edits run only after explicit confirmation.
use super::{Presentation, SearchSession, TextInput};
use crate::{
    application::{Application, ViewId},
    core::EditError,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ReplacePhase {
    Query,
    Replacement,
    Review,
}

pub struct ReplaceSession {
    pub(super) search: SearchSession,
    pub(super) input: TextInput,
    pub(super) phase: ReplacePhase,
    pub(super) replacement: String,
}
impl ReplaceSession {
    pub fn new(app: &Application, view: ViewId) -> Result<Self, EditError> {
        Ok(Self {
            search: SearchSession::new(app, view)?,
            input: TextInput::default(),
            phase: ReplacePhase::Query,
            replacement: String::new(),
        })
    }
    pub fn input(&self) -> &TextInput {
        &self.input
    }
    pub fn search(&self) -> &SearchSession {
        &self.search
    }
    pub(super) fn presentation(&self) -> Presentation {
        if self.phase == ReplacePhase::Review {
            return Presentation {
                text: format!(
                    "Replace {:?} with {:?} [{} matches]: Enter current, F4 all, F3 next, Esc cancel",
                    self.search.query().text(),
                    self.replacement,
                    self.search.results().count
                ),
                cursor: None,
                selection: 0..0,
            };
        }
        let label = if self.phase == ReplacePhase::Query {
            format!("Replace query [{}]: ", self.search.results().count)
        } else {
            "Replacement: ".to_owned()
        };
        let mut presentation = super::session::field_presentation(label, &self.input);
        if let Some(error) = self
            .search
            .query()
            .error()
            .filter(|_| self.phase == ReplacePhase::Query)
        {
            presentation.text.push_str(&format!("  ({error})"));
        }
        presentation
    }
}

impl ReplaceSession {
    pub(super) fn handle(
        &mut self,
        input: super::Input,
        app: &Application,
        time: std::time::Duration,
    ) -> Result<super::session::Transition, EditError> {
        use super::{
            Input, Response,
            session::{Transition, edit_field},
        };
        use crate::{application::Event, editor::Command};
        Ok(match (self.phase, input) {
            (_, Input::Cancel) => Transition::Closed(self.search.cancel_response(app, time)?),
            (ReplacePhase::Query, Input::Confirm) => {
                if !self.search.query().is_valid() {
                    return Ok(Transition::Active(Response::default()));
                }
                self.phase = ReplacePhase::Replacement;
                self.input = TextInput::default();
                Transition::redraw()
            }
            (ReplacePhase::Replacement, Input::Confirm) => {
                self.replacement = self.input.text().to_owned();
                self.phase = ReplacePhase::Review;
                Transition::redraw()
            }
            (ReplacePhase::Review, input @ (Input::Confirm | Input::ReplaceAll)) => {
                Transition::Closed(Response {
                    events: vec![
                        Event::Edit {
                            view: self.search.view(),
                            command: Command::SetSearchQuery(self.search.query().clone()),
                            time,
                        },
                        Event::Edit {
                            view: self.search.view(),
                            command: if matches!(input, Input::ReplaceAll) {
                                Command::ReplaceAll(self.replacement.clone())
                            } else {
                                Command::ReplaceCurrent(self.replacement.clone())
                            },
                            time,
                        },
                    ],
                    redraw: true,
                    ..Response::default()
                })
            }
            (ReplacePhase::Query | ReplacePhase::Review, Input::Navigate { backward }) => {
                Transition::Active(self.search.preview_response(app, backward, true, time)?)
            }
            (ReplacePhase::Query, input) => {
                self.search.handle(&mut self.input, input, app, time)?
            }
            (ReplacePhase::Replacement, input) => match edit_field(&mut self.input, input) {
                Some(update) if update.text_changed || update.selection_changed => {
                    Transition::redraw()
                }
                _ => Transition::Blocked,
            },
            _ => Transition::Blocked,
        })
    }
    pub(super) fn observe(
        &mut self,
        app: &Application,
        update: &crate::application::Update,
        time: std::time::Duration,
    ) -> Result<super::session::Transition, EditError> {
        self.search.observe_transition(app, update, time)
    }
}
