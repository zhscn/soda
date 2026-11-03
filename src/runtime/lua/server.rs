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
        scope.create_function(|_, (language, command): (String, Option<Vec<String>>)| {
            if command.as_ref().is_some_and(Vec::is_empty) {
                return Err(mlua::Error::runtime("a language server needs a program"));
            }
            runtime.borrow_mut().lsp.set_server(language, command);
            Ok(())
        })?,
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
            |lua, (method, params, function): (String, Value, Function)| {
                let params: serde_json::Value = lua.from_value(params)?;
                let id = host.keep(function)?;
                let mut runtime = runtime.borrow_mut();
                let Some(key) = runtime.lsp_key() else {
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
        scope.create_function(|lua, (method, params): (String, Value)| {
            let params: serde_json::Value = lua.from_value(params)?;
            let mut runtime = runtime.borrow_mut();
            let Some(key) = runtime.lsp_key() else {
                return Ok(false);
            };
            Ok(runtime.lsp.notify(&key, &method, params))
        })?,
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
        scope.create_function(|lua, ()| {
            let runtime = runtime.borrow();
            let Some(key) = runtime.lsp_key() else {
                return Ok(Value::Nil);
            };
            let Some((encoding, capabilities)) = runtime.lsp.client_of(&key) else {
                return Ok(Value::Nil);
            };
            let info = lua.create_table()?;
            info.set("encoding", encoding)?;
            info.set("capabilities", super::to_lua(lua, capabilities)?)?;
            Ok(Value::Table(info))
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
