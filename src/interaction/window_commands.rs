//! Commands that change window placement or focus.
use super::{Command, Layer, Layers, Response};
use crate::interaction::FileCommand;
use crate::{
    application::{Application, Axis, Direction, Event},
    core::EditError,
};
use std::time::Duration;

#[derive(Clone, Debug)]
pub enum WindowCommand {
    /// Splits the active window, then opens a file in the new one if given.
    Split(Axis, Option<std::path::PathBuf>),
    Close,
    Only,
    Focus(Direction),
    Cycle {
        backward: bool,
    },
    /// Grows the window by cells along an axis, or shrinks it.
    Resize(Axis, i32),
    /// Makes splits equal and side windows their opening size.
    ResetSizes,
    /// Takes the window's document out of its row of tabs.
    CloseTab,
    /// Resizes step by step until Esc.
    ResizeMode,
    NextView,
    /// Focuses a window chosen by its label.
    WindowPick,
}

impl Layers {
    pub(super) fn execute_window(
        &mut self,
        command: WindowCommand,
        mut response: Response,
        app: &Application,
        time: Duration,
    ) -> Result<Response, EditError> {
        match command {
            WindowCommand::WindowPick => match super::labels::LabelSession::windows(app) {
                Ok(session) => response = self.enter(Layer::Labels(session), app, time)?,
                Err(Some(other)) => response.events.push(Event::Focus(other)),
                Err(None) => {}
            },
            WindowCommand::ResizeMode => {
                if let Some(session) = super::resize::ResizeSession::new(app) {
                    response = self.enter(Layer::Resize(session), app, time)?;
                }
            }
            WindowCommand::NextView => {
                // Views shown in other windows stay where they are.
                let ids: Vec<_> = app
                    .views()
                    .map(|v| v.id)
                    .filter(|id| Some(*id) == app.active_view() || !app.windows().contains(*id))
                    .collect();
                if let Some(index) = app
                    .active_view()
                    .and_then(|active| ids.iter().position(|id| *id == active))
                {
                    response
                        .events
                        .push(Event::Focus(ids[(index + 1) % ids.len()]));
                }
            }
            command => {
                let Some(active) = app.active_view() else {
                    return Ok(response);
                };
                response.events.push(match command {
                    WindowCommand::ResizeMode
                    | WindowCommand::WindowPick
                    | WindowCommand::NextView => unreachable!(),
                    WindowCommand::Resize(axis, delta) => Event::ResizeWindow { axis, delta },
                    WindowCommand::ResetSizes => Event::ResetWindowSizes,
                    // A file to open goes to the new window, which takes
                    // focus for it, as `find-file-other-window`.
                    WindowCommand::Split(axis, path) => {
                        let follow = path.is_some();
                        response
                            .commands
                            .extend(path.map(|value| Command::File(FileCommand::OpenPath(value))));
                        Event::Split { axis, follow }
                    }
                    WindowCommand::CloseTab => match app.view(active) {
                        Some(view) => Event::CloseTab(view.document_id),
                        None => return Ok(response),
                    },
                    WindowCommand::Close => Event::CloseWindow(active),
                    WindowCommand::Only => Event::OnlyWindow(active),
                    WindowCommand::Focus(direction) => Event::FocusWindow(direction),
                    WindowCommand::Cycle { backward } => Event::CycleWindow { backward },
                });
            }
        }
        Ok(response)
    }
}
