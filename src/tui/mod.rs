//! Minimal terminal host. Key bindings and screen layout adapt the application
//! API; text mutation, history, file identity and sessions stay in lower layers.
mod input;
mod layout;
use crate::interaction::picker::{
    PickerCompletion, PickerEffect, PickerLimits, PickerRunner, PickerSession,
};
use crate::{
    application::{Application, Effect, Event, Update},
    editor::{Command, Language},
    interaction::{
        Input, InputResult, Layer as Prompt, Layers, Presentation, Response, SearchSession,
        TextInput as InputField,
    },
};
use crossterm::{
    cursor::{Hide, MoveTo, Show},
    event::{self, DisableBracketedPaste, EnableBracketedPaste, Event as TerminalEvent},
    execute, queue,
    style::{Attribute, Print, SetAttribute},
    terminal::{self, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen},
};
use input::Action;
enum HostEvent {
    Application(Box<Event>),
    Picker(PickerCompletion),
}
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
struct Host {
    app: Application,
    sender: mpsc::Sender<Event>,
    receiver: mpsc::Receiver<Event>,
    layers: Layers,
    picker: PickerRunner,
    message: String,
    epoch: Instant,
    quit: bool,
    dirty: bool,
}
impl Host {
    fn new() -> io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        let mut host = Self {
            app: Application::default(),
            sender,
            receiver,
            layers: Layers::default(),
            picker: PickerRunner::new()?,
            message: String::new(),
            epoch: Instant::now(),
            quit: false,
            dirty: true,
        };
        host.dispatch(Event::NewDocument(Language::PlainText));
        Ok(host)
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
    fn completion(&mut self, event: HostEvent) {
        match event {
            HostEvent::Application(event) => self.dispatch(*event),
            HostEvent::Picker(completion) => {
                let response = self.layers.picker_finished(completion);
                self.respond(Ok(response));
            }
        }
    }
    fn accept(&mut self, update: Update) {
        let response = self
            .layers
            .observe(&self.app, &update, self.epoch.elapsed());
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
        self.respond(response);
    }
    fn respond(&mut self, response: Result<Response, crate::core::EditError>) {
        match response {
            Ok(response) => {
                self.dirty |= response.redraw;
                self.quit |= response.quit;
                for effect in response.effects {
                    match effect {
                        PickerEffect::Run(task) => {
                            if let Err(error) = self.picker.submit(task) {
                                let response = self.layers.picker_failed(error.to_string());
                                self.dirty |= response.redraw;
                            }
                        }
                        PickerEffect::Cancel(id) => self.picker.cancel(id),
                    }
                }
                for event in response.events {
                    self.dispatch(event);
                }
            }
            Err(error) => {
                if let Ok(response) = self.layers.close(&self.app, self.epoch.elapsed()) {
                    self.respond(Ok(response));
                }
                self.message = error.to_string();
                self.dirty = true;
            }
        }
    }
    fn enter(&mut self, layer: Prompt) {
        let response = self.layers.enter(layer, &self.app, self.epoch.elapsed());
        self.respond(response);
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
            Action::PickFiles => {
                match std::env::current_dir()
                    .and_then(|root| PickerSession::new(root, PickerLimits::default()))
                {
                    Ok(session) => {
                        let response =
                            self.layers
                                .start_picker(session, &self.app, self.epoch.elapsed());
                        self.respond(response);
                    }
                    Err(error) => {
                        self.message = error.to_string();
                        self.dirty = true;
                    }
                }
            }
            Action::Search => {
                if let Some(view) = self.app.active_view() {
                    match SearchSession::new(&self.app, view) {
                        Ok(session) => {
                            self.enter(Prompt::Search {
                                input: InputField::default(),
                                session,
                            });
                        }
                        Err(error) => self.message = error.to_string(),
                    }
                }
            }
            Action::Edit(command) => self.edit(command),
            Action::Open => self.enter(Prompt::Open(InputField::default())),
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
                        self.enter(Prompt::Save(document, InputField::new(&text)));
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
                    self.enter(Prompt::Quit);
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
        if matches!(event, TerminalEvent::Resize(..)) {
            self.dirty = true;
            return;
        }
        let input = match &event {
            TerminalEvent::Key(key) => input::modal_key(*key),
            TerminalEvent::Paste(text) => Input::Paste(text.clone()),
            _ => Input::Unrecognized,
        };
        match self.layers.handle(input, &self.app, self.epoch.elapsed()) {
            Ok(InputResult::Handled(response)) => self.respond(Ok(response)),
            Ok(InputResult::Blocked) => {}
            Err(error) => self.respond(Err(error)),
            Ok(InputResult::Pass) => match event {
                TerminalEvent::Key(key) => {
                    if let Some(action) = input::binding(key) {
                        self.message.clear();
                        self.dirty = true;
                        self.action(action);
                    }
                }
                TerminalEvent::Paste(text) => self.edit(Command::InsertText(text)),
                _ => {}
            },
        }
    }
    fn draw(&mut self) -> io::Result<()> {
        let (width, height) = terminal::size()?;
        let list_rows = usize::from(height.saturating_sub(2)).min(10);
        self.layers.resize_picker(list_rows);
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
            draw_spans(&mut output, row)?;
        }
        if let Some(Prompt::Picker(session)) = self.layers.active() {
            let start = usize::from(height.saturating_sub(2)) - list_rows;
            let rows = &session.results().rows;
            for offset in 0..list_rows {
                queue!(
                    output,
                    MoveTo(0, (start + offset) as u16),
                    Clear(ClearType::CurrentLine)
                )?;
                if let Some(row) = rows.get(session.list().first_visible() + offset) {
                    let spans =
                        layout::candidate_row(row, session.list().selected(), usize::from(width));
                    draw_spans(&mut output, &spans)?;
                }
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
            let presentation = self.layers.active().map_or_else(
                || Presentation {
                    text: self.message.clone(),
                    cursor: None,
                    selection: 0..0,
                },
                Prompt::presentation,
            );
            let (footer, prompt_cursor) = layout::prompt_row(&presentation, usize::from(width));
            queue!(output, MoveTo(0, height - 1))?;
            draw_spans(&mut output, &footer)?;
            if self.layers.active().is_some() {
                cursor = prompt_cursor.map(|x| (x.min(usize::from(width - 1)) as u16, height - 1));
            }
        }
        if let Some((x, y)) = cursor {
            queue!(output, MoveTo(x, y), Show)?;
        }
        output.flush()
    }
}

