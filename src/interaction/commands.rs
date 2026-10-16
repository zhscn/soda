//! Application command reduction. Commands resolve their targets on the owner
//! thread and return ordered application events and platform effects.
use super::{
    BufferSession, ExitScope, ExitSession, GotoSession, HelpSession, Layer, Layers, Message,
    ReplaceSession, Response, SearchSession, TextInput,
    path::PathInput,
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
#[derive(Clone, Debug)]
pub enum Command {
    Edit(EditCommand),
    SetMode(super::EditMode),
    Vim(super::vim::VimCommand),
    Ex,
    Named(String),
    OpenPath(std::path::PathBuf),
    SavePath(std::path::PathBuf),
    WriteQuit,
    Clipboard(ClipboardAction),
    Goto,
    Page { backward: bool, extend: bool },
    Open,
    New,
    Close,
    Reload,
    Help,
    Save { choose_path: bool },
    Quit,
    NextView,
    Search,
    Replace,
    PickFiles,
    SwitchBuffer,
}

impl Layers {
    pub fn set_page_rows(&mut self, rows: usize) {
        self.page_rows = rows;
    }
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
        self.sequence.clear();
        self.vim.clear();
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        let opening_path = matches!(command, Command::OpenPath(_));
        match command {
            Command::SetMode(mode) => {
                if matches!(mode, super::EditMode::Visual | super::EditMode::VisualLine) {
                    if self.mode == mode {
                        return Ok(super::InputResult::Handled(response));
                    }
                    return self.execute(
                        Command::Vim(super::vim::VimCommand::Visual {
                            linewise: mode == super::EditMode::VisualLine,
                        }),
                        app,
                        time,
                        file_root,
                    );
                }
                let caret = self.vim.caret();
                self.vim.reset();
                self.mode = mode;
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let selection = app
                        .workspace()
                        .editor(view.document_id)
                        .unwrap()
                        .model()
                        .session(view.session_id)
                        .unwrap()
                        .selection();
                    response.events.push(Event::Edit {
                        view: view.id,
                        command: EditCommand::SetSelection(
                            caret.map_or(selection, crate::core::Selection::caret),
                        ),
                        time,
                    });
                }
            }
            Command::Vim(super::vim::VimCommand::Search { backward }) => {
                if let Some(view) = app.active_view() {
                    let mut session = SearchSession::new(app, view)?;
                    session.set_direction(backward, self.vim.last_search.clone());
                    response = self.enter(
                        Layer::Search {
                            input: TextInput::default(),
                            session,
                        },
                        app,
                        time,
                    )?;
                }
            }
            Command::Vim(command) => response = self.vim_execute(command, app, time),
            Command::Ex => {
                response = self.enter(Layer::Ex(super::ExSession::default()), app, time)?
            }
            Command::Named(name) => {
                if let Some(handler) = self.handlers.get(&name) {
                    let command = handler(app)?;
                    if matches!(command, Command::Named(_)) {
                        response.message = Message::Set(
                            "Named commands cannot recursively dispatch named commands".into(),
                        );
                    } else {
                        return self.execute(command, app, time, file_root);
                    }
                } else {
                    response.message = Message::Set(format!("Unknown command: {name}"));
                }
            }
            Command::OpenPath(path) | Command::SavePath(path) => {
                let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
                match super::path::resolve_path(file_root, home.as_deref(), &path) {
                    Ok(path) => {
                        if opening_path {
                            response.events.push(Event::Open(path));
                        } else if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                            response.events.push(Event::Save {
                                document: view.document_id,
                                target: Some(path),
                            });
                        }
                    }
                    Err(error) => response.message = Message::Set(error),
                }
            }
            Command::WriteQuit => {
                if let Some(session) = ExitSession::write_quit(app, file_root.to_owned()) {
                    response = self.enter(Layer::Exit(session), app, time)?;
                    if let Some(Layer::Exit(session)) = &mut self.active
                        && let super::session::Transition::Active(next) =
                            session.handle(super::Input::Text(super::InputKey::Char('s')), app)
                    {
                        let mut next = next;
                        let mut events = response.events;
                        events.append(&mut next.events);
                        next.events = events;
                        response = next;
                    }
                } else {
                    return self.execute(Command::Quit, app, time, file_root);
                }
            }
            Command::Help => {
                response = self.enter(Layer::Help(HelpSession::default()), app, time)?
            }
            Command::Goto => {
                if let Some(view) = app.active_view() {
                    response = self.enter(Layer::Goto(GotoSession::new(view)), app, time)?;
                }
            }
            Command::Page { backward, extend } => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let count = self.page_rows.saturating_sub(1).max(1);
                    let snapshot = app
                        .workspace()
                        .editor(view.document_id)
                        .unwrap()
                        .model()
                        .document()
                        .snapshot();
                    let top = snapshot.line_of(view.viewport.anchor.offset.0).unwrap();
                    let top = if backward {
                        top.saturating_sub(count)
                    } else {
                        top.saturating_add(count)
                            .min(snapshot.line_count().saturating_sub(self.page_rows.max(1)))
                    };
                    response.events.push(Event::Edit {
                        view: view.id,
                        command: EditCommand::Move {
                            motion: crate::editor::Motion::Lines { backward, count },
                            extend,
                        },
                        time,
                    });
                    response.events.push(Event::SetViewport {
                        view: view.id,
                        anchor: crate::core::ByteOffset(snapshot.line_start(top).unwrap()),
                        horizontal_column: view.viewport.horizontal_column,
                    });
                }
            }
            Command::SwitchBuffer => {
                response = self.enter(Layer::Buffer(BufferSession::new(app)), app, time)?;
            }
            Command::PickFiles => {
                match PickerSession::new(file_root.to_owned(), PickerLimits::default()) {
                    Ok(session) => response = self.start_picker(session, app, time)?,
                    Err(error) => response.message = Message::Set(error.to_string()),
                }
            }
            Command::Replace => {
                if let Some(view) = app.active_view() {
                    response =
                        self.enter(Layer::Replace(ReplaceSession::new(app, view)?), app, time)?;
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
            Command::Open => {
                response = self.enter(
                    Layer::Open(PathInput::new(file_root.to_owned(), "")),
                    app,
                    time,
                )?
            }
            Command::New => response
                .events
                .push(Event::NewDocument(Language::PlainText)),
            Command::Close | Command::Reload => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let document = view.document_id;
                    let editor = app.workspace().editor(document).unwrap();
                    let reload = matches!(command, Command::Reload);
                    if reload && editor.model().document().file().path().is_none() {
                        response.message =
                            Message::Set("Untitled document has no file to reload".into());
                    } else if app.workspace().is_saving(document) {
                        response.message =
                            Message::Set("Save in progress; wait before leaving document".into());
                    } else if editor.model().document().is_dirty() {
                        let scope = if reload {
                            ExitScope::Reload(view.id)
                        } else {
                            ExitScope::Close(document)
                        };
                        response = self.enter(
                            Layer::Exit(
                                ExitSession::new_with_root(app, scope, file_root.to_owned())
                                    .unwrap(),
                            ),
                            app,
                            time,
                        )?;
                    } else {
                        response.events.push(if reload {
                            Event::Reload {
                                view: view.id,
                                discard: false,
                            }
                        } else {
                            Event::CloseDocument {
                                document,
                                discard: false,
                            }
                        });
                    }
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
                        response = self.enter(
                            Layer::Save(document, PathInput::new(file_root.to_owned(), &text)),
                            app,
                            time,
                        )?;
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
                    response = self.enter(
                        Layer::Exit(
                            ExitSession::new_with_root(app, ExitScope::Quit, file_root.to_owned())
                                .unwrap(),
                        ),
                        app,
                        time,
                    )?;
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
