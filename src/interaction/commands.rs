//! Application command reduction. Commands resolve their targets on the owner
//! thread and return ordered application events and platform effects.
use super::{
    Layer, Layers, Message, Response, SearchSession, TextInput,
    picker::{PickerLimits, PickerSession},
};
use crate::{
    application::{Application, ClipboardAction, Event},
    core::EditError,
    editor::{Command as EditCommand, Language},
};
use std::{path::Path, time::Duration};

/// Commands shared by keyboard bindings and other invocation surfaces.
/// Targets are resolved against the current application state at invocation.
pub enum Command {
    Edit(EditCommand),
    Clipboard(ClipboardAction),
    Open,
    New,
    Close,
    Save { choose_path: bool },
    Quit,
    NextView,
    Search,
    PickFiles,
}

impl Layers {
    /// Invoke a command independently of key bindings. Invocation is blocked
    /// while a modal layer owns focus; confirmation uses that layer's contract.
    pub fn execute(
        &mut self,
        command: Command,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<super::InputResult, EditError> {
        if self.active().is_some() {
            return Ok(super::InputResult::Blocked);
        }
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        match command {
            Command::PickFiles => {
                match PickerSession::new(file_root.to_owned(), PickerLimits::default()) {
                    Ok(session) => response = self.start_picker(session, app, time)?,
                    Err(error) => response.message = Message::Set(error.to_string()),
                }
            }
            Command::Search => {
                if let Some(view) = app.active_view() {
                    response = self.enter(
                        Layer::Search {
                            input: TextInput::default(),
                            session: SearchSession::new(app, view)?,
                        },
                        app,
                        time,
                    )?;
                }
            }
            Command::Clipboard(action) => {
                if let Some(view) = app.active_view() {
                    response
                        .events
                        .push(Event::Clipboard { view, action, time });
                }
            }
            Command::Edit(command) => {
                if let Some(view) = app.active_view() {
                    response.events.push(Event::Edit {
                        view,
                        command,
                        time,
                    });
                }
            }
            Command::Open => response = self.enter(Layer::Open(TextInput::default()), app, time)?,
            Command::New => response
                .events
                .push(Event::NewDocument(Language::PlainText)),
            Command::Close => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    response.events.push(Event::CloseDocument {
                        document: view.document_id,
                        discard: false,
                    });
                }
            }
            Command::Save { choose_path } => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let document = view.document_id;
                    let path = app
                        .workspace()
                        .editor(document)
                        .unwrap()
                        .model()
                        .document()
                        .file()
                        .path();
                    if choose_path || path.is_none() {
                        let text = path.map_or_else(String::new, |p| p.display().to_string());
                        response =
                            self.enter(Layer::Save(document, TextInput::new(&text)), app, time)?;
                    } else {
                        response.events.push(Event::Save {
                            document,
                            target: None,
                        });
                    }
                }
            }
            Command::Quit => {
                if app
                    .workspace()
                    .documents()
                    .any(|id| app.workspace().is_saving(id))
                {
                    response.message =
                        Message::Set("Save in progress; quit after it completes".into());
                } else if app.workspace().documents().any(|id| {
                    app.workspace()
                        .editor(id)
                        .unwrap()
                        .model()
                        .document()
                        .is_dirty()
                }) {
                    response = self.enter(Layer::Quit, app, time)?;
                } else {
                    response.quit = true;
                }
            }
            Command::NextView => {
                let ids: Vec<_> = app.views().map(|v| v.id).collect();
                if let Some(index) = app
                    .active_view()
                    .and_then(|active| ids.iter().position(|id| *id == active))
                {
                    response
                        .events
                        .push(Event::Focus(ids[(index + 1) % ids.len()]));
                }
            }
        }
        if matches!(response.message, Message::Keep) {
            response.message = Message::Clear;
        }
        Ok(super::InputResult::Handled(response))
    }
}
