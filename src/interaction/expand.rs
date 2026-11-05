//! `%opt{NAME}` and `%val{NAME}` in command lines. A statement is expanded
//! when it runs, so it reads the state that the statements before it left.
//! Values replace the expansion as they are; they are not split again.
use super::EditMode;
use crate::application::Application;
use std::path::Path;

/// The state `%val{NAME}` reads, for help.
pub const VALUES: &[(&str, &str)] = &[
    ("file", "Path of the current file, empty when it has none"),
    ("name", "Buffer name of the current document"),
    ("kind", "file, or a scratch document's name such as grep"),
    ("line", "One-based caret line"),
    (
        "column",
        "One-based caret column, counting tabs to their stop",
    ),
    ("selection", "Selected text"),
    ("word", "The word at the caret: letters, digits and _"),
    ("root", "Project root"),
    (
        "column-limit",
        "clang-format's ColumnLimit for the file, 0 without one",
    ),
    ("mode", "normal, insert or beacon"),
    (
        "frontend",
        "gui or tui, the frontend drawing the editor; none without one",
    ),
    (
        "hook",
        "In a hook, the event's parameter, such as the saved path",
    ),
];

/// Whether a line reads state when it runs.
pub(super) fn has_expansions(line: &str) -> bool {
    line.contains("%opt{") || line.contains("%val{")
}

pub(super) struct State<'a> {
    pub app: &'a Application,
    pub mode: EditMode,
    pub root: &'a Path,
    /// The parameter of the event whose hooks are running.
    pub hook: Option<&'a str>,
}

pub(super) fn expand(line: &str, state: &State) -> Result<String, String> {
    let mut out = String::new();
    let mut rest = line;
    while let Some(start) = [rest.find("%opt{"), rest.find("%val{")]
        .into_iter()
        .flatten()
        .min()
    {
        out.push_str(&rest[..start]);
        let kind = &rest[start + 1..start + 4];
        let body = &rest[start + 5..];
        let end = body
            .find('}')
            .ok_or_else(|| format!("%{kind}{{ is not closed"))?;
        let name = &body[..end];
        out.push_str(&match kind {
            "opt" => option(name, state)?,
            _ => value(name, state)?,
        });
        rest = &body[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

fn document(state: &State) -> Option<crate::editor::DocumentId> {
    let view = state.app.view(state.app.active_view()?)?;
    Some(view.document_id)
}
fn option(name: &str, state: &State) -> Result<String, String> {
    crate::options::info(name).ok_or_else(|| format!("%opt{{{name}}}: unknown option"))?;
    Ok(state.app.options().get(document(state), name).to_string())
}
fn value(name: &str, state: &State) -> Result<String, String> {
    let app = state.app;
    match name {
        "root" => return Ok(state.root.to_string_lossy().into_owned()),
        "mode" => return Ok(state.mode.name().into()),
        "frontend" => return Ok(app.frontend().name().into()),
        "hook" => return Ok(state.hook.unwrap_or_default().into()),
        _ if !VALUES.iter().any(|(value, _)| *value == name) => {
            return Err(format!("%val{{{name}}}: unknown value"));
        }
        _ => {}
    }
    let view = app
        .active_view()
        .and_then(|id| app.view(id))
        .ok_or_else(|| format!("%val{{{name}}}: no document"))?;
    let document = view.document_id;
    Ok(match name {
        "file" => app
            .workspace()
            .file(document)
            .and_then(|file| file.path())
            .map_or_else(String::new, |path| path.to_string_lossy().into_owned()),
        "name" => app.document_name(document),
        "kind" => app.document_kind(document).to_owned(),
        "column-limit" => app
            .workspace()
            .file(document)
            .and_then(|file| file.configuration())
            .and_then(|resolved| resolved.config.values.get("ColumnLimit")?.as_u64())
            .unwrap_or(0)
            .to_string(),
        _ => {
            let editor = app.workspace().editor(document).unwrap();
            let snapshot = editor.model().document().snapshot();
            let selection = editor.model().session(view.session_id).unwrap().selection();
            let head = selection.head;
            let line = snapshot.line_of(head).unwrap();
            match name {
                "line" => (line + 1).to_string(),
                "word" => {
                    let start = snapshot.line_start(line).unwrap();
                    let end = snapshot.line_content_range(line).unwrap().end;
                    let text = snapshot.byte_slice(start..end).unwrap().to_string();
                    let at = head - start;
                    let part = |c: char| c.is_alphanumeric() || c == '_';
                    let from = text[..at]
                        .char_indices()
                        .rfind(|(_, c)| !part(*c))
                        .map_or(0, |(i, c)| i + c.len_utf8());
                    let to = text[at..].find(|c| !part(c)).map_or(text.len(), |i| at + i);
                    if from == to {
                        return Err("%val{word}: no word at the caret".into());
                    }
                    text[from..to].to_owned()
                }
                "column" => {
                    let tab = editor.model().document().whitespace().tab_width;
                    let column = crate::core::logical_column_at(
                        snapshot,
                        crate::core::ByteOffset(head),
                        tab,
                    )
                    .map_err(|e| e.to_string())?;
                    (column.0 + 1).to_string()
                }
                _ => snapshot
                    .byte_slice(selection.range())
                    .map_or_else(String::new, |text| text.to_string()),
            }
        }
    })
}
