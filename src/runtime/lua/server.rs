//! `soda.lsp` functions: servers, requests, notifications and what a
//! server said about itself.
use super::{Host, Runtime};
use mlua::{Function, LuaSerdeExt, Scope, Table, Value};
use std::cell::RefCell;

pub(super) fn register<'scope, 'r: 'scope>(
    scope: &'scope Scope<'scope, '_>,
    soda: &Table,
    runtime: &'scope RefCell<&'r mut Runtime>,
    host: &'scope Host,
) -> mlua::Result<()> {
    soda.set(
        "lsp_server",
        scope.create_function(
            |lua, (language, command, options): (String, Option<Vec<String>>, Option<Table>)| {
                if command.as_ref().is_some_and(Vec::is_empty) {
                    return Err(mlua::Error::runtime("a language server needs a program"));
                }
                let json = |name: &str| -> mlua::Result<serde_json::Value> {
                    match options.as_ref().map(|o| o.get::<Value>(name)).transpose()? {
                        None | Some(Value::Nil) => Ok(serde_json::Value::Null),
                        Some(value) => lua.from_value(value),
                    }
                };
                use crate::runtime::lsp::Auto;
                let auto = match options
                    .as_ref()
                    .map(|o| o.get::<Value>("auto"))
                    .transpose()?
                {
                    None | Some(Value::Nil | Value::Boolean(true)) => Auto::Always,
                    Some(Value::Boolean(false)) => Auto::Never,
                    Some(Value::String(s)) if s.to_str()? == "marked" => Auto::Marked,
                    Some(_) => {
                        return Err(mlua::Error::runtime("auto is true, false or \"marked\""));
                    }
                };
                // Markers, or a function that chooses.
                let (roots, function) = match options
                    .as_ref()
                    .map(|o| o.get::<Value>("roots"))
                    .transpose()?
                {
                    None | Some(Value::Nil) => (vec![], None),
                    Some(Value::Function(function)) => (vec![], Some(host.keep(function)?)),
                    Some(value) => (lua.from_value::<Vec<String>>(value)?, None),
                };
                let name = options
                    .as_ref()
                    .map(|o| o.get::<Option<String>>("name"))
                    .transpose()?
                    .flatten();
                let server = command
                    .map(|command| -> mlua::Result<_> {
                        // The program's file name unless told: what keymaps
                        // of servers name it by.
                        let name = name.unwrap_or_else(|| {
                            std::path::Path::new(&command[0])
                                .file_name()
                                .map_or_else(String::new, |n| n.to_string_lossy().into_owned())
                        });
                        Ok(crate::runtime::lsp::Server {
                            name,
                            command,
                            init: json("init")?,
                            settings: json("settings")?,
                            auto,
                            roots: function,
                        })
                    })
                    .transpose()?;
                let mut runtime = runtime.borrow_mut();
                runtime.lsp.set_server(language.clone(), server);
                runtime.edit_event(crate::application::Event::ServerRoots {
                    language,
                    markers: roots,
                })
            },
        )?,
    )?;
    soda.set(
        "lsp_array",
        scope.create_function(|lua, table: Table| {
            table.set_metatable(Some(lua.array_metatable()))?;
            Ok(table)
        })?,
    )?;
    soda.set(
        "lsp_request",
        scope.create_function(
            |lua, (method, params, function, buffer): (String, Value, Function, Option<Table>)| {
                let params: serde_json::Value = lua.from_value(params)?;
                let key = key_for(&runtime.borrow(), buffer)?;
                let id = host.keep(function)?;
                let mut runtime = runtime.borrow_mut();
                let Some(key) = key else {
                    host.callbacks()?.set(id, Value::Nil)?;
                    return Ok(Value::Boolean(false));
                };
                let Runtime { lsp, app, .. } = &mut **runtime;
                lsp.sync(app, true);
                // The function's id names the request, for `soda.lsp.cancel`.
                if lsp.request(&key, &method, params, id) {
                    Ok(Value::Integer(id as i64))
                } else {
                    host.callbacks()?.set(id, Value::Nil)?;
                    Ok(Value::Boolean(false))
                }
            },
        )?,
    )?;
    soda.set(
        "lsp_cancel",
        scope.create_function(|_, request: Option<u64>| {
            let Some(request) = request else {
                return Ok(false);
            };
            let cancelled = runtime.borrow_mut().lsp.cancel(request);
            if cancelled {
                host.callbacks()?.set(request, Value::Nil)?;
            }
            Ok(cancelled)
        })?,
    )?;
    soda.set(
        "lsp_notify",
        scope.create_function(
            |lua, (method, params, buffer): (String, Value, Option<Table>)| {
                let params: serde_json::Value = lua.from_value(params)?;
                let mut runtime = runtime.borrow_mut();
                let Some(key) = key_for(&runtime, buffer)? else {
                    return Ok(false);
                };
                Ok(runtime.lsp.notify(&key, &method, params))
            },
        )?,
    )?;
    soda.set(
        "lsp_on",
        scope.create_function(|_, (method, function): (String, Function)| {
            let id = host.keep(function)?;
            runtime.borrow_mut().lsp.on(method, id);
            Ok(())
        })?,
    )?;
    soda.set(
        "lsp_uri",
        scope.create_function(|_, ()| {
            let runtime = runtime.borrow();
            let document = runtime.document().ok();
            let path = document
                .and_then(|document| runtime.app.workspace().file(document))
                .and_then(|file| file.path());
            Ok(path.map(crate::runtime::lsp::uri))
        })?,
    )?;
    soda.set(
        "lsp_info",
        scope.create_function(|lua, buffer: Option<Table>| {
            let runtime = runtime.borrow();
            let Some(key) = key_for(&runtime, buffer)? else {
                return Ok(Value::Nil);
            };
            let Some((encoding, capabilities, watchers)) = runtime.lsp.client_of(&key) else {
                return Ok(Value::Nil);
            };
            let info = lua.create_table()?;
            info.set("language", key.0.as_str())?;
            info.set("root", key.1.to_string_lossy().into_owned())?;
            info.set("encoding", encoding)?;
            info.set("capabilities", super::to_lua(lua, capabilities)?)?;
            let list = lua.create_table()?;
            for watcher in watchers {
                list.push(super::to_lua(lua, watcher)?)?;
            }
            info.set("watchers", list)?;
            Ok(Value::Table(info))
        })?,
    )?;
    soda.set(
        "lsp_set_root",
        scope.create_function(|_, (id, root): (u64, Value)| {
            let mut runtime = runtime.borrow_mut();
            let document = super::buffer::document(&runtime, id)?;
            let root = match root {
                Value::String(dir) => {
                    let dir = dir.to_str()?.to_string();
                    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
                    Some(
                        crate::interaction::path::resolve_path(
                            &runtime.app.root_of(document),
                            home.as_deref(),
                            std::path::Path::new(&dir),
                        )
                        .map_err(mlua::Error::runtime)?,
                    )
                }
                Value::Nil | Value::Boolean(false) => None,
                _ => return Err(mlua::Error::runtime("a root is a directory, or false")),
            };
            runtime.edit_event(crate::application::Event::ChosenRoot { document, root })
        })?,
    )?;
    soda.set(
        "lsp_start",
        scope.create_function(|_, dir: Option<String>| {
            let mut runtime = runtime.borrow_mut();
            let document = runtime.document().map_err(mlua::Error::runtime)?;
            let Some((language, root)) = runtime.lsp_key_of(document) else {
                return Ok(None);
            };
            let root = match dir {
                Some(dir) if !dir.trim().is_empty() => {
                    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
                    crate::interaction::path::resolve_path(
                        &runtime.app.root(),
                        home.as_deref(),
                        std::path::Path::new(dir.trim()),
                    )
                    .map_err(mlua::Error::runtime)?
                }
                _ => root,
            };
            runtime.lsp.allow(&(language.clone(), root.clone()));
            runtime.edit_event(crate::application::Event::StartedRoot {
                language,
                root: root.clone(),
                started: true,
            })?;
            Ok(Some(root.to_string_lossy().into_owned()))
        })?,
    )?;
    soda.set(
        "lsp_stop",
        scope.create_function(|lua, ()| {
            let mut runtime = runtime.borrow_mut();
            let Some(key) = runtime.lsp_key() else {
                return Ok(Value::Nil);
            };
            let documents = runtime.lsp.stop(&key);
            runtime.edit_event(crate::application::Event::StartedRoot {
                language: key.0.clone(),
                root: key.1.clone(),
                started: false,
            })?;
            // What it said about its documents goes with it.
            let uris = lua.create_table()?;
            for (document, uri) in documents {
                use crate::application::Event;
                runtime.edit_event(Event::Note {
                    document,
                    group: "lsp".into(),
                    notes: vec![],
                })?;
                runtime.edit_event(Event::Tokens {
                    document,
                    tokens: vec![],
                })?;
                runtime.edit_event(Event::Inlays {
                    document,
                    hints: vec![],
                })?;
                for group in ["lsp-tags", "lsp-deprecated", "lsp-highlight"] {
                    runtime.edit_event(Event::Paint {
                        document,
                        group: group.into(),
                        paints: vec![],
                    })?;
                }
                uris.push(uri)?;
            }
            Ok(Value::Table(uris))
        })?,
    )?;
    soda.set(
        "lsp_servers",
        scope.create_function(|lua, ()| {
            let runtime = runtime.borrow();
            let list = lua.create_table()?;
            for server in runtime.lsp.servers() {
                let entry = lua.create_table()?;
                entry.set("language", server.language)?;
                entry.set("root", server.root.to_string_lossy().into_owned())?;
                entry.set("command", server.command)?;
                entry.set("state", server.state)?;
                entry.set("uris", server.uris)?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;
    soda.set(
        "lsp_restart",
        scope.create_function(|_, ()| {
            let mut runtime = runtime.borrow_mut();
            if let Some(key) = runtime.lsp_key() {
                runtime.lsp.restart(&key);
            }
            Ok(())
        })?,
    )?;
    Ok(())
}

/// The server of a buffer handle, or of the current document without one.
fn key_for(
    runtime: &Runtime,
    buffer: Option<Table>,
) -> mlua::Result<Option<crate::runtime::lsp::Key>> {
    match buffer {
        None => Ok(runtime.lsp_key()),
        Some(buffer) => {
            let document = super::buffer::document(runtime, buffer.get("id")?)?;
            Ok(runtime.lsp_key_of(document))
        }
    }
}
