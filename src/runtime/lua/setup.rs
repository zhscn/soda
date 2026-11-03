//! `soda` functions that extend the editor: key bindings, hooks, commands
//! and completion sources.
use super::{Host, Runtime};
use crate::interaction::{Command, KeyStroke, key_notation};
use mlua::{Function, Scope, Table, Value};
use std::cell::RefCell;

pub(super) fn register<'scope, 'r: 'scope>(
    scope: &'scope Scope<'scope, '_>,
    soda: &Table,
    runtime: &'scope RefCell<&'r mut Runtime>,
    host: &'scope Host,
) -> mlua::Result<()> {
    soda.set(
        "language",
        scope.create_function(|_, (name, language): (String, String)| {
            runtime
                .borrow_mut()
                .edit_event(crate::application::Event::MapLanguage { name, language })
        })?,
    )?;
    soda.set(
        "face",
        scope.create_function(|_, (name, spec): (String, Value)| {
            let spec = match spec {
                Value::Nil => None,
                Value::String(spec) => Some(spec.to_str()?.to_owned()),
                // `{ fg = "#rrggbb", bold = true }` reads as the words.
                Value::Table(table) => {
                    let mut words = vec![];
                    for side in ["fg", "bg"] {
                        if let Some(color) = table.get::<Option<String>>(side)? {
                            words.push(format!("{side}:{color}"));
                        }
                    }
                    for attribute in [
                        "bold",
                        "italic",
                        "underline",
                        "dim",
                        "reverse",
                        "strikethrough",
                        "plain",
                    ] {
                        if table.get::<Option<bool>>(attribute)? == Some(true) {
                            words.push(attribute.to_owned());
                        }
                    }
                    Some(words.join(" "))
                }
                _ => return Err(mlua::Error::runtime("a face is a table, a string or nil")),
            };
            let spec = spec
                .map(|spec| crate::application::faces::FaceSpec::parse(&spec))
                .transpose()
                .map_err(mlua::Error::runtime)?;
            runtime
                .borrow_mut()
                .edit_event(crate::application::Event::SetFace { name, spec })
        })?,
    )?;
    soda.set(
        "map",
        scope.create_function(
            |_, (keymap, keys, target, doc): (String, String, Value, Option<String>)| {
                let keys = KeyStroke::parse_sequence(&keys).map_err(mlua::Error::runtime)?;
                // A function is kept and called by number; its label is
                // what it says it does.
                let (target, label) = match target {
                    Value::String(line) => (line.to_str()?.to_owned(), doc),
                    Value::Function(function) if keymap != "prompt" => {
                        let id = host.keep(function)?;
                        let label = doc.unwrap_or_else(|| "Lua function".into());
                        (format!("lua-call {id}"), Some(label))
                    }
                    _ => {
                        return Err(mlua::Error::runtime(
                            "soda.map binds a command line, or a function outside prompt",
                        ));
                    }
                };
                runtime
                    .borrow_mut()
                    .layers
                    .configure(Command::Map {
                        keymap,
                        keys,
                        target,
                        label,
                    })
                    .map_err(mlua::Error::runtime)
            },
        )?,
    )?;
    soda.set(
        "unmap",
        scope.create_function(|_, (keymap, keys): (String, String)| {
            let keys = KeyStroke::parse_sequence(&keys).map_err(mlua::Error::runtime)?;
            runtime
                .borrow_mut()
                .layers
                .configure(Command::Unmap { keymap, keys })
                .map_err(mlua::Error::runtime)
        })?,
    )?;
    soda.set(
        "keymap",
        scope.create_function(|_, (name, options): (String, Option<Table>)| {
            let (server, doc) = match &options {
                Some(options) => (
                    options.get::<Option<String>>("server")?,
                    options.get::<Option<String>>("doc")?,
                ),
                None => (None, None),
            };
            // Only server keymaps are defined; a language's needs no definition.
            let Some(server) = server else {
                return Err(mlua::Error::runtime(
                    "soda.keymap needs server = NAME, or \"*\" for any server",
                ));
            };
            let scope = crate::interaction::Scope::Server((server != "*").then_some(server));
            let doc = doc.unwrap_or_else(|| format!("Keys of the {name} keymap"));
            runtime
                .borrow_mut()
                .layers
                .define_keymap(&name, scope, doc)
                .map_err(mlua::Error::runtime)
        })?,
    )?;
    soda.set(
        "bindings",
        scope.create_function(|lua, keymap: String| {
            let bindings = runtime.borrow().layers.bindings(&keymap);
            let bindings = bindings
                .ok_or_else(|| mlua::Error::runtime(format!("unknown keymap: {keymap}")))?;
            let out = lua.create_table()?;
            for (keys, label) in bindings {
                let binding = lua.create_table()?;
                binding.set("keys", key_notation(&keys))?;
                binding.set("command", label)?;
                out.push(binding)?;
            }
            Ok(out)
        })?,
    )?;
    soda.set(
        "hook",
        scope.create_function(|_, (event, filter, function): (String, String, Function)| {
            let id = host.keep(function)?;
            runtime
                .borrow_mut()
                .layers
                .add_hook(&event, &filter, hook_command(id))
                .map_err(mlua::Error::runtime)?;
            Ok(id)
        })?,
    )?;
    soda.set(
        "unhook",
        scope.create_function(|_, id: u64| {
            let removed = runtime
                .borrow_mut()
                .layers
                .remove_hook_command(&hook_command(id));
            if removed {
                host.callbacks()?.set(id, Value::Nil)?;
            }
            Ok(removed)
        })?,
    )?;
    soda.set(
        "define_command",
        scope.create_function(
            |_, (name, second, third, options): (String, Value, Option<Function>, Option<Table>)| {
                // `(name, doc, fn)` reads like a docstring;
                // `(name, fn)` has none.
                let slots = options
                    .and_then(|options| options.get::<Option<Table>>("args").transpose())
                    .transpose()?
                    .map(|args| slots(&args))
                    .transpose()?;
                let (doc, function) = match (second, third) {
                    (Value::String(doc), Some(function)) => {
                        (Some(doc.to_str()?.to_owned()), function)
                    }
                    (Value::Function(function), None) => (None, function),
                    _ => {
                        return Err(mlua::Error::runtime(
                            "define_command takes a name, a description and a function",
                        ));
                    }
                };
                let id = host.keep(function)?;
                // The body names a function by number, which says
                // nothing to a reader; the name does.
                let doc = doc.unwrap_or_else(|| name.clone());
                runtime
                    .borrow_mut()
                    .layers
                    .configure(Command::Define {
                        name,
                        body: format!("lua-call {id} %arg{{@}}"),
                        doc: Some(doc),
                        slots,
                    })
                    .map_err(mlua::Error::runtime)
            },
        )?,
    )?;
    soda.set(
        "completion_source",
        scope.create_function(
            |_, (triggers, function, resolve): (String, Function, Option<Function>)| {
                let id = host.keep(function)?;
                let resolve = resolve.map(|resolve| host.keep(resolve)).transpose()?;
                runtime.borrow_mut().layers.completion_source(
                    id,
                    triggers.chars().collect(),
                    resolve,
                );
                Ok(())
            },
        )?,
    )?;
    Ok(())
}
/// The command a Lua hook runs: its function, with the event's parameter.
fn hook_command(id: u64) -> String {
    format!("lua-call {id} %val{{hook}}")
}
/// The argument places of a Lua command, from `args`: each a kind such as
/// `"file"`, or a table with `name`, `kind` or `choices`, and `optional`.
/// Commands live as long as the editor, so their slots are leaked once
/// for each definition.
fn slots(args: &Table) -> mlua::Result<&'static [crate::interaction::Slot]> {
    use crate::interaction::{Choice, Slot, SlotKind};
    let leak = |text: String| -> &'static str { Box::leak(text.into_boxed_str()) };
    let kind = |name: &str| -> mlua::Result<SlotKind> {
        Ok(match name {
            "file" => SlotKind::File,
            "path" => SlotKind::Path,
            "buffer" => SlotKind::Buffer,
            "option" => SlotKind::Option,
            "face" => SlotKind::Face,
            "language" => SlotKind::Language,
            "recent" => SlotKind::Recent,
            "symbol" => SlotKind::Symbol,
            "word" => SlotKind::Word,
            "rest" => SlotKind::Rest,
            name => {
                return Err(mlua::Error::runtime(format!(
                    "unknown argument kind {name}: use file, path, buffer, option, face, language, recent, symbol, word, rest or choices"
                )));
            }
        })
    };
    let mut out = vec![];
    for arg in args.sequence_values::<Value>() {
        let slot = match arg? {
            Value::String(name) => {
                let name = name.to_str()?.to_owned();
                Slot {
                    kind: kind(&name)?,
                    name: leak(name.to_uppercase()),
                    required: true,
                }
            }
            Value::Table(arg) => {
                let kind = match arg.get::<Option<Vec<Value>>>("choices")? {
                    Some(choices) => {
                        let choices = choices
                            .into_iter()
                            .map(|choice| {
                                // A word, or `{ word, doc }`.
                                let (word, doc) = match choice {
                                    Value::Table(pair) => {
                                        (pair.get(1)?, pair.get::<Option<String>>(2)?)
                                    }
                                    Value::String(word) => (word.to_str()?.to_owned(), None),
                                    _ => {
                                        return Err(mlua::Error::runtime(
                                            "a choice is a word or { word, doc }",
                                        ));
                                    }
                                };
                                Ok(Choice {
                                    word: leak(word),
                                    key: None,
                                    doc: leak(doc.unwrap_or_default()),
                                })
                            })
                            .collect::<mlua::Result<Vec<_>>>()?;
                        SlotKind::Choice(Box::leak(choices.into_boxed_slice()))
                    }
                    None => kind(&arg.get::<Option<String>>("kind")?.unwrap_or("rest".into()))?,
                };
                Slot {
                    name: leak(arg.get::<Option<String>>("name")?.unwrap_or("ARG".into())),
                    kind,
                    required: !arg.get::<Option<bool>>("optional")?.unwrap_or(false),
                }
            }
            _ => return Err(mlua::Error::runtime("an argument is a kind or a table")),
        };
        out.push(slot);
    }
    Ok(Box::leak(out.into_boxed_slice()))
}
