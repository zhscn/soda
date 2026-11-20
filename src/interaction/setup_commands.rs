//! Configures bindings, options and document annotations.
use super::{Command, Layers, Message, Response, commands::active};
use crate::application::{Application, Event};

#[derive(Clone, Debug)]
pub enum SetupCommand {
    /// Binds keys in a key table: a context, a document keymap or a
    /// language's keymap, by name.
    Map {
        keymap: String,
        keys: Vec<super::KeyStroke>,
        target: String,
        /// What help and key hints show; `None` shows the target.
        label: Option<String>,
        /// A plugin's binding: a default, which user bindings shadow and
        /// which `unmap` does not take away.
        default: bool,
    },
    Unmap {
        keymap: String,
        keys: Vec<super::KeyStroke>,
    },
    Define {
        name: String,
        body: String,
        /// What help and key hints show; `None` shows the body.
        doc: Option<String>,
        /// What the command line completes its arguments as; `None` takes
        /// them as text.
        slots: Option<&'static [super::Slot]>,
    },
    Hook {
        event: &'static str,
        filter: String,
        command: String,
    },
    Unhook {
        event: &'static str,
        filter: Option<String>,
    },
    /// Highlights a pattern everywhere, or in the current document.
    Highlight {
        local: bool,
        face: String,
        pattern: regex::Regex,
    },
    /// Removes the highlights of a pattern, or all of them.
    Unhighlight(Option<String>),
    /// Flags zero-based lines of the current document in a group.
    FlagLines {
        group: String,
        face: String,
        sign: String,
        lines: Vec<usize>,
    },
    /// Removes a group's flags, or all, from the current document.
    UnflagLines(Option<String>),
    /// Sets an option globally, or for the current document.
    SetOption {
        local: bool,
        name: &'static str,
        value: crate::options::Value,
    },
    /// Drops the current document's own value of an option.
    UnsetOption(&'static str),
    /// Gives files of a name or extension a language.
    MapLanguage { name: String, language: String },
    /// Sets a face over the theme; `None` gives it back.
    Face {
        name: String,
        spec: Option<crate::application::faces::FaceSpec>,
    },
    /// Sets where documents of a kind are shown.
    Display {
        kind: String,
        placement: crate::application::Placement,
    },
}

impl Layers {
    pub(super) fn execute_setup(
        &mut self,
        command: SetupCommand,
        mut response: Response,
        app: &Application,
    ) -> Response {
        match command {
            command @ (SetupCommand::Map { .. }
            | SetupCommand::Unmap { .. }
            | SetupCommand::Define { .. }
            | SetupCommand::Hook { .. }
            | SetupCommand::Unhook { .. }) => {
                if let Err(error) = self.configure_setup(command) {
                    response.message = Message::Set(error);
                    response.failed = true;
                }
            }
            SetupCommand::Highlight {
                local,
                face,
                pattern,
            } => {
                let document = active(app).map(|view| view.document_id);
                if local && document.is_none() {
                    response.message = Message::Set("No document to highlight in".into());
                } else {
                    let face = if face == "mark" {
                        Ok(None)
                    } else {
                        app.faces()
                            .resolve(&face)
                            .map(Some)
                            .ok_or_else(|| format!("unknown face {face}"))
                    };
                    match face {
                        Ok(face) => response.events.push(Event::Highlight {
                            document: document.filter(|_| local),
                            mark: matches!(face, None | Some(crate::application::Face::Mark(_))),
                            face,
                            pattern,
                        }),
                        Err(error) => {
                            response.failed = true;
                            response.message = Message::Set(error);
                        }
                    }
                }
            }
            SetupCommand::Unhighlight(pattern) => {
                let document = active(app).map(|view| view.document_id);
                response
                    .events
                    .push(Event::Unhighlight { document, pattern });
            }
            SetupCommand::FlagLines {
                group,
                face,
                sign,
                lines,
            } => {
                let flag = app
                    .faces()
                    .resolve(&face)
                    .ok_or_else(|| {
                        if face == "mark" {
                            "flags need a face".to_owned()
                        } else {
                            format!("unknown face {face}")
                        }
                    })
                    .and_then(|face| crate::application::Flag::new(face, &sign));
                match (flag, active(app)) {
                    (Ok(flag), Some(view)) => response.events.push(Event::Flag {
                        document: view.document_id,
                        group,
                        flag,
                        lines,
                    }),
                    (Err(error), _) => {
                        response.failed = true;
                        response.message = Message::Set(error);
                    }
                    (Ok(_), None) => response.message = Message::Set("No document to flag".into()),
                }
            }
            SetupCommand::UnflagLines(group) => {
                if let Some(view) = active(app) {
                    response.events.push(Event::Unflag {
                        document: view.document_id,
                        group,
                    });
                }
            }
            SetupCommand::SetOption { local, name, value } => {
                let document = active(app).map(|view| view.document_id);
                let scope = match (local, document) {
                    (false, _) => Some(crate::options::Scope::Global),
                    (true, Some(document)) => Some(crate::options::Scope::Document(document)),
                    (true, None) => None,
                };
                match scope {
                    Some(scope) => response
                        .events
                        .push(Event::SetOption { scope, name, value }),
                    None => response.message = Message::Set("No document to set it for".into()),
                }
            }
            SetupCommand::UnsetOption(name) => {
                if let Some(view) = active(app) {
                    response.events.push(Event::UnsetOption {
                        document: view.document_id,
                        name,
                    });
                }
            }
            SetupCommand::Display { kind, placement } => {
                response.events.push(Event::SetDisplay { kind, placement })
            }
            SetupCommand::Face { name, spec } => {
                response.events.push(Event::SetFace { name, spec })
            }
            SetupCommand::MapLanguage { name, language } => {
                response.events.push(Event::MapLanguage { name, language })
            }
        }
        response
    }
}
impl Layers {
    /// Applies a configuration command: `map`, `unmap` or `define-command`.
    pub fn configure(&mut self, command: Command) -> Result<(), String> {
        let Command::Setup(command) = command else {
            return Err("only map, unmap, define-command, hook and unhook are allowed here".into());
        };
        self.configure_setup(command)
    }

