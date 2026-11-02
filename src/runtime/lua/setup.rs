//! `soda` functions that extend the editor: key bindings, hooks, commands
//! and completion sources.
use super::{Host, Runtime};
use crate::interaction::{Command, Context, KeyStroke, key_notation};
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
                    for attribute in ["bold", "italic", "underline", "dim", "reverse", "plain"] {
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
            |_, (mode, keys, target, doc): (String, String, Value, Option<String>)| {
                let context = context(&mode)?;
                let keys = KeyStroke::parse_sequence(&keys).map_err(mlua::Error::runtime)?;
                // A function is kept and called by number; its label is
                // what it says it does.
                let (target, label) = match target {
                    Value::String(line) => (line.to_str()?.to_owned(), doc),
                    Value::Function(function) if context != Context::Prompt => {
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
                        context,
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
        scope.create_function(|_, (mode, keys): (String, String)| {
            let context = context(&mode)?;
            let keys = KeyStroke::parse_sequence(&keys).map_err(mlua::Error::runtime)?;
            runtime
                .borrow_mut()
                .layers
                .configure(Command::Unmap { context, keys })
                .map_err(mlua::Error::runtime)
        })?,
    )?;
    soda.set(
        "bindings",
        scope.create_function(|lua, mode: String| {
            let context = context(&mode)?;
            let out = lua.create_table()?;
            for (keys, label) in runtime.borrow().layers.bindings(context) {
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
                .add_hook(&event, &filter, format!("lua-call {id} %val{{hook}}"))
                .map_err(mlua::Error::runtime)
        })?,
    )?;
    soda.set(
        "define_command",
        scope.create_function(
            |_, (name, second, third): (String, Value, Option<Function>)| {
                // `(name, doc, fn)` reads like a docstring;
                // `(name, fn)` has none.
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
                    })
                    .map_err(mlua::Error::runtime)
            },
        )?,
    )?;
    soda.set(
        "completion_source",
        scope.create_function(|_, (triggers, function): (String, Function)| {
            let id = host.keep(function)?;
            runtime
                .borrow_mut()
                .layers
                .completion_source(id, triggers.chars().collect());
            Ok(())
        })?,
    )?;
    Ok(())
}
fn context(mode: &str) -> mlua::Result<Context> {
    Context::parse(mode).ok_or_else(|| mlua::Error::runtime(format!("unknown mode: {mode}")))
}
