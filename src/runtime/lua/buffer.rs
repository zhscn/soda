//! Buffer handles: Lua reads and edits documents through them.
//!
//! A handle holds only the document's number; each method looks the
//! document up again, so a handle kept between requests keeps working
//! until its document closes. Positions are `{line, column}` with both
//! counted from 1 and the column in bytes, as `string.sub` counts; a range
//! is two positions and leaves out the second. The column just past a
//! line's text is valid, so is `{line_count() + 1, 1}` after a final line
//! break. Offsets count bytes from 1.
//!
//! Every edit a request makes to one document becomes one undo step when
//! the request returns.
use super::super::Runtime;
use crate::{
    application::{Event, ViewId},
    core::{ByteOffset, Change, Selection, Snapshot, Transaction},
    editor::{Command, DocumentId},
    language::IndentAdvice,
};
use mlua::{Lua, Scope, Table};
use std::cell::RefCell;

/// Methods of a buffer handle; `buffer_NAME` in the lent table implements
/// each.
pub(super) const METHODS: &[&str] = &[
    "text",
    "line",
    "line_count",
    "revision",
    "selection",
    "set_selection",
    "edit",
    "indent",
    "offset",
    "point",
];

/// Documents a request edited, with the undo depth each had before its
/// first edit.
pub(super) type Edited = RefCell<Vec<(DocumentId, usize)>>;

fn error(message: impl Into<String>) -> mlua::Error {
    mlua::Error::runtime(message.into())
}
fn document(runtime: &Runtime, number: u64) -> mlua::Result<DocumentId> {
    runtime
        .app
        .workspace()
        .documents()
        .find(|document| document.number() == number)
        .ok_or_else(|| error(format!("buffer {number} is closed")))
}
fn snapshot(runtime: &Runtime, document: DocumentId) -> &Snapshot {
    runtime
        .app
        .workspace()
        .editor(document)
        .unwrap()
        .model()
        .document()
        .snapshot()
}
/// The view a request edits a document through: the view it runs in when
/// that shows the document, else one on screen, else any.
fn view(runtime: &Runtime, document: DocumentId) -> mlua::Result<ViewId> {
    let app = &runtime.app;
    if let Some(view) = app
        .active_view()
        .filter(|view| app.view(*view).is_some_and(|v| v.document_id == document))
    {
        return Ok(view);
    }
    app.views()
        .filter(|view| view.document_id == document)
        .max_by_key(|view| app.windows().contains(view.id))
        .map(|view| view.id)
        .ok_or_else(|| error("buffer has no view"))
}
/// A zero-based byte offset from a `{line, column}` table.
fn offset(snapshot: &Snapshot, position: &Table) -> mlua::Result<usize> {
    let line: i64 = position.get(1)?;
    let column: i64 = position.get(2)?;
    let outside = || {
        error(format!(
            "position {{{line}, {column}}} is outside the buffer"
        ))
    };
    if line < 1 || column < 1 {
        return Err(outside());
    }
    let range = snapshot
        .line_content_range(line as usize - 1)
        .ok_or_else(outside)?;
    let column = column as usize - 1;
    if column > range.len() {
        return Err(outside());
    }
    let offset = range.start + column;
    if !snapshot.is_char_boundary(offset) {
        return Err(error(format!(
            "position {{{line}, {}}} is inside a character",
            column + 1
        )));
    }
    Ok(offset)
}
fn position(lua: &Lua, snapshot: &Snapshot, offset: usize) -> mlua::Result<Table> {
    let point = snapshot
        .text_point(ByteOffset(offset))
        .map_err(|e| error(e.to_string()))?;
    lua.create_sequence_from([point.row + 1, point.byte_column + 1])
}
fn line_number(snapshot: &Snapshot, line: i64) -> mlua::Result<usize> {
    if line < 1 || line as usize > snapshot.line_count() {
        return Err(error(format!("line {line} is outside the buffer")));
    }
    Ok(line as usize - 1)
}
/// Runs an editor command for a document; a failure becomes a Lua error.
fn execute(runtime: &mut Runtime, document: DocumentId, command: Command) -> mlua::Result<()> {
    let view = view(runtime, document)?;
    let time = runtime.epoch.elapsed();
    runtime.edit_event(Event::Edit {
        view,
        command,
        time,
    })
}

