//! Application command reduction. Commands resolve their targets on the owner
//! thread and return ordered application events and platform effects.
use super::{
    FileCommand, HelpSession, InsertCommand, Layer, Layers, MacroCommand, Message, PromptCommand,
    Response, SearchCommand, SetupCommand, WindowCommand, expand, registry::holds_commands,
};
use crate::{
    application::{Application, ClipboardAction, Event},
    core::EditError,
    editor::Command as EditCommand,
};
use std::{path::Path, time::Duration};

/// Commands shared by keyboard bindings and other invocation surfaces.
/// Targets are resolved against the current application state at invocation.
#[derive(Clone, Debug)]
pub enum Command {
    Edit(EditCommand),
    SetMode(super::EditMode),
    Modal(super::modal::Action),
    /// Work the runtime does for the modal layer.
    Effect(Box<super::modal::Effect>),
    /// A command line resolved through the registry when executed.
    Named(String),
    /// Reads the next keys through the keypad.
    Keypad(super::KeypadStart),
    Pipe(String),
    Shell(String),
    Nop,
    Clipboard(ClipboardAction),
    Page {
        backward: bool,
        extend: bool,
    },
    /// Makes the text of the graphical frontend a step larger or smaller,
    /// or with none, as the options set it.
    TextScale(Option<i32>),
    Help,
    File(FileCommand),
    Window(WindowCommand),
    Results(super::ResultsCommand),
    /// Goes back to where the caret jumped from, or forward again.
    JumpBack,
    JumpForward,
    /// Stops background work: the run, the shell command and the search.
    Stop,
    /// Hands the terminal back to the shell until the editor is resumed.
    Suspend,
    Restart,
    Lua(super::LuaCommand),
    /// Shows a message.
    Echo(String),
    /// Fails with a message, which stops a macro.
    Fail(String),
    /// Shows recent messages in `*messages*`.
    Messages,
    Insert(InsertCommand),
    Prompt(PromptCommand),
    Search(SearchCommand),
    Macro(MacroCommand),
    Setup(SetupCommand),
}
/// Why a move cannot go: the caret is at the first or last line, or the
/// start or end of the text, already.
fn past_the_end(app: &Application, command: &EditCommand) -> Option<&'static str> {
    use crate::editor::Motion;
    let EditCommand::Move { motion, .. } = command else {
        return None;
    };
    let view = active(app)?;
    let editor = app.workspace().editor(view.document_id)?;
    let text = editor.model().document().snapshot();
    let head = editor.model().session(view.session_id)?.selection().head;
    let line = text.line_of(head)?;
    match motion {
        Motion::Up if line == 0 => Some("Beginning of buffer"),
        Motion::Backward if head == 0 => Some("Beginning of buffer"),
        Motion::Down if line + 1 >= text.line_count() => Some("End of buffer"),
        Motion::Forward if head >= text.len_bytes() => Some("End of buffer"),
        _ => None,
    }
}
pub(super) fn active(app: &Application) -> Option<&crate::application::View> {
    app.active_view().and_then(|id| app.view(id))
}
impl Layers {
    /// The rows of text each window shows.
    pub fn set_window_rows(&mut self, rows: Vec<(crate::application::ViewId, usize)>) {
        self.geometry.window_rows = rows;
    }
    pub fn set_page_rows(&mut self, rows: usize) {
        self.geometry.page_rows = rows;
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
        // A hook runs between keys, not because of one: the keys of a
        // binding being typed stay.
        if self.lua_interaction.hook.is_none() {
            self.keys.sequence.clear();
        }
        // The prefix argument waits for the keypad to give it a command.
        if !matches!(
            command,
            Command::Modal(_) | Command::Keypad(_) | Command::Named(_)
        ) {
            self.modal.clear();
        }
        let mut response = Response {
            redraw: true,
            message: Message::Clear,
            ..Response::default()
        };
        self.jumps.clear_pending();
        // With a mark set, every move extends from it, as in Emacs; in
        // Insert only when editing is not modal, as meow's Insert typing
        // drops it.
        let marked = (self.mode != super::EditMode::Insert || !super::modal_on(app))
            && super::modal::execute_place(app)
                .and_then(|selection| self.modal.tag(selection))
                .is_some_and(|tag| tag.kind == super::modal::Kind::Char);
        let command = match command {
            Command::Edit(EditCommand::Move {
                motion,
                extend: false,
            }) if marked => Command::Edit(EditCommand::Move {
                motion,
                extend: true,
            }),
            command => command,
        };
        // Typing and yanking go in at the caret and drop the selection, as
        // Emacs does without delete-selection-mode; meow's Insert keeps its
        // own way.
        if self.mode == super::EditMode::Insert
            && !super::modal_on(app)
            && matches!(
                command,
                Command::Edit(
                    EditCommand::TypeChar(_) | EditCommand::InsertText(_) | EditCommand::Enter
                ) | Command::Clipboard(ClipboardAction::Paste)
            )
            && let Some(view) = active(app)
            && let Some(selection) = super::modal::execute_place(app)
            && !selection.range().is_empty()
        {
            self.modal.tag = None;
            response.events.push(Event::Edit {
                view: view.id,
                command: EditCommand::SetSelection(crate::core::Selection::caret(selection.head)),
                time,
            });
        }
        match &command {
            Command::Results(super::ResultsCommand::ResultStep { .. }) => {
                self.jumps.expect_result()
            }
            Command::Modal(super::modal::Action::Found {
                kind: super::modal::Kind::Block,
                ..
            })
            | Command::Edit(EditCommand::Goto { .. })
            | Command::Edit(EditCommand::Move {
                motion: crate::editor::Motion::DocumentStart | crate::editor::Motion::DocumentEnd,
                ..
            }) => self.jumps.expect(),
            _ => {}
        }
        match command {
            Command::Keypad(start) => self.keys.sequence.start(start),
            Command::JumpBack => match self.jumps.back(app) {
                Some(place) => go(app, place, time, &mut response),
                None => response.message = Message::Set("At the oldest jump".into()),
            },
            Command::JumpForward => match self.jumps.forward() {
                Some(place) => go(app, place, time, &mut response),
                None => response.message = Message::Set("At the newest jump".into()),
            },
            Command::SetMode(mode) => {
                self.modal.tag = None;
                if self.mode == super::EditMode::Beacon {
                    self.leave_beacon();
                }
                // Without modal editing there is no other mode to be in.
                self.mode = if super::modal_on(app) {
                    mode
                } else {
                    super::EditMode::Insert
                };
            }
            Command::Modal(action) => response = self.modal_execute(action, app, time),
            Command::Fail(message) => {
                response.failed = true;
                response.message = Message::Set(message);
            }
            // Only the runtime can do these; it takes them from the response.
            effect @ Command::Effect(_) => response.commands.push(effect),
            Command::Named(line) => {
                let line = if holds_commands(&line) || !expand::has_expansions(&line) {
                    line
                } else {
                    match expand::expand(&line, &self.expansion(app, file_root)) {
                        Ok(line) => line,
                        Err(error) => {
                            response.message = Message::Set(error);
                            response.failed = true;
                            return Ok(super::InputResult::Handled(response));
                        }
                    }
                };
                match self.registry.expand(&line) {
                    Ok(mut commands) if commands.len() == 1 => {
                        return self.execute(commands.pop().unwrap(), app, time, file_root);
                    }
                    Ok(commands) => response.commands = commands,
                    Err(error) => {
                        response.message = Message::Set(error);
                        response.failed = true;
                    }
                }
            }
            Command::Pipe(shell) => {
                if let Some(view) = active(app) {
                    let directory = app.directory();
                    response.effects.push(super::ResponseEffect::Shell(Box::new(
                        super::shell::pipe(app, view, shell, &directory),
                    )));
                }
            }
            Command::Shell(shell) => {
                let view = active(app);
                let directory = app.directory();
                response
                    .effects
                    .push(super::ResponseEffect::Shell(Box::new(super::shell::run(
                        app, view, shell, &directory,
                    ))));
            }
            Command::Nop => {}
            Command::Help => {
                response = self.enter(
                    Layer::Help(HelpSession::new(super::help::text(
                        &self.keys.keymap,
                        &self.registry,
                        super::modal_on(app),
                    ))),
                    app,
                    time,
                )?
            }
            Command::Page { backward, extend } => {
                if let Some(view) = active(app) {
                    let count = self.geometry.page_rows.saturating_sub(1).max(1);
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
                        top.saturating_add(count).min(
                            snapshot
                                .line_count()
                                .saturating_sub(self.geometry.page_rows.max(1)),
                        )
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
                        horizontal_scroll: view.viewport.horizontal_scroll,
                    });
                }
            }
            Command::Clipboard(action) => {
                if let Some(view) = app.active_view() {
                    response
                        .events
                        .push(Event::Clipboard { view, action, time });
                }
            }
            Command::Insert(command) => self.execute_insert(command, app, time, &mut response),
            Command::Edit(command) => {
                // Moving past either end of the text fails, as Emacs's
                // `next-line` and `forward-char` signal, which ends a macro
                // played until something fails.
                if let Some(message) = past_the_end(app, &command) {
                    return Ok(super::InputResult::Handled(response.modal_failure(message)));
                }
                if let Some(view) = app.active_view() {
                    response.events.push(Event::Edit {
                        view,
                        command,
                        time,
                    });
                }
            }
            Command::TextScale(step) => response.events.push(Event::TextScale(step)),
            Command::Prompt(command) => {
                response = self.execute_prompt(command, app, time, file_root)?;
            }
            Command::Search(command) => {
                response = self.execute_search(command, response, app, time)?;
            }
            Command::Macro(command) => {
                response = self.execute_macro(command, response, app);
            }
            Command::Setup(command) => {
                response = self.execute_setup(command, response, app);
            }
            Command::File(command) => {
                return self.execute_file(command, response, app, time, file_root);
            }
            Command::Window(command) => {
                response = self.execute_window(command, response, app, time)?;
            }
            Command::Results(command) => {
                self.execute_results(command, app, time, file_root, &mut response)
            }
            Command::Stop => response.effects.push(super::ResponseEffect::Stop),
            Command::Suspend => response.suspend = true,
            // Unsaved text goes along, so nothing is asked.
            Command::Restart => {
                if app
                    .workspace()
                    .documents()
                    .any(|id| app.workspace().is_saving(id))
                {
                    response.message =
                        Message::Set("Save in progress; restart after it completes".into());
                } else {
                    response.restart = true;
                }
            }
            Command::Lua(command) => {
                return self.execute_lua(command, response, app, time, file_root);
            }
            Command::Messages => response.effects.push(super::ResponseEffect::ShowMessages),
            Command::Echo(text) => response.message = Message::Set(text),
        }
        if matches!(response.message, Message::Keep) {
            response.message = Message::Clear;
        }
        Ok(super::InputResult::Handled(response))
    }
}
/// Takes the caret to a place from the jump history: focusing a view of its
/// document, one on screen if any, in the window that holds it.
fn go(
    app: &Application,
    place: crate::editor::DocumentPosition,
    time: Duration,
    response: &mut Response,
) {
    let view = app
        .views()
        .filter(|view| view.document_id == place.document_id)
        .max_by_key(|view| app.windows().contains(view.id));
    let Some(view) = view else {
        response.events.push(Event::AddView(place.document_id));
        return;
    };
    response.events.extend([
        Event::Focus(view.id),
        Event::Edit {
            view: view.id,
            command: EditCommand::SetSelection(crate::core::Selection::caret(place.offset.0)),
            time,
        },
    ]);
}
/// A view's selection.
pub(super) fn selection_of(
    app: &Application,
    view: crate::application::ViewId,
) -> Option<crate::core::Selection> {
    let state = app.view(view)?;
    let editor = app.workspace().editor(state.document_id)?;
    Some(editor.model().session(state.session_id)?.selection())
}
