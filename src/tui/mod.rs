//! Minimal terminal host. Key bindings and screen layout adapt the application
//! API; text mutation, history, file identity and sessions stay in lower layers.
mod input;
mod layout;
use crate::{
    application::{Application, Effect, Event, Update},
    editor::{Command, DocumentId, Language},
};
use crossterm::{
    cursor::{Hide, MoveTo, Show},
    event::{
        self, DisableBracketedPaste, EnableBracketedPaste, Event as TerminalEvent, KeyCode,
        KeyEventKind,
    },
    execute, queue,
    style::{Attribute, Print, SetAttribute},
    terminal::{self, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen},
};
use input::{Action, InputField};
use std::{
    io::{self, IsTerminal, Write},
    path::PathBuf,
    sync::mpsc,
    time::{Duration, Instant},
};

struct Terminal;
impl Terminal {
    fn enter() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        let guard = Self;
        execute!(
            io::stdout(),
            EnterAlternateScreen,
            EnableBracketedPaste,
            Hide
        )?;
        Ok(guard)
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = execute!(
            io::stdout(),
            SetAttribute(Attribute::Reset),
            DisableBracketedPaste,
            Show,
            LeaveAlternateScreen
        );
        let _ = terminal::disable_raw_mode();
    }
}
enum Prompt {
    Open(InputField),
    Save(DocumentId, InputField),
    Quit,
}
struct Host {
    app: Application,
    sender: mpsc::Sender<Event>,
    receiver: mpsc::Receiver<Event>,
    prompt: Option<Prompt>,
    message: String,
    epoch: Instant,
    quit: bool,
    dirty: bool,
}
impl Host {
    fn new() -> Self {
        let (sender, receiver) = mpsc::channel();
        let mut host = Self {
            app: Application::default(),
            sender,
            receiver,
            prompt: None,
            message: String::new(),
            epoch: Instant::now(),
            quit: false,
            dirty: true,
        };
        host.dispatch(Event::NewDocument(Language::PlainText));
        host
    }
    fn dispatch(&mut self, event: Event) {
        match self.app.dispatch(event) {
            Ok(update) => self.accept(update),
            Err(error) => {
                self.message = match error {
                    crate::application::Error::File(crate::files::FileError::UnsavedChanges) => {
                        "Unsaved changes; save before closing".into()
                    }
                    other => other.to_string(),
                };
                self.dirty = true;
            }
        }
    }
    fn accept(&mut self, update: Update) {
        self.dirty |= update.active_changed
            || !update.changed_views.is_empty()
            || !update.closed_views.is_empty()
            || !update.files.is_empty()
            || !update.effects.is_empty();
        for result in update.files {
            self.message = match result.result {
                Ok(file) => format!(
                    "Saved {}{}",
                    file.path.display(),
                    if file.dirty {
                        " (newer edits remain)"
                    } else {
                        ""
                    }
                ),
                Err(error) => error.to_string(),
            };
        }
        for effect in update.effects {
            let service = self.app.workspace().service().clone();
            let sender = self.sender.clone();
            std::thread::spawn(move || {
                let event = match effect {
                    Effect::Open(request) => Event::OpenFinished(service.read_request(request)),
                    Effect::Save(request) => Event::SaveFinished(service.write(*request)),
                };
                let _ = sender.send(event);
            });
        }
    }
    fn edit(&mut self, command: Command) {
        if let Some(view) = self.app.active_view() {
            self.dispatch(Event::Edit {
                view,
                command,
                time: self.epoch.elapsed(),
            });
        }
    }
    fn action(&mut self, action: Action) {
        match action {
            Action::Edit(command) => self.edit(command),
            Action::Open => self.prompt = Some(Prompt::Open(InputField::default())),
            Action::New => self.dispatch(Event::NewDocument(Language::PlainText)),
            Action::Close => {
                if let Some(view) = self.app.active_view() {
                    let document = self.app.view(view).unwrap().document_id;
                    self.dispatch(Event::CloseDocument {
                        document,
                        discard: false,
                    });
                }
            }
            Action::Save { choose_path } => {
                if let Some(id) = self.app.active_view() {
                    let document = self.app.view(id).unwrap().document_id;
                    let path = self
                        .app
                        .workspace()
                        .editor(document)
                        .unwrap()
                        .model()
                        .document()
                        .file()
                        .path();
                    if choose_path || path.is_none() {
                        let text = path.map_or_else(String::new, |p| p.display().to_string());
                        self.prompt = Some(Prompt::Save(
                            document,
                            InputField {
                                cursor: text.len(),
                                text,
                            },
                        ));
                    } else {
                        self.dispatch(Event::Save {
                            document,
                            target: None,
                        });
                    }
                }
            }
            Action::Quit => {
                if self
                    .app
                    .workspace()
                    .documents()
                    .any(|id| self.app.workspace().is_saving(id))
                {
                    self.message = "Save in progress; quit after it completes".into();
                } else if self.app.workspace().documents().any(|id| {
                    self.app
                        .workspace()
                        .editor(id)
                        .unwrap()
                        .model()
                        .document()
                        .is_dirty()
                }) {
                    self.prompt = Some(Prompt::Quit);
                } else {
                    self.quit = true;
                }
            }
            Action::NextView => {
                let ids: Vec<_> = self.app.views().map(|v| v.id).collect();
                if let Some(active) = self.app.active_view() {
                    let index = ids.iter().position(|id| *id == active).unwrap();
                    self.dispatch(Event::Focus(ids[(index + 1) % ids.len()]));
                }
            }
        }
    }
    fn input(&mut self, event: TerminalEvent) {
        self.dirty = true;
        match event {
            TerminalEvent::Key(key) if key.kind != KeyEventKind::Release => {
                if self.prompt.is_some() {
                    if key.code == KeyCode::Esc {
                        self.prompt = None;
                        return;
                    }
                    if matches!(self.prompt, Some(Prompt::Quit)) {
                        if key.code == KeyCode::Char('y') {
                            self.quit = true;
                        }
                        self.prompt = None;
                        return;
                    }
                    if key.code == KeyCode::Enter {
                        let prompt = self.prompt.take().unwrap();
                        match prompt {
                            Prompt::Open(field) if !field.text.is_empty() => {
                                self.dispatch(Event::Open(PathBuf::from(field.text)))
                            }
                            Prompt::Save(document, field) if !field.text.is_empty() => self
                                .dispatch(Event::Save {
                                    document,
                                    target: Some(PathBuf::from(field.text)),
                                }),
                            _ => {}
                        }
                    } else if let Some(Prompt::Open(field) | Prompt::Save(_, field)) =
                        &mut self.prompt
                    {
                        field.key(key);
                    }
                } else if let Some(action) = input::binding(key) {
                    self.message.clear();
                    self.action(action);
                }
            }
            TerminalEvent::Paste(text) => match &mut self.prompt {
                Some(Prompt::Open(field) | Prompt::Save(_, field)) => field.insert(&text),
                Some(Prompt::Quit) => {}
                None => self.edit(Command::InsertText(text)),
            },
            _ => {}
        }
    }
    fn draw(&mut self) -> io::Result<()> {
        let (width, height) = terminal::size()?;
        let frame = layout::frame(&mut self.app, width, height).map_err(io::Error::other)?;
        let mut output = io::stdout().lock();
        queue!(
            output,
            Hide,
            SetAttribute(Attribute::Reset),
            Clear(ClearType::All)
        )?;
        for (y, row) in frame.rows.iter().enumerate() {
            queue!(output, MoveTo(0, y as u16))?;
            for span in row {
                queue!(
                    output,
                    SetAttribute(if span.selected {
                        Attribute::Reverse
                    } else {
                        Attribute::Reset
                    }),
                    Print(&span.text)
                )?;
            }
        }
        queue!(output, SetAttribute(Attribute::Reset))?;
        let mut cursor = frame.cursor;
        if width > 0 && height > 0 {
            if height > 1 {
                queue!(
                    output,
                    MoveTo(0, height - 2),
                    SetAttribute(Attribute::Reverse),
                    Print(layout::plain(&frame.status, 0, usize::from(width))),
                    SetAttribute(Attribute::Reset)
                )?;
            }
            let (footer, prompt_cursor) = match &self.prompt {
                Some(Prompt::Open(field)) => {
                    let text = format!("Open: {}", field.text);
                    let (text, x) =
                        layout::prompt_cursor(&text, 6 + field.cursor, usize::from(width));
                    (text, Some(x))
                }
                Some(Prompt::Save(_, field)) => {
                    let text = format!("Save as: {}", field.text);
                    let (text, x) =
                        layout::prompt_cursor(&text, 9 + field.cursor, usize::from(width));
                    (text, Some(x))
                }
                Some(Prompt::Quit) => ("Unsaved changes: discard and quit? (y/N)".into(), None),
                None => (self.message.clone(), None),
            };
            queue!(
                output,
                MoveTo(0, height - 1),
                Print(layout::plain(&footer, 0, usize::from(width)))
            )?;
            if self.prompt.is_some() {
                cursor = prompt_cursor.map(|x| (x.min(usize::from(width - 1)) as u16, height - 1));
            }
        }
        if let Some((x, y)) = cursor {
            queue!(output, MoveTo(x, y), Show)?;
        }
        output.flush()
    }
}

