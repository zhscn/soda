//! Language server answers kept in Rust. Converting a whole document's
//! semantic tokens or inlay hints into Lua tables, and walking them in Lua,
//! held the owner thread for hundreds of milliseconds on a large file. A
//! request made raw hands Lua a handle to the JSON instead; Lua reads the
//! small parts it needs, and the bulky parts are decoded here.
use super::{Runtime, to_lua};
use crate::{
    application::{Event, TokenSpan},
    syntax::Category,
};
use mlua::{Function, Lua, LuaSerdeExt, Scope, Table, UserData, UserDataMethods, Value};
use std::{cell::RefCell, collections::HashMap, sync::Arc};

/// An answer as the server sent it.
pub(super) struct Json(pub Arc<serde_json::Value>);
impl UserData for Json {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        // A field, or an element counted from 1, as Lua values.
        methods.add_method("get", |lua, this, key: Value| {
            let child = match &key {
                Value::String(name) => this.0.get(&*name.to_str()?),
                Value::Integer(index) => usize::try_from(*index - 1)
                    .ok()
                    .and_then(|index| this.0.get(index)),
                _ => None,
            };
            child.map_or(Ok(Value::Nil), |child| to_lua(lua, child))
        });
        // A field that is an array of numbers, kept in Rust.
        methods.add_method("numbers", |lua, this, name: String| {
            match numbers_of(this.0.get(&name)) {
                Some(numbers) => Ok(Value::UserData(lua.create_userdata(numbers)?)),
                None => Ok(Value::Nil),
            }
        });
        methods.add_method("decode", |lua, this, ()| to_lua(lua, &this.0));
    }
}
fn numbers_of(value: Option<&serde_json::Value>) -> Option<Numbers> {
    let array = value?.as_array()?;
    let numbers = array
        .iter()
        .map(|number| number.as_u64().and_then(|n| u32::try_from(n).ok()))
        .collect::<Option<Vec<u32>>>()?;
    Some(Numbers(numbers.into()))
}

/// Semantic token data: five numbers a token, positions relative to the
/// token before.
#[derive(Clone)]
pub(super) struct Numbers(pub Arc<[u32]>);
impl UserData for Numbers {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_meta_method(mlua::MetaMethod::Len, |_, this, ()| Ok(this.0.len()));
        methods.add_meta_method(mlua::MetaMethod::Index, |_, this, index: usize| {
            Ok(index.checked_sub(1).and_then(|i| this.0.get(i).copied()))
        });
        // The data with a delta answer's edits made: each replaces
        // `deleteCount` numbers from `start` (from 0) with its `data`.
        methods.add_method("edited", |lua, this, edits: Value| {
            let edits: Vec<serde_json::Value> = lua.from_value(edits)?;
            let mut edits: Vec<_> = edits
                .iter()
                .map(|edit| {
                    let number = |name: &str| edit[name].as_u64().unwrap_or(0) as usize;
                    let data = numbers_of(edit.get("data")).map_or(vec![], |n| n.0.to_vec());
                    (number("start"), number("deleteCount"), data)
                })
                .collect();
            edits.sort_by_key(|(start, ..)| *start);
            let old = &this.0;
            let mut new = Vec::with_capacity(old.len());
            let mut at = 0;
            for (start, delete, data) in edits {
                let start = start.min(old.len());
                if start > at {
                    new.extend_from_slice(&old[at..start]);
                }
                new.extend(data);
                at = at.max(start + delete).min(old.len());
            }
            new.extend_from_slice(&old[at..]);
            Ok(Numbers(new.into()))
        });
    }
}

/// The byte in `text` at a server's column: UTF-8 bytes, UTF-16 units or
/// code points, rounded down to a character.
fn byte_of(text: &str, character: usize, encoding: &str) -> usize {
    if encoding == "utf-8" {
        let mut at = character.min(text.len());
        while !text.is_char_boundary(at) {
            at -= 1;
        }
        return at;
    }
    let mut units = 0;
    for (at, ch) in text.char_indices() {
        if units >= character {
            return at;
        }
        units += match encoding {
            "utf-32" => 1,
            _ => ch.len_utf16(),
        };
    }
    text.len()
}

fn json_of(lua: &Lua, value: Value) -> mlua::Result<Arc<serde_json::Value>> {
    match value {
        Value::Nil => Ok(Arc::new(serde_json::Value::Null)),
        Value::UserData(data) if data.is::<Json>() => Ok(data.borrow::<Json>()?.0.clone()),
        value => Ok(Arc::new(lua.from_value(value)?)),
    }
}

