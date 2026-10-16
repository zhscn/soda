//! Owner-thread command loop shared by frontends. It owns application and modal
//! state, reduces every update in order, and executes bounded background tasks.
use crate::{
    application::{Application, Event, Operation, Update, ViewId},
    core::{ByteOffset, EditError},
    files::{FileCompletion, FileRunner, paths::PathRunner},
    interaction::{
        Command, InputResult, Layer, Layers, Message, Response, UserInput,
        picker::{PickerEffect, PickerRunner},
    },
};
use std::{
    io,
    path::PathBuf,
    time::{Duration, Instant},
};

pub struct Runtime {
    // Workers drop before the application so in-progress file writes can finish.
    files: FileRunner,
    picker: PickerRunner,
    paths: PathRunner,
    app: Application,
    layers: Layers,
    file_root: PathBuf,
    message: String,
    epoch: Instant,
    quit: bool,
    dirty: bool,
}
impl Runtime {
    pub fn new(file_root: PathBuf) -> io::Result<Self> {
        Self::with_application(Application::default(), file_root)
    }
    pub fn with_application(app: Application, file_root: PathBuf) -> io::Result<Self> {
        if !file_root.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Runtime requires an absolute file root",
            ));
        }
        Ok(Self {
            files: FileRunner::new()?,
            picker: PickerRunner::new()?,
            paths: PathRunner::new()?,
            app,
            layers: Layers::default(),
            file_root,
            message: String::new(),
            epoch: Instant::now(),
            quit: false,
            dirty: true,
        })
    }
    pub fn start(&mut self, path: Option<PathBuf>) {
        self.command(Command::New);
        if let Some(path) = path {
            self.dispatch(Event::Open(path));
        }
    }
    pub fn app(&self) -> &Application {
        &self.app
    }
    pub fn layer(&self) -> Option<&Layer> {
        self.layers.active()
    }
    pub fn edit_mode(&self) -> crate::interaction::EditMode {
        self.layers.edit_mode()
    }
    pub fn input_hint(&self) -> String {
        self.layers.input_hint()
    }
    pub fn message(&self) -> &str {
        &self.message
    }
    pub fn quit_requested(&self) -> bool {
        self.quit
    }
    pub fn take_redraw(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }
    pub fn resize(&mut self, editor_rows: usize, picker_rows: usize) {
        self.layers.set_page_rows(editor_rows);
        self.layers.resize_help(editor_rows);
        self.layers.resize_picker(picker_rows);
        self.dirty = true;
    }
    /// Layout feedback is applied through the same update path as commands.
    /// Modal surfaces that hide the editing cursor preserve its viewport.
    pub fn update_viewport(&mut self, view: ViewId, anchor: ByteOffset, horizontal_column: usize) {
        if matches!(
            self.layer(),
            None | Some(Layer::Search { .. } | Layer::Replace(_))
        ) {
            self.dispatch(Event::SetViewport {
                view,
                anchor,
                horizontal_column,
            });
        }
    }
    pub fn input(&mut self, input: UserInput) {
        self.input_at(input, self.epoch.elapsed());
    }
    pub fn input_at(&mut self, input: UserInput, time: Duration) {
        let result = self
            .layers
            .route_input(input, &self.app, time, &self.file_root);
        self.input_result(result, time);
    }
    pub fn command(&mut self, command: Command) {
        self.command_at(command, self.epoch.elapsed());
    }
    pub fn command_at(&mut self, command: Command, time: Duration) {
        let result = self
            .layers
            .execute(command, &self.app, time, &self.file_root);
        self.input_result(result, time);
    }
    fn input_result(&mut self, result: Result<InputResult, EditError>, time: Duration) {
        match result {
            Ok(InputResult::Handled(response)) => {
                self.respond(response, time);
            }
            Ok(InputResult::Pass | InputResult::Blocked) => {}
            Err(error) => self.interaction_failed(error, time),
        }
    }
    /// Returns false on failure. A response batch stops at its first failed
    /// event; preceding events are committed and their updates already observed.
    pub fn dispatch(&mut self, event: Event) -> bool {
        let time = match &event {
            Event::Edit { time, .. } | Event::Clipboard { time, .. } => *time,
            _ => self.epoch.elapsed(),
        };
        self.reduce(event, time)
    }
    fn reduce(&mut self, event: Event, time: Duration) -> bool {
        let operation = event.operation();
        match self.app.dispatch(event) {
            Ok(update) => self.accept(update, time),
            Err(error) => {
                if !matches!(
                    (&operation, &error),
                    (
                        Operation::Open { request: Some(_) },
                        crate::application::Error::File(crate::files::FileError::StaleCompletion)
                    )
                ) {
                    self.message = error.to_string();
                    let response = self
                        .layers
                        .application_failed(operation, self.message.clone());
                    self.respond(response, time);
                    self.dirty = true;
                }
                false
            }
        }
    }
    fn accept(&mut self, update: Update, time: Duration) -> bool {
        let response = self.layers.observe(&self.app, &update, time);
        self.dirty |= update.active_changed
            || !update.changed_views.is_empty()
            || !update.closed_views.is_empty()
            || !update.files.is_empty()
            || !update.effects.is_empty();
        let reloaded = update
            .edit
            .as_ref()
            .and_then(|edit| edit.document.as_ref())
            .is_some_and(|document| document.origin == crate::editor::EditOrigin::Reload);
        for result in update.files {
            self.message = match result.result {
                Ok(file) => format!(
                    "{} {}{}",
                    if reloaded { "Reloaded" } else { "Saved" },
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
            let operation = effect.key().into();
            if let Err(error) = self
                .files
                .submit(self.app.workspace().service().clone(), effect)
            {
                let error = error.to_string();
                let response = self.layers.application_failed(operation, error.clone());
                self.respond(response, time);
                self.dirty = true;
                // Rejected requests have been dropped and queued cancellation.
                self.reduce(Event::PollFiles, time);
                self.message = error;
            }
        }
        match response {
            Ok(response) => self.respond(response, time),
            Err(error) => {
                self.interaction_failed(error, time);
                false
            }
        }
    }
    fn respond(&mut self, response: Response, time: Duration) -> bool {
        match response.message {
            Message::Keep => {}
            Message::Clear => self.message.clear(),
            Message::Set(message) => self.message = message,
        }
        self.dirty |= response.redraw;
        for request in response.path_requests {
            self.paths.submit(request);
        }
        for effect in response.effects {
            match effect {
                PickerEffect::Run(task) => {
                    if let Err(error) = self.picker.submit(task) {
                        let response = self.layers.picker_failed(error.to_string());
                        self.respond(response, time);
                    }
                }
                PickerEffect::Cancel(id) => self.picker.cancel(id),
            }
        }
        for event in response.events {
            if !self.reduce(event, time) {
                return false;
            }
        }
        self.quit |= response.quit;
        true
    }
    fn interaction_failed(&mut self, error: EditError, time: Duration) {
        if let Ok(response) = self.layers.close(&self.app, time) {
            self.respond(response, time);
        }
        self.message = error.to_string();
        self.dirty = true;
    }
    /// Bounded completion reduction prevents workers from monopolizing input.
    pub fn poll(&mut self) {
        for _ in 0..8 {
            match self.files.poll() {
                Ok(Some(FileCompletion::Open(completion))) => {
                    self.dispatch(Event::OpenFinished(completion));
                }
                Ok(Some(FileCompletion::Save(completion))) => {
                    self.dispatch(Event::SaveFinished(completion));
                }
                Ok(Some(FileCompletion::Failed { key, error })) => {
                    self.dispatch(Event::PollFiles);
                    let operation = key.into();
                    let response = self.layers.application_failed(operation, error.clone());
                    self.respond(response, self.epoch.elapsed());
                    self.message = error;
                    self.dirty = true;
                }
                Ok(None) => break,
                Err(error) => {
                    self.message = error.to_string();
                    self.dirty = true;
                    break;
                }
            }
        }
        for _ in 0..8 {
            match self.picker.poll() {
                Ok(Some(completion)) => {
                    let response = self.layers.picker_finished(completion);
                    self.respond(response, self.epoch.elapsed());
                }
                Ok(None) => break,
                Err(error) => {
                    let response = self.layers.picker_failed(error.to_string());
                    self.respond(response, self.epoch.elapsed());
                    break;
                }
            }
        }
        for _ in 0..8 {
            let Some(completion) = self.paths.poll() else {
                break;
            };
            let response = self.layers.path_finished(completion);
            self.respond(response, self.epoch.elapsed());
        }
        self.dispatch(Event::PollFiles);
    }
}

#[cfg(test)]
mod tests;
