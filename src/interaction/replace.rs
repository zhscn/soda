//! Search-backed replacement dialog. Query preview and cancellation reuse the
//! search session; replacement edits run only after explicit confirmation.
use super::{Presentation, SearchSession, TextInput};
use crate::{
    application::{Application, ViewId},
    core::EditError,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReplacePhase {
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
    pub fn phase(&self) -> ReplacePhase {
        self.phase
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
        let selection = self.input.selection().range();
        Presentation {
            cursor: Some(label.len() + self.input.cursor()),
            selection: label.len() + selection.start..label.len() + selection.end,
            text: format!("{label}{}", self.input.text()),
        }
    }
}
