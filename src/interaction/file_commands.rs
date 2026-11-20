//! File and project commands, including prompts for unsaved documents.
use super::{Command, InputResult, Layer, Layers, Message, Response, SaveWait, commands::active};
use crate::interaction::PromptCommand;
use crate::{
    application::{Application, Event},
    core::EditError,
    editor::{DocumentId, Language},
};
use std::{path::Path, time::Duration};

#[derive(Clone, Debug)]
pub enum FileCommand {
    OpenPath(std::path::PathBuf),
    /// Switch to the open document with this buffer name.
    Buffer(String),
    /// Close the open document with this buffer name, as `close` does the
    /// current one.
    KillBuffer(String),
    SavePath(std::path::PathBuf),
    WriteQuit,
    New,
    Close(Option<Departure>),
    Reload(Option<Departure>),
    Save {
        choose_path: bool,
    },
    Quit(Option<Departure>),
    /// Opens a file named relative to the project.
    OpenProjectFile(std::path::PathBuf),
    /// Asks for a project file, or first for a project when the active
    /// document has none, as project.el's `project-find-file` does.
    FindProjectFile,
    /// Asks for a file of another project.
    SwitchProject(std::path::PathBuf),
    /// Asks for a file, starting from the active document's directory.
    OpenPrompt,
    /// Shows the project, or makes a directory it.
    ProjectRoot(Option<std::path::PathBuf>),
    /// Looks for open files changed on disk: reloads those without unsaved
    /// edits and reports the rest.
    CheckFiles,
    /// Asks about each unsaved file whether to save it, as Emacs's
    /// `save-some-buffers`; the answer is for the one being asked.
    SaveSome(Option<SaveAnswer>),
    /// Shows the buffer used before, or after, in the order of use, as
    /// Emacs's `previous-buffer` and `next-buffer`.
    CycleBuffer {
        backward: bool,
    },
}

/// An answer to `save-some-buffers` about one file.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SaveAnswer {
    Yes,
    No,
    /// This one and every one after it.
    All,
    /// None of them any more.
    Quit,
}
/// How `close`, `reload` and `quit` treat a document with unsaved changes.
/// Without one, they ask through the command line.
#[derive(Clone, Debug)]
pub enum Departure {
    Save(Option<std::path::PathBuf>),
    Discard,
}

/// Reloads the active view's document, or closes `document`.
fn leaving(app: &Application, document: DocumentId, reload: bool, discard: bool) -> Event {
    if reload {
        Event::Reload {
            view: app.active_view().unwrap(),
            discard,
        }
    } else {
        Event::CloseDocument { document, discard }
    }
}
/// A path typed by the user, against the current directory and `~`.
fn resolve(app: &Application, path: &Path) -> Result<std::path::PathBuf, String> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    super::path::resolve_path(&app.directory(), home.as_deref(), path)
}
/// A directory as a path to start from: under `~` when it can be, and
/// ending in a slash so that a file name follows.
fn prompt_directory(directory: &Path) -> String {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    let shown = match home.and_then(|home| directory.strip_prefix(home).ok().map(Path::to_owned)) {
        Some(below) if below.as_os_str().is_empty() => "~".to_owned(),
        Some(below) => format!("~/{}", below.display()),
        None => directory.display().to_string(),
    };
    if shown.ends_with('/') {
        shown
    } else {
        shown + "/"
    }
}
fn check_files(app: &Application, file_root: &Path, response: &mut Response) {
    // Focus comes back often; the message stays unless something changed.
    response.message = Message::Keep;
    response.redraw = false;
    let workspace = app.workspace();
    let mut changed = vec![];
    for document in workspace.documents() {
        if workspace.is_saving(document)
            || !workspace.externally_modified(document).unwrap_or(false)
        {
            continue;
        }
        let path = workspace.file(document).unwrap().path().unwrap();
        let name = path.strip_prefix(file_root).unwrap_or(path).display();
        let view = app.views().find(|view| view.document_id == document);
        if !path.exists() {
            changed.push(format!("{name} was deleted"));
        } else if let Some(view) = view.filter(|_| {
            !workspace.is_dirty(document) && app.options().bool(Some(document), "auto-reload")
        }) {
            response.events.push(Event::Reload {
                view: view.id,
                discard: false,
            });
        } else {
            changed.push(format!("{name} changed on disk"));
        }
    }
    // After the reloads, whose own messages it would otherwise lose to.
    if !changed.is_empty() {
        response.commands.push(Command::Echo(changed.join("; ")));
        response.redraw = true;
    }
}
/// Shows a document: focuses a view of it, or adds one.
pub fn show(app: &Application, document: crate::editor::DocumentId) -> Event {
    let active = active(app).filter(|v| v.document_id == document);
    let view = active.or_else(|| app.views().find(|v| v.document_id == document));
    view.map_or(Event::AddView(document), |v| Event::Focus(v.id))
}

