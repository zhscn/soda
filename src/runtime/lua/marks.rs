//! `soda` functions that mark a document: line flags, notes, end-of-line
//! indicators, semantic tokens and inlay hints.
use super::Runtime;
use mlua::{Scope, Table, Value};
use std::cell::RefCell;

pub(super) fn register<'scope, 'r: 'scope>(
    scope: &'scope Scope<'scope, '_>,
    soda: &Table,
    runtime: &'scope RefCell<&'r mut Runtime>,
) -> mlua::Result<()> {
    soda.set(
        "paint",
        scope.create_function(|_, (group, items): (String, Option<Vec<Table>>)| {
            let paints = items
                .unwrap_or_default()
                .iter()
                .map(|item| {
                    let place = |name: &str| -> mlua::Result<(usize, usize)> {
                        let [line, column]: [usize; 2] = item.get(name)?;
                        Ok((line.saturating_sub(1), column.saturating_sub(1)))
                    };
                    let face = super::setup::resolve_face(
                        runtime.borrow().app.faces(),
                        item.get("face")?,
                    )?;
                    Ok(crate::application::PaintSpan {
                        start: place("from")?,
                        end: place("to")?,
                        face,
                    })
                })
                .collect::<mlua::Result<Vec<_>>>()?;
            let mut runtime = runtime.borrow_mut();
            let document = runtime.document().map_err(mlua::Error::runtime)?;
            runtime.edit_event(crate::application::Event::Paint {
                document,
                group,
                paints,
            })
        })?,
    )?;
    soda.set(
        "highlight",
        scope.create_function(
            |_, (pattern, style, options): (String, Value, Option<Table>)| {
                let pattern = regex::Regex::new(&pattern).map_err(mlua::Error::runtime)?;
                let mut runtime = runtime.borrow_mut();
                let face = super::setup::resolve_face(runtime.app.faces(), style)?;
                let (document, mark) = match options {
                    Some(options) => {
                        let document = if options.get::<Option<bool>>("global")?.unwrap_or(false) {
                            None
                        } else {
                            Some(runtime.document().map_err(mlua::Error::runtime)?)
                        };
                        (
                            document,
                            options.get::<Option<bool>>("mark")?.unwrap_or(false),
                        )
                    }
                    None => (
                        Some(runtime.document().map_err(mlua::Error::runtime)?),
                        false,
                    ),
                };
                runtime.edit_event(crate::application::Event::Highlight {
                    document,
                    face: Some(face),
                    pattern,
                    mark,
                })
            },
        )?,
    )?;
    soda.set(
        "flag",
        scope.create_function(
            |_, (group, face, sign, lines): (String, Value, String, Vec<usize>)| {
                let face = super::setup::resolve_face(runtime.borrow().app.faces(), face)?;
                let flag =
                    crate::application::Flag::new(face, &sign).map_err(mlua::Error::runtime)?;
                let lines = lines
                    .into_iter()
                    .filter(|line| *line > 0)
                    .map(|line| line - 1)
                    .collect();
                let mut runtime = runtime.borrow_mut();
                let document = runtime.document().map_err(mlua::Error::runtime)?;
                runtime.edit_event(crate::application::Event::Flag {
                    document,
                    group,
                    flag,
                    lines,
                })
            },
        )?,
    )?;
    soda.set(
        "note",
        scope.create_function(|_, (group, items): (String, Vec<mlua::Table>)| {
            let notes = items
                .iter()
                .map(|item| {
                    let place = |name: &str| -> mlua::Result<(usize, usize)> {
                        let [line, column]: [usize; 2] = item.get(name)?;
                        Ok((line.saturating_sub(1), column.saturating_sub(1)))
                    };
                    let severity: String = item.get("severity")?;
                    Ok(crate::application::NoteSpan {
                        start: place("from")?,
                        end: place("to")?,
                        severity: crate::application::Severity::parse(&severity)
                            .map_err(mlua::Error::runtime)?,
                        text: item.get("text")?,
                    })
                })
                .collect::<mlua::Result<Vec<_>>>()?;
            let mut runtime = runtime.borrow_mut();
            let document = runtime.document().map_err(mlua::Error::runtime)?;
            runtime.edit_event(crate::application::Event::Note {
                document,
                group,
                notes,
            })
        })?,
    )?;
    soda.set(
        "indicator",
        scope.create_function(|_, (line, text): (usize, String)| {
            let mut runtime = runtime.borrow_mut();
            let document = runtime.document().map_err(mlua::Error::runtime)?;
            runtime
                .app
                .set_indicator(document, line.saturating_sub(1), text);
            runtime.dirty = true;
            Ok(())
        })?,
    )?;
    soda.set(
        "tokens",
        scope.create_function(|_, (data, names): (Vec<usize>, Vec<String>)| {
            let categories: Vec<_> = names
                .iter()
                .map(|name| crate::syntax::Category::named(name))
                .collect();
            let tokens = data
                .as_chunks::<4>()
                .0
                .iter()
                .filter_map(|token| {
                    let category = (*categories.get(token[3])?)?;
                    Some(crate::application::TokenSpan {
                        line: token[0],
                        bytes: token[1]..token[2],
                        category,
                    })
                })
                .collect();
            let mut runtime = runtime.borrow_mut();
            let document = runtime.document().map_err(mlua::Error::runtime)?;
            runtime.edit_event(crate::application::Event::Tokens { document, tokens })
        })?,
    )?;
    soda.set(
        "inlays",
        scope.create_function(|_, items: Vec<Table>| {
            let hints = items
                .iter()
                .map(|item| {
                    let line: usize = item.get("line")?;
                    let column: usize = item.get("column")?;
                    let text: String = item.get("text")?;
                    Ok((line.saturating_sub(1), column.saturating_sub(1), text))
                })
                .collect::<mlua::Result<Vec<_>>>()?;
            let mut runtime = runtime.borrow_mut();
            let document = runtime.document().map_err(mlua::Error::runtime)?;
            runtime.edit_event(crate::application::Event::Inlays { document, hints })
        })?,
    )?;
    soda.set(
        "unflag",
        scope.create_function(|_, group: Option<String>| {
            let mut runtime = runtime.borrow_mut();
            let document = runtime.document().map_err(mlua::Error::runtime)?;
            // Nothing to remove is not a failure for a script.
            let _ = runtime
                .app
                .dispatch(crate::application::Event::Unflag { document, group });
            runtime.dirty = true;
            Ok(())
        })?,
    )?;
    Ok(())
}