/// Start the terminal host. File requests run on workers; completion reduction
/// and all editor mutation run on this thread. Starting without a path creates
/// an untitled buffer.
pub fn run(path: Option<PathBuf>) -> io::Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(io::Error::other("interactive editing requires a terminal"));
    }
    let _terminal = Terminal::enter()?;
    let mut host = Host::new();
    if let Some(path) = path {
        host.dispatch(Event::Open(path));
    }
    while !host.quit {
        while let Ok(event) = host.receiver.try_recv() {
            host.dispatch(event);
        }
        host.dispatch(Event::PollFiles);
        if host.dirty {
            host.draw()?;
            host.dirty = false;
        }
        if event::poll(Duration::from_millis(30))? {
            host.input(event::read()?);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{KeyEvent, KeyModifiers};
    fn key(code: KeyCode) -> TerminalEvent {
        TerminalEvent::Key(KeyEvent::new(code, KeyModifiers::NONE))
    }
    #[test]
    fn path_prompt_owns_input_and_stays_bound_to_original_document() {
        let mut host = Host::new();
        let first = host.app.active_view().unwrap();
        let document = host.app.view(first).unwrap().document_id;
        host.action(Action::Save { choose_path: true });
        host.input(TerminalEvent::Paste("目录/file.txt".into()));
        host.dispatch(Event::NewDocument(Language::PlainText));
        let Some(Prompt::Save(target, field)) = &host.prompt else {
            panic!()
        };
        assert_eq!(*target, document);
        assert_eq!(field.text, "目录/file.txt");
        assert!(
            host.app
                .workspace()
                .editor(document)
                .unwrap()
                .state()
                .snapshot()
                .is_empty()
        );
        host.input(key(KeyCode::Esc));
        assert!(host.prompt.is_none());
    }
    #[test]
    fn bracketed_paste_is_one_undoable_edit() {
        let mut host = Host::new();
        host.input(TerminalEvent::Paste("a\r\n中🦀".into()));
        let document = host
            .app
            .view(host.app.active_view().unwrap())
            .unwrap()
            .document_id;
        assert_eq!(
            host.app
                .workspace()
                .editor(document)
                .unwrap()
                .state()
                .snapshot()
                .text(),
            "a\r\n中🦀"
        );
        host.action(Action::Edit(Command::Undo));
        assert!(
            host.app
                .workspace()
                .editor(document)
                .unwrap()
                .state()
                .snapshot()
                .is_empty()
        );
    }
    #[test]
    fn close_rejects_dirty_buffer_and_last_clean_buffer_can_close() {
        let mut host = Host::new();
        host.action(Action::Close);
        assert!(host.app.active_view().is_none());
        host.action(Action::New);
        let view = host.app.active_view().unwrap();
        host.edit(Command::InsertText("unsaved".into()));
        host.action(Action::Close);
        assert_eq!(host.app.active_view(), Some(view));
        assert!(host.message.contains("save before closing"));
        host.edit(Command::Undo);
        host.action(Action::Close);
        assert!(host.app.active_view().is_none());
    }
    #[test]
    fn quit_checks_hidden_documents_and_waits_for_pending_saves() {
        let directory = tempfile::tempdir().unwrap();
        let mut host = Host::new();
        host.edit(Command::InsertText("dirty".into()));
        let document = host
            .app
            .view(host.app.active_view().unwrap())
            .unwrap()
            .document_id;
        host.dispatch(Event::NewDocument(Language::PlainText));
        host.action(Action::Quit);
        assert!(matches!(host.prompt, Some(Prompt::Quit)));
        host.input(key(KeyCode::Esc));
        assert!(!host.quit);
        let update = host
            .app
            .dispatch(Event::Save {
                document,
                target: Some(directory.path().join("a.txt")),
            })
            .unwrap();
        host.action(Action::Quit);
        assert!(host.prompt.is_none());
        assert!(!host.quit);
        assert!(host.message.contains("Save in progress"));
        drop(update);
        host.dispatch(Event::PollFiles);
        host.action(Action::Quit);
        host.input(key(KeyCode::Char('y')));
        assert!(host.quit);
    }
}
