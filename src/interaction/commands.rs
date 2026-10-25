//! Application command reduction. Commands resolve their targets on the owner
//! thread and return ordered application events and platform effects.
use super::{
    CommandLine, ExitScope, ExitSession, HelpSession, Layer, Layers, Message, ReplaceSession,
    Response, SearchSession, TextInput,
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
    /// Open the command line with initial text.
    Ex(String),
    /// A command line resolved through the registry when executed.
    Named(String),
    Line {
        edit: super::LineEdit,
        extend: bool,
    },
    Map {
        context: super::Context,
        keys: Vec<super::KeyStroke>,
        target: String,
    },
    Unmap {
        context: super::Context,
        keys: Vec<super::KeyStroke>,
    },
    Define {
        name: String,
        body: String,
    },
    Pipe(String),
    Shell(String),
    Nop,
    OpenPath(std::path::PathBuf),
    /// Switch to the open document with this buffer name.
    Buffer(String),
    SavePath(std::path::PathBuf),
    WriteQuit,
    Clipboard(ClipboardAction),
    Page {
        backward: bool,
        extend: bool,
    },
    New,
    Close,
    Reload,
    Help,
    Save {
        choose_path: bool,
    },
    Quit,
    NextView,
    Search,
    Replace,
}

impl Layers {
    /// Applies a configuration command: `map`, `unmap` or `define-command`.
    pub fn configure(&mut self, command: Command) -> Result<(), String> {
        self.sequence.clear();
        self.vim.clear();
        match command {
            Command::Map {
                context: super::Context::Prompt,
                keys,
                target,
            } => {
                let input = super::keymap::prompt_action(target.trim())
                    .ok_or_else(|| format!("unknown prompt action: {target}"))?;
                let [key] = keys[..] else {
                    return Err("prompt bindings use a single key".into());
                };
                self.keymap
                    .bind_input(key, input, target)
                    .map_err(|e| e.to_string())
            }
            Command::Map {
                context,
                keys,
                target,
            } => {
                if !self.registry.knows(&target) {
                    return Err(format!("unknown command: {target}"));
                }
                self.keymap
                    .bind(context, &keys, Command::Named(target.clone()), target)
                    .map_err(|e| e.to_string())
            }
            Command::Unmap { context, keys } => self
                .keymap
                .unbind(context, &keys)
                .map_err(|e| e.to_string()),
            Command::Define { name, body } => self.registry.define(name, body),
            _ => Err("only map, unmap and define-command are allowed here".into()),
        }
    }
    /// Applies configuration text line by line. Failed lines are skipped and
    /// reported with their one-based line numbers.
    pub fn source(&mut self, text: &str) -> Vec<(usize, String)> {
        let mut errors = vec![];
        for (index, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let result = self
                .registry
                .parse_builtin(line)
                .and_then(|command| self.configure(command));
            if let Err(error) = result {
                errors.push((index + 1, error));
            }
        }
        errors
    }
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
            Command::Ex(text) => {
                let line =
                    CommandLine::new(&text, self.registry.commands(), file_root.to_owned(), app);
                response = self.enter(Layer::CommandLine(Box::new(line)), app, time)?;
                if let Some(Layer::CommandLine(line)) = &mut self.active {
                    let first = line.refresh(app, true);
                    response.effects.extend(first.effects);
                    response.path_requests.extend(first.path_requests);
                }
            }
            Command::Buffer(name) => {
                let name = name.trim();
                match app
                    .workspace()
                    .documents()
                    .find(|id| super::command_line::buffer_name(app, *id) == name)
                {
                    Some(document) => {
                        let active = app
                            .active_view()
                            .and_then(|id| app.view(id))
                            .filter(|v| v.document_id == document);
                        let view =
                            active.or_else(|| app.views().find(|v| v.document_id == document));
                        response
                            .events
                            .push(view.map_or(Event::AddView(document), |v| Event::Focus(v.id)));
                    }
                    None => response.message = Message::Set(format!("No buffer named {name}")),
                }
            }
            Command::Named(line) => {
                if let Some(handler) = self.registry.handler(line.trim()) {
                    let command = handler(app)?;
                    if matches!(command, Command::Named(_)) {
                        response.message = Message::Set(
                            "Registered commands cannot recursively dispatch named commands".into(),
                        );
                    } else {
                        return self.execute(command, app, time, file_root);
                    }
                } else {
                    match self.registry.expand(&line) {
                        Ok(mut commands) if commands.len() == 1 => {
                            return self.execute(commands.pop().unwrap(), app, time, file_root);
                        }
                        Ok(commands) => response.commands = commands,
                        Err(error) => response.message = Message::Set(error),
                    }
                }
            }
            Command::Line { edit, extend } => {
                return self.execute(edit.command(extend), app, time, file_root);
            }
            Command::Map { .. } | Command::Unmap { .. } | Command::Define { .. } => {
                if let Err(error) = self.configure(command) {
                    response.message = Message::Set(error);
                }
            }
            Command::Pipe(shell) => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    response.shell =
                        Some(Box::new(super::shell::pipe(app, view, shell, file_root)));
                }
            }
            Command::Shell(shell) => {
                let view = app.active_view().and_then(|id| app.view(id));
                response.shell = Some(Box::new(super::shell::run(app, view, shell, file_root)));
            }
            Command::Nop => {}
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
                response = self.enter(
                    Layer::Help(HelpSession::new(super::help::text(
                        &self.keymap,
                        &self.registry,
                    ))),
                    app,
                    time,
                )?
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
            Command::New => response
                .events
                .push(Event::NewDocument(Language::PlainText)),
            Command::Close | Command::Reload => {
                if let Some(view) = app.active_view().and_then(|id| app.view(id)) {
                    let document = view.document_id;
                    let reload = matches!(command, Command::Reload);
                    if reload && app.workspace().file(document).unwrap().path().is_none() {
                        response.message =
                            Message::Set("Untitled document has no file to reload".into());
                    } else if app.workspace().is_saving(document) {
                        response.message =
                            Message::Set("Save in progress; wait before leaving document".into());
                    } else if app.workspace().is_dirty(document) {
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
                    let path = app.workspace().file(document).unwrap().path();
                    if choose_path || path.is_none() {
                        let text = path.map_or_else(String::new, |p| {
                            p.strip_prefix(file_root).unwrap_or(p).display().to_string()
                        });
                        return self.execute(
                            Command::Ex(format!("saveas {text}")),
                            app,
                            time,
                            file_root,
                        );
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
                } else if app
                    .workspace()
                    .documents()
                    .any(|id| app.workspace().is_dirty(id))
                {
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