#[derive(Default)]
pub(super) struct FileInteraction {
    /// The documents still awaiting a save decision.
    save_some: Vec<DocumentId>,
    /// The order captured at the start of repeated buffer cycling.
    buffer_cycle: Option<(Vec<DocumentId>, usize)>,
}

impl Layers {
    pub(super) fn execute_file(
        &mut self,
        command: FileCommand,
        mut response: Response,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<InputResult, EditError> {
        let opening_path = matches!(command, FileCommand::OpenPath(_));
        match command {
            FileCommand::KillBuffer(name) => {
                let name = name.trim();
                let document = app
                    .workspace()
                    .documents()
                    .find(|id| app.document_name(*id) == name);
                match document {
                    None => response.message = Message::Set(format!("No buffer named {name}")),
                    Some(document) if active(app).is_some_and(|v| v.document_id == document) => {
                        return self.execute(
                            Command::File(FileCommand::Close(None)),
                            app,
                            time,
                            file_root,
                        );
                    }
                    // Unsaved changes are decided where they can be seen:
                    // the document comes forward, then `close` asks.
                    Some(document)
                        if app.workspace().is_dirty(document)
                            && !app.workspace().is_saving(document) =>
                    {
                        response.events.push(show(app, document));
                        response
                            .commands
                            .push(Command::File(FileCommand::Close(None)));
                    }
                    Some(document) => response = self.leave(document, false, app),
                }
            }
            FileCommand::Buffer(name) => {
                let name = name.trim();
                match app
                    .workspace()
                    .documents()
                    .find(|id| app.document_name(*id) == name)
                {
                    Some(document) => response.events.push(show(app, document)),
                    None => response.message = Message::Set(format!("No buffer named {name}")),
                }
            }
            FileCommand::OpenPrompt => {
                let line = format!("open {}", prompt_directory(&app.directory()));
                return self.execute(
                    Command::Prompt(PromptCommand::Ex(line)),
                    app,
                    time,
                    file_root,
                );
            }
            FileCommand::ProjectRoot(None) => {
                response.message = Message::Set(match app.project() {
                    Some(project) => project.display().to_string(),
                    None => format!("No project; using {}", app.directory().display()),
                });
            }
            FileCommand::ProjectRoot(Some(path)) => {
                match resolve(app, &path).and_then(|path| {
                    std::fs::canonicalize(&path)
                        .ok()
                        .filter(|path| path.is_dir())
                        .ok_or_else(|| format!("{} is not a directory", path.display()))
                }) {
                    Ok(directory) => {
                        response.message = Message::Set(format!("Project {}", directory.display()));
                        response.events.push(Event::SetProject(directory));
                    }
                    Err(error) => {
                        response.message = Message::Set(error);
                        response.failed = true;
                    }
                }
            }
            FileCommand::OpenProjectFile(path) => {
                response.events.push(Event::Open(file_root.join(path)));
            }
            FileCommand::FindProjectFile => {
                let line = match app.project() {
                    Some(_) => "project ",
                    None => "project-switch ",
                };
                return self.execute(
                    Command::Prompt(PromptCommand::Ex(line.into())),
                    app,
                    time,
                    file_root,
                );
            }
            FileCommand::SwitchProject(path) => {
                match resolve(app, &path).and_then(|path| {
                    std::fs::canonicalize(&path)
                        .ok()
                        .filter(|path| path.is_dir())
                        .ok_or_else(|| format!("{} is not a directory", path.display()))
                }) {
                    Ok(directory) => {
                        // A directory chosen without a marker is a project
                        // from now on, so the file opened in it has it.
                        let line = Command::Prompt(PromptCommand::ProjectLine(directory.clone()));
                        let mut opened = self.execute(line, app, time, file_root)?;
                        if let super::InputResult::Handled(response) = &mut opened {
                            response.events.insert(0, Event::AddProject(directory));
                        }
                        return Ok(opened);
                    }
                    Err(error) => {
                        response.message = Message::Set(error);
                        response.failed = true;
                    }
                }
            }
            FileCommand::OpenPath(path) | FileCommand::SavePath(path) => {
                match resolve(app, &path) {
                    Ok(path) => {
                        if opening_path {
                            // Nothing on screen changes, so say why.
                            if let Some(document) = active(app).map(|v| v.document_id)
                                && let Some(current) =
                                    app.workspace().file(document).and_then(|f| f.path())
                                && std::fs::canonicalize(&path).is_ok_and(|p| p == current)
                            {
                                response.message = Message::Set(format!(
                                    "Already at {}",
                                    app.document_name(document)
                                ));
                            }
                            response.events.push(Event::Open(path));
                        } else if let Some(view) = active(app) {
                            response.events.push(Event::Save {
                                document: view.document_id,
                                target: Some(path),
                            });
                        }
                    }
                    Err(error) => {
                        response.message = Message::Set(error);
                        response.failed = true;
                    }
                }
            }
            FileCommand::WriteQuit => {
                let dirty =
                    active(app).is_some_and(|view| app.workspace().is_dirty(view.document_id));
                let decision = dirty.then_some(Departure::Save(None));
                return self.execute(
                    Command::File(FileCommand::Quit(decision)),
                    app,
                    time,
                    file_root,
                );
            }
            FileCommand::SaveSome(answer) => {
                let unsaved = |id: &crate::editor::DocumentId| {
                    app.workspace().is_dirty(*id)
                        && !app.workspace().is_saving(*id)
                        && app
                            .workspace()
                            .file(*id)
                            .is_some_and(|f| f.path().is_some())
                };
                match answer {
                    None => {
                        self.files.save_some = app.workspace().documents().filter(unsaved).collect()
                    }
                    Some(answer) => {
                        let asked = self.files.save_some.first().copied();
                        let rest = match answer {
                            SaveAnswer::Yes => asked.into_iter().collect(),
                            SaveAnswer::All => std::mem::take(&mut self.files.save_some),
                            SaveAnswer::No | SaveAnswer::Quit => vec![],
                        };
                        for document in rest.into_iter().filter(unsaved) {
                            response.events.push(Event::Save {
                                document,
                                target: None,
                            });
                        }
                        if answer == SaveAnswer::Quit {
                            self.files.save_some.clear();
                        } else if !self.files.save_some.is_empty() {
                            self.files.save_some.remove(0);
                        }
                    }
                }
                self.files.save_some.retain(unsaved);
                match self.files.save_some.first() {
                    Some(document) => {
                        let ask = Command::Prompt(PromptCommand::Ask {
                            line: "save-some-buffers ".into(),
                            note: format!("save {}?", app.document_name(*document)),
                        });
                        let asked = self.execute(ask, app, time, file_root)?;
                        if let super::InputResult::Handled(mut asked) = asked {
                            asked.events.splice(0..0, response.events);
                            return Ok(super::InputResult::Handled(asked));
                        }
                        return Ok(asked);
                    }
                    None if answer.is_none() => {
                        response.message = Message::Set("(No files need saving)".into());
                    }
                    None => {}
                }
            }
            FileCommand::CycleBuffer { backward } => {
                let current = active(app).map(|view| view.document_id);
                let again = self.keys.command.after(
                    |c| matches!(c, Command::File(FileCommand::CycleBuffer { .. })),
                    &["previous-buffer", "next-buffer"],
                );
                let fresh = !again || self.files.buffer_cycle.is_none();
                if fresh {
                    let mut order: Vec<_> = current.into_iter().collect();
                    for document in app.documents_by_use().chain(app.workspace().documents()) {
                        if !order.contains(&document) {
                            order.push(document);
                        }
                    }
                    self.files.buffer_cycle = Some((order, 0));
                }
                let (order, at) = self.files.buffer_cycle.as_mut().unwrap();
                order.retain(|document| app.workspace().editor(*document).is_some());
                if order.len() < 2 {
                    response.message = Message::Set("No other buffer".into());
                    return Ok(super::InputResult::Handled(response));
                }
                let n = order.len();
                *at = if backward {
                    (*at + 1) % n
                } else {
                    (*at + n - 1) % n
                };
                response.events.push(show(app, order[*at]));
            }
            FileCommand::New => response
                .events
                .push(Event::NewDocument(Language::PlainText)),
            FileCommand::Close(decision) => {
                if let Some(view) = active(app) {
                    let document = view.document_id;
                    if app.workspace().is_dirty(document) && !app.workspace().is_saving(document) {
                        return self.depart("close", document, decision, app, time, file_root);
                    }
                    response = self.leave(document, false, app);
                }
            }
            FileCommand::Reload(decision) => {
                if let Some(view) = active(app) {
                    let document = view.document_id;
                    if app.workspace().file(document).unwrap().path().is_none() {
                        response.message =
                            Message::Set("Untitled document has no file to reload".into());
                    } else if app.workspace().is_dirty(document)
                        && !app.workspace().is_saving(document)
                    {
                        return self.depart("reload", document, decision, app, time, file_root);
                    } else {
                        response = self.leave(document, true, app);
                    }
                }
            }
            FileCommand::Save { choose_path } => {
                if let Some(view) = active(app) {
                    let document = view.document_id;
                    let path = app.workspace().file(document).unwrap().path();
                    if choose_path || path.is_none() {
                        let text = path.map_or_else(String::new, |p| {
                            p.strip_prefix(app.directory())
                                .unwrap_or(p)
                                .display()
                                .to_string()
                        });
                        return self.execute(
                            Command::Prompt(PromptCommand::Ex(format!("saveas {text}"))),
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
            FileCommand::Quit(decision) => {
                let active = active(app).map(|view| view.document_id);
                let dirty = active
                    .filter(|id| app.workspace().is_dirty(*id))
                    .or_else(|| {
                        app.workspace()
                            .documents()
                            .find(|id| app.workspace().is_dirty(*id))
                    });
                if app
                    .workspace()
                    .documents()
                    .any(|id| app.workspace().is_saving(id))
                {
                    response.message =
                        Message::Set("Save in progress; quit after it completes".into());
                } else if let Some(document) = dirty {
                    return self.depart("quit", document, decision, app, time, file_root);
                } else {
                    response.quit = true;
                }
            }
            FileCommand::CheckFiles => {
                // Unlike other commands, an empty check keeps the message.
                check_files(app, file_root, &mut response);
                return Ok(super::InputResult::Handled(response));
            }
        }
        if matches!(response.message, Message::Keep) {
            response.message = Message::Clear;
        }
        Ok(InputResult::Handled(response))
    }

    /// Closes or reloads a document that needs no decision.
    fn leave(&self, document: DocumentId, reload: bool, app: &Application) -> Response {
        let mut response = Response {
            redraw: true,
            ..Response::default()
        };
        if app.workspace().is_saving(document) {
            response.message =
                Message::Set("Save in progress; wait before leaving document".into());
        } else {
            response.events.push(leaving(app, document, reload, false));
        }
        response
    }
    /// Leaves a dirty document by the decision, asking for one through the
    /// command line when there is none. Each step is a command line; nothing
    /// nests.
    fn depart(
        &mut self,
        action: &str,
        document: DocumentId,
        decision: Option<Departure>,
        app: &Application,
        time: Duration,
        file_root: &Path,
    ) -> Result<super::InputResult, EditError> {
        let name = app.document_name(document);
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        match decision {
            None => {
                let ask = Command::Prompt(PromptCommand::Ask {
                    line: format!("{action} "),
                    note: format!("unsaved {name}"),
                });
                return self.execute(ask, app, time, file_root);
            }
            Some(Departure::Discard) => {
                response
                    .events
                    .push(leaving(app, document, action == "reload", true));
                // Quitting continues with the next unsaved document.
                if action == "quit" {
                    response.commands.push(Command::Named("quit".into()));
                }
            }
            Some(Departure::Save(None))
                if app.workspace().file(document).unwrap().path().is_none() =>
            {
                let ask = Command::Prompt(PromptCommand::Ask {
                    line: format!("{action} save "),
                    note: format!("{name} needs a PATH"),
                });
                return self.execute(ask, app, time, file_root);
            }
            Some(Departure::Save(path)) => {
                let target = match path {
                    Some(path) => match resolve(app, &path) {
                        Ok(target) => Some(target),
                        Err(error) => {
                            response.message = Message::Set(error);
                            return Ok(super::InputResult::Handled(response));
                        }
                    },
                    None => None,
                };
                let retry = target.as_ref().map_or_else(
                    || format!("{action} save"),
                    |target| {
                        let directory = app.directory();
                        let shown = target.strip_prefix(directory).unwrap_or(target);
                        format!("{action} save {}", shown.display())
                    },
                );
                let wait = SaveWait::new(app, document, action.to_owned(), retry);
                response = self.enter(Layer::Saving(wait), app, time)?;
                response.events.push(Event::Save { document, target });
            }
        }
        Ok(super::InputResult::Handled(response))
    }
}