/// Adds the buffer functions to the table lent for a request.
pub(super) fn register<'scope, 'r: 'scope>(
    scope: &'scope Scope<'scope, '_>,
    soda: &Table,
    runtime: &'scope RefCell<&'r mut Runtime>,
    edited: &'scope Edited,
) -> mlua::Result<()> {
    soda.set(
        "buffer",
        scope.create_function(|_, ()| {
            let runtime = runtime.borrow();
            let document = runtime.document().map_err(error)?;
            Ok(document.number())
        })?,
    )?;
    soda.set(
        "buffer_text",
        scope.create_function(
            |_, (number, from, to): (u64, Option<Table>, Option<Table>)| {
                let runtime = runtime.borrow();
                let snapshot = snapshot(&runtime, document(&runtime, number)?);
                let range = match (from, to) {
                    (None, None) => 0..snapshot.len_bytes(),
                    (Some(from), Some(to)) => offset(snapshot, &from)?..offset(snapshot, &to)?,
                    _ => return Err(error("buf:text takes no position or two")),
                };
                if range.start > range.end {
                    return Err(error("range ends before it starts"));
                }
                Ok(snapshot.byte_slice(range).unwrap().to_string())
            },
        )?,
    )?;
    soda.set(
        "buffer_line",
        scope.create_function(|_, (number, line): (u64, i64)| {
            let runtime = runtime.borrow();
            let snapshot = snapshot(&runtime, document(&runtime, number)?);
            let line = line_number(snapshot, line)?;
            Ok(snapshot.line(line).unwrap().into_owned())
        })?,
    )?;
    soda.set(
        "buffer_line_count",
        scope.create_function(|_, number: u64| {
            let runtime = runtime.borrow();
            Ok(snapshot(&runtime, document(&runtime, number)?).text_lines())
        })?,
    )?;
    soda.set(
        "buffer_revision",
        scope.create_function(|_, number: u64| {
            let runtime = runtime.borrow();
            Ok(snapshot(&runtime, document(&runtime, number)?).version())
        })?,
    )?;
    soda.set(
        "buffer_selection",
        scope.create_function(|lua, number: u64| {
            let runtime = runtime.borrow();
            let document = document(&runtime, number)?;
            let view = runtime.app.view(view(&runtime, document)?).unwrap();
            let editor = runtime.app.workspace().editor(document).unwrap();
            let selection = editor.model().session(view.session_id).unwrap().selection();
            let snapshot = snapshot(&runtime, document);
            Ok((
                position(lua, snapshot, selection.anchor)?,
                position(lua, snapshot, selection.head)?,
            ))
        })?,
    )?;
    soda.set(
        "buffer_set_selection",
        scope.create_function(|_, (number, anchor, head): (u64, Table, Option<Table>)| {
            let mut runtime = runtime.borrow_mut();
            let document = document(&runtime, number)?;
            let snapshot = snapshot(&runtime, document);
            let anchor = offset(snapshot, &anchor)?;
            let head = match head {
                Some(head) => offset(snapshot, &head)?,
                None => anchor,
            };
            execute(
                &mut runtime,
                document,
                Command::SetSelection(Selection { anchor, head }),
            )
        })?,
    )?;
    soda.set(
        "buffer_edit",
        scope.create_function(
            |_, (number, changes, revision): (u64, Table, Option<u64>)| {
                let mut runtime = runtime.borrow_mut();
                let document = document(&runtime, number)?;
                let snapshot = snapshot(&runtime, document);
                let version = snapshot.version();
                if revision.is_some_and(|revision| revision != version) {
                    return Err(error(format!(
                        "buffer changed since revision {}",
                        revision.unwrap()
                    )));
                }
                let mut list = vec![];
                for change in changes.sequence_values::<Table>() {
                    let change = change?;
                    let from = offset(snapshot, &change.get(1)?)?;
                    let to = offset(snapshot, &change.get(2)?)?;
                    if from > to {
                        return Err(error("range ends before it starts"));
                    }
                    let text: String = change.get(3)?;
                    list.push(Change::new(from..to, text));
                }
                if list.is_empty() {
                    return Ok(version);
                }
                if !edited.borrow().iter().any(|(d, _)| *d == document) {
                    let depth = runtime
                        .app
                        .workspace()
                        .editor(document)
                        .unwrap()
                        .model()
                        .document()
                        .history_depth();
                    edited.borrow_mut().push((document, depth));
                }
                execute(
                    &mut runtime,
                    document,
                    Command::Apply(Transaction::new(version, list)),
                )?;
                Ok(snapshot_version(&runtime, document))
            },
        )?,
    )?;
    soda.set(
        "buffer_indent",
        scope.create_function(|_, (number, line): (u64, i64)| {
            let mut runtime = runtime.borrow_mut();
            let document = document(&runtime, number)?;
            let line = line_number(snapshot(&runtime, document), line)?;
            let advice = runtime
                .app
                .indentation(document, line)
                .map_err(|e| error(e.to_string()))?;
            Ok(match advice {
                IndentAdvice::Set { prefix, .. } => Some(prefix),
                IndentAdvice::Preserve { .. } | IndentAdvice::Unavailable => None,
            })
        })?,
    )?;
    soda.set(
        "buffer_offset",
        scope.create_function(|_, (number, at): (u64, Table)| {
            let runtime = runtime.borrow();
            let snapshot = snapshot(&runtime, document(&runtime, number)?);
            Ok(offset(snapshot, &at)? + 1)
        })?,
    )?;
    soda.set(
        "buffer_point",
        scope.create_function(|lua, (number, at): (u64, i64)| {
            let runtime = runtime.borrow();
            let snapshot = snapshot(&runtime, document(&runtime, number)?);
            if at < 1 || at as usize > snapshot.len_bytes() + 1 {
                return Err(error(format!("offset {at} is outside the buffer")));
            }
            let at = at as usize - 1;
            if !snapshot.is_char_boundary(at) {
                return Err(error(format!("offset {} is inside a character", at + 1)));
            }
            position(lua, snapshot, at)
        })?,
    )?;
    Ok(())
}
fn snapshot_version(runtime: &Runtime, document: DocumentId) -> u64 {
    snapshot(runtime, document).version()
}
/// Makes the edits of a finished request one undo step per document.
pub(super) fn squash(runtime: &mut Runtime, edited: Vec<(DocumentId, usize)>) {
    for (document, depth) in edited {
        if runtime.app.workspace().editor(document).is_some() {
            // A document whose last view closed keeps its separate steps.
            let _ = execute(runtime, document, Command::SquashHistory(depth));
        }
    }
}
