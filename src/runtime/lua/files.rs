//! `soda` functions on files, for edits that create, rename and delete
//! them, such as a language server's: open documents follow a rename and
//! close with a delete.
use super::Runtime;
use crate::application::Event;
use mlua::{LuaSerdeExt, Scope, SerializeOptions, Table};
use std::{
    cell::RefCell,
    path::{Path, PathBuf},
};

pub(super) fn register<'scope, 'r: 'scope>(
    scope: &'scope Scope<'scope, '_>,
    soda: &Table,
    runtime: &'scope RefCell<&'r mut Runtime>,
) -> mlua::Result<()> {
    let resolve = |path: &str| -> mlua::Result<PathBuf> {
        let home = std::env::var_os("HOME").map(PathBuf::from);
        crate::interaction::path::resolve_path(
            &runtime.borrow().app.root(),
            home.as_deref(),
            Path::new(path),
        )
        .map_err(mlua::Error::runtime)
    };
    soda.set(
        "file_kind",
        scope.create_function(move |_, path: String| {
            let path = resolve(&path)?;
            Ok(std::fs::metadata(&path).ok().map(|metadata| {
                if metadata.is_dir() {
                    "directory"
                } else {
                    "file"
                }
            }))
        })?,
    )?;
    soda.set(
        "create_file",
        scope.create_function(move |_, path: String| {
            let path = resolve(&path)?;
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).map_err(|e| failure(parent, e))?;
            }
            std::fs::write(&path, "").map_err(|e| failure(&path, e))
        })?,
    )?;
    soda.set(
        "rename_file",
        scope.create_function(move |_, (from, to): (String, String)| {
            let (from, to) = (resolve(&from)?, resolve(&to)?);
            if let Some(parent) = to.parent() {
                std::fs::create_dir_all(parent).map_err(|e| failure(parent, e))?;
            }
            std::fs::rename(&from, &to).map_err(|e| failure(&from, e))?;
            let mut runtime = runtime.borrow_mut();
            // What was at the target is gone, and the documents under the
            // old name now stand for the new one.
            for (document, _) in documents_under(&runtime, &to) {
                runtime.edit_event(Event::CloseDocument {
                    document,
                    discard: true,
                })?;
            }
            for (document, path) in documents_under(&runtime, &from) {
                let rest = path.strip_prefix(&from).unwrap_or(Path::new(""));
                let path = if rest.as_os_str().is_empty() {
                    to.clone()
                } else {
                    to.join(rest)
                };
                runtime.edit_event(Event::Relocate { document, path })?;
            }
            Ok(())
        })?,
    )?;
    soda.set(
        "delete_file",
        scope.create_function(move |_, (path, recursive): (String, Option<bool>)| {
            let path = resolve(&path)?;
            let directory = std::fs::metadata(&path)
                .map_err(|e| failure(&path, e))?
                .is_dir();
            let removed = match (directory, recursive.unwrap_or(false)) {
                (true, true) => std::fs::remove_dir_all(&path),
                (true, false) => std::fs::remove_dir(&path),
                (false, _) => std::fs::remove_file(&path),
            };
            removed.map_err(|e| failure(&path, e))?;
            let mut runtime = runtime.borrow_mut();
            for (document, _) in documents_under(&runtime, &path) {
                runtime.edit_event(Event::CloseDocument {
                    document,
                    discard: true,
                })?;
            }
            Ok(())
        })?,
    )?;
    soda.set(
        "json_decode",
        scope.create_function(|lua, text: String| {
            let value: serde_json::Value =
                serde_json::from_str(&crate::language::plain_json(&text))
                    .map_err(|e| mlua::Error::runtime(format!("json: {e}")))?;
            lua.to_value_with(
                &value,
                SerializeOptions::new()
                    .serialize_none_to_null(false)
                    .serialize_unit_to_null(false),
            )
        })?,
    )?;
    Ok(())
}
fn failure(path: &Path, error: std::io::Error) -> mlua::Error {
    mlua::Error::runtime(format!("{}: {error}", path.display()))
}
/// Open documents of a file, or of the files in a directory.
fn documents_under(runtime: &Runtime, path: &Path) -> Vec<(crate::editor::DocumentId, PathBuf)> {
    let workspace = runtime.app.workspace();
    workspace
        .documents()
        .filter_map(|document| {
            let own = workspace.file(document)?.path()?;
            own.starts_with(path).then(|| (document, own.to_owned()))
        })
        .collect()
}