    fn configure_setup(&mut self, command: SetupCommand) -> Result<(), String> {
        self.keys.sequence.clear();
        self.modal.clear();
        let table = |keymap: &mut super::Keymap, name: &str| {
            keymap
                .table(name)
                .ok_or_else(|| format!("unknown keymap: {name}"))
        };
        match command {
            SetupCommand::Map {
                keymap,
                keys,
                target,
                ..
            } if keymap == "prompt" => {
                let input = super::keymap::prompt_action(target.trim())
                    .ok_or_else(|| format!("unknown prompt action: {target}"))?;
                let [key] = keys[..] else {
                    return Err("prompt bindings use a single key".into());
                };
                self.keys
                    .keymap
                    .bind_input(key, input, target)
                    .map_err(|e| e.to_string())
            }
            SetupCommand::Map {
                keymap,
                keys,
                target,
                label,
                default,
            } => {
                if !self.registry.knows(&target) {
                    return Err(format!("unknown command: {target}"));
                }
                let table = table(&mut self.keys.keymap, &keymap)?;
                let label = label.unwrap_or_else(|| target.clone());
                let command = Command::Named(target);
                if default {
                    self.keys.keymap.bind_default(table, &keys, command, label)
                } else {
                    self.keys.keymap.bind(table, &keys, command, label)
                }
                .map_err(|e| e.to_string())
            }
            SetupCommand::Unmap { keymap, keys } => {
                let table = table(&mut self.keys.keymap, &keymap)?;
                self.keys
                    .keymap
                    .unbind(table, &keys)
                    .map_err(|e| e.to_string())
            }
            SetupCommand::Define {
                name,
                body,
                doc,
                slots,
            } => self.registry.define(name, body, doc, slots),
            SetupCommand::Hook {
                event,
                filter,
                command,
            } => {
                if !self.registry.knows(&command) {
                    return Err(format!("unknown command: {command}"));
                }
                self.hooks
                    .add(super::hooks::Hook::new(event, &filter, command)?);
                Ok(())
            }
            SetupCommand::Unhook { event, filter } => {
                match self.hooks.remove(event, filter.as_deref()) {
                    0 => Err(format!("no {event} hook to remove")),
                    _ => Ok(()),
                }
            }
            _ => Err("only map, unmap, define-command, hook and unhook are allowed here".into()),
        }
    }
}