fn draw_spans(output: &mut impl Write, spans: &[layout::Span]) -> io::Result<()> {
    for span in spans {
        queue!(output, SetAttribute(Attribute::Reset))?;
        if span.selected {
            queue!(output, SetAttribute(Attribute::Reverse))?;
        }
        if span.matched {
            queue!(output, SetAttribute(Attribute::Underlined))?;
        }
        queue!(output, Print(&span.text))?;
    }
    queue!(output, SetAttribute(Attribute::Reset))
}

/// Start the terminal host. File requests run on workers; completion reduction
/// and all editor mutation run on this thread. Starting without a path creates
/// an untitled buffer.
pub fn run(path: Option<PathBuf>) -> io::Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(io::Error::other("interactive editing requires a terminal"));
    }
    let _terminal = Terminal::enter()?;
    let mut host = Host::new()?;
    if let Some(path) = path {
        host.dispatch(Event::Open(path));
    }
    while !host.quit {
        for _ in 0..8 {
            let Ok(event) = host.receiver.try_recv() else {
                break;
            };
            host.completion(HostEvent::Application(Box::new(event)));
        }
        for _ in 0..8 {
            match host.picker.poll() {
                Ok(Some(completion)) => host.completion(HostEvent::Picker(completion)),
                Ok(None) => break,
                Err(error) => {
                    let response = host.layers.picker_failed(error.to_string());
                    host.respond(Ok(response));
                    break;
                }
            }
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
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
    fn key(code: KeyCode) -> TerminalEvent {
        TerminalEvent::Key(KeyEvent::new(code, KeyModifiers::NONE))
    }
    #[test]
    fn path_prompt_owns_input_and_stays_bound_to_original_document() {
        let mut host = Host::new().unwrap();
        let first = host.app.active_view().unwrap();
        let document = host.app.view(first).unwrap().document_id;
        host.action(Action::Save { choose_path: true });
        host.input(TerminalEvent::Paste("目录/file.txt".into()));
        host.dispatch(Event::NewDocument(Language::PlainText));
        let Some(Prompt::Save(target, field)) = host.layers.active() else {
            panic!()
        };
        assert_eq!(*target, document);
        assert_eq!(field.text(), "目录/file.txt");
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
        assert!(host.layers.active().is_none());
    }
    #[test]
    fn bracketed_paste_is_one_undoable_edit() {
        let mut host = Host::new().unwrap();
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
        let mut host = Host::new().unwrap();
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
        let mut host = Host::new().unwrap();
        host.edit(Command::InsertText("dirty".into()));
        let document = host
            .app
            .view(host.app.active_view().unwrap())
            .unwrap()
            .document_id;
        host.dispatch(Event::NewDocument(Language::PlainText));
        host.action(Action::Quit);
        assert!(matches!(host.layers.active(), Some(Prompt::Quit)));
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
        assert!(host.layers.active().is_none());
        assert!(!host.quit);
        assert!(host.message.contains("Save in progress"));
        drop(update);
        host.dispatch(Event::PollFiles);
        host.action(Action::Quit);
        host.input(key(KeyCode::Char('y')));
        assert!(host.quit);
    }
    #[test]
    fn search_input_is_modal_and_cancel_restores_selection() {
        let mut host = Host::new().unwrap();
        host.edit(Command::InsertText("one two one".into()));
        host.edit(Command::SetSelection(crate::core::Selection::caret(0)));
        let view = host.app.active_view().unwrap();
        let state = |host: &Host| {
            let v = host.app.view(view).unwrap();
            host.app
                .workspace()
                .editor(v.document_id)
                .unwrap()
                .model()
                .session(v.session_id)
                .unwrap()
                .selection()
        };
        host.input(TerminalEvent::Key(KeyEvent::new(
            KeyCode::Char('f'),
            KeyModifiers::CONTROL,
        )));
        host.input(TerminalEvent::Paste("one".into()));
        assert_eq!(state(&host), crate::core::Selection { anchor: 0, head: 3 });
        host.input(key(KeyCode::F(3)));
        assert_eq!(
            state(&host),
            crate::core::Selection {
                anchor: 8,
                head: 11
            }
        );
        host.input(TerminalEvent::Key(KeyEvent::new(
            KeyCode::Char('z'),
            KeyModifiers::CONTROL,
        )));
        assert_eq!(
            state(&host),
            crate::core::Selection {
                anchor: 8,
                head: 11
            }
        );
        host.input(key(KeyCode::Esc));
        assert_eq!(state(&host), crate::core::Selection::caret(0));
        assert!(host.layers.active().is_none());
    }
    #[test]
    fn search_confirmation_repeats_in_editor_and_paste_replaces_match() {
        let mut host = Host::new().unwrap();
        host.edit(Command::InsertText("one two one".into()));
        host.edit(Command::SetSelection(crate::core::Selection::caret(0)));
        host.action(Action::Search);
        host.input(TerminalEvent::Paste("one".into()));
        host.input(key(KeyCode::Enter));
        host.input(key(KeyCode::F(3)));
        host.input(TerminalEvent::Paste("中".into()));
        let view = host.app.view(host.app.active_view().unwrap()).unwrap();
        assert_eq!(
            host.app
                .workspace()
                .editor(view.document_id)
                .unwrap()
                .state()
                .snapshot()
                .text(),
            "one two 中"
        );
    }
    #[test]
    fn prompt_selection_cursor_and_modifier_events_have_distinct_effects() {
        let mut host = Host::new().unwrap();
        host.action(Action::Open);
        host.input(TerminalEvent::Paste("路径/file".into()));
        host.dirty = false;
        host.input(TerminalEvent::Key(KeyEvent::new(
            KeyCode::Enter,
            KeyModifiers::CONTROL,
        )));
        assert!(host.layers.active().is_some());
        assert!(!host.dirty);
        host.input(TerminalEvent::Key(KeyEvent::new(
            KeyCode::Left,
            KeyModifiers::SHIFT,
        )));
        assert!(host.dirty);
        let Some(Prompt::Open(field)) = host.layers.active() else {
            panic!()
        };
        assert_eq!(&field.text()[field.selection().range()], "e");
        host.input(TerminalEvent::Paste("X".into()));
        let Some(Prompt::Open(field)) = host.layers.active() else {
            panic!()
        };
        assert_eq!(field.text(), "路径/filX");
        host.dirty = false;
        let mut release = KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE);
        release.kind = crossterm::event::KeyEventKind::Release;
        host.input(TerminalEvent::Key(release));
        assert!(!host.dirty);
        host.input(key(KeyCode::Esc));
        assert!(host.layers.active().is_none());
        assert!(host.dirty);
    }
}
