//! `soda` functions that run commands, read state, talk to the user and
//! start processes.
use super::{Host, Runtime};
use crate::interaction::Command;
use mlua::{Function, Scope, Table, Value};
use std::cell::RefCell;

pub(super) fn register<'scope, 'r: 'scope>(
    scope: &'scope Scope<'scope, '_>,
    soda: &Table,
    runtime: &'scope RefCell<&'r mut Runtime>,
    host: &'scope Host,
) -> mlua::Result<()> {
    soda.set(
        "defer",
        scope.create_function(|_, (ms, function): (u64, Function)| {
            let id = host.keep(function)?;
            let at = std::time::Instant::now() + std::time::Duration::from_millis(ms);
            let view = runtime.borrow().app.active_view();
            host.timers.borrow_mut().push((at, id, view));
            Ok(id)
        })?,
    )?;
    soda.set(
        "cancel",
        scope.create_function(|_, id: u64| {
            let mut timers = host.timers.borrow_mut();
            let before = timers.len();
            timers.retain(|(_, timer, _)| *timer != id);
            let cancelled = timers.len() != before;
            drop(timers);
            if cancelled {
                host.callbacks()?.set(id, Value::Nil)?;
            }
            Ok(cancelled)
        })?,
    )?;
    soda.set(
        "command",
        scope.create_function(|_, line: String| {
            let mut runtime = runtime.borrow_mut();
            runtime.failed = false;
            runtime.command(Command::Named(line));
            Ok((!runtime.failed, runtime.message.clone()))
        })?,
    )?;
    soda.set(
        "val",
        scope.create_function(|_, name: String| {
            super::expand(&runtime.borrow(), &format!("%val{{{name}}}"))
        })?,
    )?;
    soda.set(
        "option",
        scope.create_function(|lua, name: String| {
            use crate::options::Value as Option;
            if crate::options::info(&name).is_none() {
                return Err(mlua::Error::runtime(format!("unknown option {name}")));
            }
            let runtime = runtime.borrow();
            let document = runtime.document().ok();
            Ok(match runtime.app.options().get(document, &name) {
                Option::Bool(value) => Value::Boolean(value),
                Option::Int(value) => Value::Integer(value.into()),
                Option::Choice(value) => Value::String(lua.create_string(value)?),
            })
        })?,
    )?;
    soda.set(
        "set",
        scope.create_function(|_, (name, value, local): (String, Value, Option<bool>)| {
            let info = crate::options::info(&name)
                .ok_or_else(|| mlua::Error::runtime(format!("unknown option {name}")))?;
            let text = match value {
                Value::Boolean(value) => value.to_string(),
                Value::Integer(value) => value.to_string(),
                Value::Number(value) => value.to_string(),
                Value::String(value) => value.to_str()?.to_owned(),
                _ => {
                    return Err(mlua::Error::runtime(format!(
                        "{name} takes {}",
                        info.values()
                    )));
                }
            };
            let value = info.parse(&text).map_err(mlua::Error::runtime)?;
            let mut runtime = runtime.borrow_mut();
            runtime.failed = false;
            runtime.command(Command::SetOption {
                local: local.unwrap_or(false),
                name: info.name,
                value,
            });
            if runtime.failed {
                return Err(mlua::Error::runtime(runtime.message.clone()));
            }
            Ok(())
        })?,
    )?;
    soda.set(
        "declare_option",
        scope.create_function(|_, (name, spec): (String, Table)| {
            use crate::options::Declared;
            let doc: String = spec.get::<Option<String>>("doc")?.unwrap_or_default();
            let declared = match spec.get::<Value>("default")? {
                Value::Boolean(default) => Declared::Bool(default),
                Value::Integer(default) => {
                    let number = |key: &str, or: u32| -> mlua::Result<u32> {
                        Ok(spec.get::<Option<u32>>(key)?.unwrap_or(or))
                    };
                    Declared::Int {
                        default: u32::try_from(default)
                            .map_err(|_| mlua::Error::runtime("options count from 0"))?,
                        min: number("min", 0)?,
                        max: number("max", u32::MAX)?,
                    }
                }
                Value::String(default) => Declared::Choice {
                    default: default.to_str()?.to_owned(),
                    words: spec.get::<Option<Vec<String>>>("choices")?.ok_or_else(|| {
                        mlua::Error::runtime("an option with words needs choices")
                    })?,
                },
                _ => {
                    return Err(mlua::Error::runtime(
                        "an option's default is a boolean, an integer or one of its choices",
                    ));
                }
            };
            crate::options::declare(&name, declared, &doc).map_err(mlua::Error::runtime)?;
            Ok(())
        })?,
    )?;
    soda.set(
        "message",
        scope.create_function(|_, text: String| {
            runtime.borrow_mut().report(text);
            Ok(())
        })?,
    )?;
    soda.set(
        "hint",
        scope.create_function(|_, text: Option<String>| {
            let mut runtime = runtime.borrow_mut();
            runtime.hint = text;
            runtime.dirty = true;
            Ok(())
        })?,
    )?;
    soda.set(
        "prompt",
        scope.create_function(|_, text: String| {
            runtime.borrow_mut().command(Command::Ex(text));
            Ok(())
        })?,
    )?;
    soda.set(
        "choose",
        scope.create_function(
            |_, (title, items, function): (String, Vec<String>, Function)| {
                let id = host.keep(function)?;
                runtime
                    .borrow_mut()
                    .command(Command::Offer { id, title, items });
                Ok(())
            },
        )?,
    )?;
    soda.set(
        "popup",
        scope.create_function(|_, text: String| {
            let mut runtime = runtime.borrow_mut();
            runtime.popup = Some(text);
            runtime.popup_scroll.set(0);
            runtime.dirty = true;
            Ok(())
        })?,
    )?;
    soda.set(
        "keys",
        scope.create_function(|_, notation: String| {
            let keys = crate::interaction::KeyStroke::parse_sequence(&notation)
                .map_err(|error| mlua::Error::runtime(format!("{error:?}")))?;
            let mut runtime = runtime.borrow_mut();
            for key in keys {
                runtime.input(crate::interaction::UserInput::Key(key));
            }
            Ok(())
        })?,
    )?;
    soda.set(
        "open",
        scope.create_function(
            |_, (path, line, column): (String, Option<i64>, Option<i64>)| {
                let line = line.unwrap_or(1);
                let column = column.unwrap_or(1);
                if line < 1 || column < 1 {
                    return Err(mlua::Error::runtime(format!(
                        "position {{{line}, {column}}} is outside the buffer"
                    )));
                }
                let mut runtime = runtime.borrow_mut();
                runtime.layers.expect_jump();
                let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
                let path = crate::interaction::path::resolve_path(
                    &runtime.app.root(),
                    home.as_deref(),
                    std::path::Path::new(&path),
                )
                .map_err(mlua::Error::runtime)?;
                runtime.edit_event(crate::application::Event::OpenAt {
                    path,
                    line: line as usize - 1,
                    column: column as usize - 1,
                })
            },
        )?,
    )?;
    soda.set(
        "clipboard",
        scope.create_function(|_, text: String| {
            runtime
                .borrow_mut()
                .edit_event(crate::application::Event::SetClipboard(text))
        })?,
    )?;
    soda.set(
        "results",
        scope.create_function(|_, (kind, lines): (String, Vec<String>)| {
            if kind.is_empty() || kind == "file" || kind.contains(['*', ' ']) {
                return Err(mlua::Error::runtime(format!(
                    "{kind:?} cannot name results"
                )));
            }
            let mut runtime = runtime.borrow_mut();
            runtime.command(Command::Results { kind, lines });
            Ok(())
        })?,
    )?;
    soda.set(
        "spawn",
        scope.create_function(
            |_, (argv, function, input): (Vec<String>, Function, Option<String>)| {
                if argv.is_empty() {
                    return Err(mlua::Error::runtime("soda.spawn needs a program"));
                }
                let id = host.keep(function)?;
                let (root, view) = {
                    let runtime = runtime.borrow();
                    (runtime.app.root(), runtime.app.active_view())
                };
                let sender = host.jobs.0.clone();
                std::thread::spawn(move || {
                    let mut job = super::spawn(id, &argv, &root, input);
                    job.view = view;
                    let _ = sender.send(job);
                });
                Ok(())
            },
        )?,
    )?;
    Ok(())
}