pub(super) fn register<'scope, 'r: 'scope>(
    scope: &'scope Scope<'scope, '_>,
    soda: &Table,
    runtime: &'scope RefCell<&'r mut Runtime>,
) -> mlua::Result<()> {
    // Semantic tokens for the current document. `name(type, bits)` names
    // the category of each kind that occurs, and whether it is struck
    // through; the struck tokens come back as ranges for `soda.paint`.
    soda.set(
        "lsp_tokens",
        scope.create_function(
            |lua, (data, encoding, name): (Value, String, Function)| -> mlua::Result<Table> {
                let data = match data {
                    Value::Nil => Numbers(Arc::new([])),
                    Value::UserData(data) => data.borrow::<Numbers>()?.clone(),
                    value => Numbers(lua.from_value::<Vec<u32>>(value)?.into()),
                };
                let (document, snapshot) = {
                    let runtime = runtime.borrow();
                    let document = runtime.document().map_err(mlua::Error::runtime)?;
                    let editor = runtime.app.workspace().editor(document).unwrap();
                    (document, editor.model().document().snapshot().clone())
                };
                // Kinds are few: Lua names each once.
                let mut kinds: HashMap<(u32, u32), (Option<Category>, bool)> = HashMap::new();
                let mut tokens = vec![];
                let mut struck = vec![];
                let (mut line, mut character) = (0usize, 0usize);
                let mut walk = snapshot.walk_lines();
                let mut row: Option<(usize, &str)> = None;
                for token in data.0.as_chunks::<5>().0 {
                    let [delta_line, delta_start, length, kind, bits] = *token;
                    if delta_line > 0 {
                        line += delta_line as usize;
                        character = 0;
                    }
                    character += delta_start as usize;
                    if line >= snapshot.line_count() {
                        continue;
                    }
                    if row.is_none_or(|(at, _)| at != line) {
                        row = Some((line, walk.content(line).map_or("", |(_, text)| text)));
                    }
                    let text = row.unwrap().1;
                    let from = byte_of(text, character, &encoding);
                    let to = byte_of(text, character + length as usize, &encoding);
                    let (category, strike) = match kinds.get(&(kind, bits)) {
                        Some(known) => *known,
                        None => {
                            let (named, strike): (String, Option<bool>) =
                                name.call((kind, bits))?;
                            let known = (Category::named(&named), strike.unwrap_or(false));
                            kinds.insert((kind, bits), known);
                            known
                        }
                    };
                    if let Some(category) = category {
                        tokens.push(TokenSpan {
                            line,
                            bytes: from..to,
                            category,
                        });
                    }
                    if strike {
                        struck.push((line, from, to));
                    }
                }
                runtime
                    .borrow_mut()
                    .edit_event(Event::Tokens { document, tokens })?;
                let out = lua.create_table()?;
                for (line, from, to) in struck {
                    let span = lua.create_table()?;
                    span.set("from", [line + 1, from + 1])?;
                    span.set("to", [line + 1, to + 1])?;
                    span.set("face", "deprecated")?;
                    out.push(span)?;
                }
                Ok(out)
            },
        )?,
    )?;
    // Inlay hints for the current document, as `textDocument/inlayHint`
    // answers them.
    soda.set(
        "lsp_inlays",
        scope.create_function(|lua, (hints, encoding): (Value, String)| {
            let hints = json_of(lua, hints)?;
            let (document, snapshot) = {
                let runtime = runtime.borrow();
                let document = runtime.document().map_err(mlua::Error::runtime)?;
                let editor = runtime.app.workspace().editor(document).unwrap();
                (document, editor.model().document().snapshot().clone())
            };
            let mut out = vec![];
            let mut walk = snapshot.walk_lines();
            let mut row: Option<(usize, &str)> = None;
            for hint in hints.as_array().into_iter().flatten() {
                let position = &hint["position"];
                let (Some(line), Some(character)) =
                    (position["line"].as_u64(), position["character"].as_u64())
                else {
                    continue;
                };
                let line = line as usize;
                if line >= snapshot.line_count() {
                    continue;
                }
                let mut text = match &hint["label"] {
                    serde_json::Value::String(label) => label.clone(),
                    serde_json::Value::Array(parts) => parts
                        .iter()
                        .filter_map(|part| part["value"].as_str())
                        .collect(),
                    _ => continue,
                };
                if hint["paddingLeft"].as_bool() == Some(true) {
                    text.insert(0, ' ');
                }
                if hint["paddingRight"].as_bool() == Some(true) {
                    text.push(' ');
                }
                if row.is_none_or(|(at, _)| at != line) {
                    row = Some((line, walk.content(line).map_or("", |(_, text)| text)));
                }
                let column = byte_of(row.unwrap().1, character as usize, &encoding);
                out.push((line, column, text));
            }
            runtime.borrow_mut().edit_event(Event::Inlays {
                document,
                hints: out,
            })
        })?,
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::byte_of;
    #[test]
    fn columns_count_in_the_server_s_units() {
        let text = "a😀b";
        assert_eq!(byte_of(text, 1, "utf-16"), 1);
        assert_eq!(byte_of(text, 3, "utf-16"), 5);
        assert_eq!(byte_of(text, 2, "utf-32"), 5);
        assert_eq!(byte_of(text, 2, "utf-8"), 1);
        assert_eq!(byte_of(text, 99, "utf-16"), text.len());
    }
}
