//! A small command prompt for built-in file and buffer workflows.
use super::{
    Command, Input, Presentation, Response, TextInput,
    session::{Transition, edit_field, field_presentation},
};
#[derive(Default)]
pub struct ExSession {
    input: TextInput,
    error: Option<String>,
}
impl ExSession {
    pub(super) fn handle(&mut self, input: Input) -> Transition {
        match input {
            Input::Cancel => Transition::close(),
            Input::Confirm => {
                let text = self.input.text().trim();
                if text.is_empty() {
                    return Transition::close();
                }
                let (name, argument) = text
                    .split_once(char::is_whitespace)
                    .map_or((text, ""), |(a, b)| (a, b.trim()));
                let command = match (name, argument) {
                    ("w" | "write", "") => Some(Command::Save { choose_path: false }),
                    ("w" | "write", path) => Some(Command::SavePath(path.into())),
                    ("e" | "edit", "") => Some(Command::Reload),
                    ("e" | "edit", path) => Some(Command::OpenPath(path.into())),
                    ("open", "") => Some(Command::Open),
                    ("saveas", "") => Some(Command::Save { choose_path: true }),
                    ("saveas", path) => Some(Command::SavePath(path.into())),
                    ("q" | "quit", "") => Some(Command::Quit),
                    ("wq" | "x", "") => Some(Command::WriteQuit),
                    ("bd" | "bdelete", "") => Some(Command::Close),
                    ("b" | "buffer" | "buffers" | "ls" | "files", "") => {
                        Some(Command::SwitchBuffer)
                    }
                    ("bn" | "bnext", "") => Some(Command::NextView),
                    ("new" | "enew", "") => Some(Command::New),
                    ("project", "") => Some(Command::PickFiles),
                    ("help", "") => Some(Command::Help),
                    ("replace", "") => Some(Command::Replace),
                    ("goto", "") => Some(Command::Goto),
                    (line, "") if line.parse::<usize>().is_ok_and(|n| n > 0) => {
                        Some(Command::Edit(crate::editor::Command::Goto {
                            line: line.parse::<usize>().unwrap() - 1,
                            column: 0,
                        }))
                    }
                    (name, "") => Some(Command::Named(name.into())),
                    _ => None,
                };
                if let Some(command) = command {
                    Transition::finished(Response {
                        commands: vec![command],
                        redraw: true,
                        ..Response::default()
                    })
                } else {
                    self.error = Some("Unsupported command".into());
                    Transition::redraw()
                }
            }
            input => match edit_field(&mut self.input, input) {
                Some(update) if update.text_changed || update.selection_changed => {
                    self.error = None;
                    Transition::redraw()
                }
                _ => Transition::Blocked,
            },
        }
    }
    pub(super) fn presentation(&self) -> Presentation {
        let mut p = field_presentation(":".into(), &self.input);
        if let Some(error) = &self.error {
            p.text.push_str(&format!(" [{error}]"));
        }
        p
    }
}
