//! External command requests. The interaction layer captures the target text
//! and revision; Runtime runs the process in the background and applies output
//! only to the revision it was computed from.
use crate::application::{Application, View, ViewId};
use std::{ops::Range, path::Path, path::PathBuf};

pub struct PipeTarget {
    pub view: ViewId,
    pub version: u64,
    pub range: Range<usize>,
    pub input: String,
}
pub struct ShellRequest {
    pub command: String,
    pub cwd: PathBuf,
    pub env: Vec<(&'static str, String)>,
    /// Present for `pipe`: stdout replaces this range of this revision.
    pub pipe: Option<PipeTarget>,
}
fn environment(app: &Application, view: &View) -> Vec<(&'static str, String)> {
    let editor = app.workspace().editor(view.document_id).unwrap();
    let snapshot = editor.model().document().snapshot();
    let head = editor
        .model()
        .session(view.session_id)
        .unwrap()
        .selection()
        .head;
    let line = snapshot.line_of(head).unwrap();
    let start = snapshot.line_start(line).unwrap();
    let column = snapshot
        .byte_slice(start..head)
        .map_or(0, |text| text.to_string().chars().count());
    let mut env = vec![
        ("SODA_LINE", (line + 1).to_string()),
        ("SODA_COLUMN", (column + 1).to_string()),
    ];
    if let Some(path) = app.workspace().file(view.document_id).unwrap().path() {
        env.push(("SODA_FILE", path.display().to_string()));
    }
    env
}
pub(super) fn run(
    app: &Application,
    view: Option<&View>,
    command: String,
    root: &Path,
) -> ShellRequest {
    ShellRequest {
        command,
        cwd: root.to_owned(),
        env: view.map_or_else(Vec::new, |view| environment(app, view)),
        pipe: None,
    }
}
/// Pipes the selection, or the whole document when the selection is empty.
pub(super) fn pipe(app: &Application, view: &View, command: String, root: &Path) -> ShellRequest {
    let editor = app.workspace().editor(view.document_id).unwrap();
    let snapshot = editor.model().document().snapshot();
    let selection = editor.model().session(view.session_id).unwrap().selection();
    let range = if selection.range().is_empty() {
        0..snapshot.len_bytes()
    } else {
        selection.range()
    };
    ShellRequest {
        command,
        cwd: root.to_owned(),
        env: environment(app, view),
        pipe: Some(PipeTarget {
            view: view.id,
            version: snapshot.version(),
            input: snapshot.byte_slice(range.clone()).unwrap().to_string(),
            range,
        }),
    }
}
