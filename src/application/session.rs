//! What `restart` carries into the next process: the documents, their
//! views with selections and scrolling, the windows and which is focused,
//! the kill ring and the servers started by hand. Unsaved text goes as it
//! is and stays unsaved; undo history does not go. Scratch documents,
//! which hold results, are left to be made again.
use super::{
    Application, Error, Notice, Update, ViewId, Viewport, Windows,
    windows::{self},
};
use crate::{
    core::{Association, ByteOffset, Selection},
    editor::{Command, DocumentId, Language},
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::PathBuf, time::Duration};

impl Application {
    /// The session as `resume` takes it back.
    pub fn session(&self) -> Value {
        let workspace = &self.workspace;
        let documents: Vec<DocumentId> = workspace
            .documents()
            .filter(|document| {
                workspace
                    .file(*document)
                    .is_some_and(|file| file.scratch().is_none())
            })
            .collect();
        let saved_documents: Vec<Value> = documents
            .iter()
            .map(|&document| {
                let file = workspace.file(document).unwrap();
                let text = workspace.is_dirty(document).then(|| {
                    let editor = workspace.editor(document).unwrap();
                    editor.model().document().snapshot().text().to_owned()
                });
                json!({
                    "path": file.path().map(|path| path.to_string_lossy().into_owned()),
                    "text": text,
                    "context": self.save_context(document),
                })
            })
            .collect();
        let mut views: Vec<_> = self
            .views
            .values()
            .filter(|view| documents.contains(&view.document_id))
            .collect();
        views.sort_by_key(|view| view.id);
        let index: BTreeMap<ViewId, usize> = views
            .iter()
            .enumerate()
            .map(|(index, view)| (view.id, index))
            .collect();
        let saved_views: Vec<Value> = views
            .iter()
            .map(|view| {
                let editor = workspace.editor(view.document_id).unwrap();
                let selection = editor
                    .model()
                    .session(view.session_id)
                    .map_or(Selection::caret(0), |session| session.selection());
                json!({
                    "document": documents.iter().position(|d| *d == view.document_id),
                    "anchor": selection.anchor,
                    "head": selection.head,
                    "top": view.viewport.anchor.offset.0,
                    "scroll": view.viewport.horizontal_scroll,
                })
            })
            .collect();
        let find = |view: ViewId| index.get(&view).copied();
        json!({
            "documents": saved_documents,
            "views": saved_views,
            "windows": self.windows.save(&find),
            "recent": self.recent.iter().filter_map(|view| find(*view)).collect::<Vec<_>>(),
            "active": self.active.and_then(find),
            "kill_ring": self.kill_ring.iter().collect::<Vec<_>>(),
            "started_roots": self.started_roots,
        })
    }
    /// Takes back a session `session` gave, into an application that has
    /// no documents yet. What cannot come back, as a file gone without
    /// unsaved text, is left out and said in the returned problems.
    pub(super) fn resume(
        &mut self,
        session: &Value,
        update: &mut Update,
    ) -> Result<Vec<String>, Error> {
        let mut problems = vec![];
        let list = |key: &str| {
            session
                .get(key)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        };
        self.kill_ring = list("kill_ring")
            .iter()
            .filter_map(|entry| entry.as_str().map(str::to_owned))
            .collect();
        self.started_roots = list("started_roots")
            .iter()
            .filter_map(|pair| {
                let language = pair.get(0)?.as_str()?.to_owned();
                let root = PathBuf::from(pair.get(1)?.as_str()?);
                Some((language, root))
            })
            .collect();
        let mut documents: Vec<Option<DocumentId>> = vec![];
        for saved in list("documents") {
            let text = saved.get("text").and_then(Value::as_str).map(str::to_owned);
            let path = saved.get("path").and_then(Value::as_str).map(PathBuf::from);
            let document = match &path {
                // A file gone is no document to come back, unless unsaved
                // text keeps it under its name.
                Some(path) if !path.exists() && text.is_none() => {
                    problems.push(format!("{} is gone", path.display()));
                    None
                }
                Some(path) => match self.workspace.open_or_create(path) {
                    Ok(document) => Some(document),
                    Err(error) => {
                        problems.push(format!("{}: {error}", path.display()));
                        None
                    }
                },
                None => Some(self.workspace.new_document(Language::PlainText)),
            };
            if let Some(document) = document {
                if let Some(text) = text {
                    self.workspace.restore_text(document, text)?;
                }
                self.load_context(document, saved.get("context").unwrap_or(&Value::Null));
                self.apply_options(document, update);
            }
            documents.push(document);
        }
        let mut views: Vec<Option<ViewId>> = vec![];
        for saved in list("views") {
            let field = |key: &str| saved.get(key).and_then(Value::as_u64).map(|n| n as usize);
            let Some(document) =
                field("document").and_then(|i| documents.get(i).copied().flatten())
            else {
                views.push(None);
                continue;
            };
            let view = self.add_view(document)?;
            let snapshot = self
                .workspace
                .editor(document)
                .unwrap()
                .model()
                .document()
                .snapshot()
                .clone();
            // The file may have changed since: places stay within its text
            // and between characters.
            let clip = |offset: usize| {
                crate::core::clip_grapheme_offset(
                    &snapshot,
                    ByteOffset(offset.min(snapshot.len_bytes())),
                    Association::Before,
                )
                .map_or(0, |offset| offset.0)
            };
            let selection = Selection {
                anchor: clip(field("anchor").unwrap_or(0)),
                head: clip(field("head").unwrap_or(0)),
            };
            self.edit(
                view,
                Command::SetSelection(selection),
                Duration::ZERO,
                update,
            )?;
            let top = clip(field("top").unwrap_or(0));
            let editor = self.workspace.editor(document).unwrap();
            let anchor = editor
                .model()
                .document()
                .position(ByteOffset(top), Association::Before)?;
            self.views.get_mut(&view).unwrap().viewport = Viewport {
                anchor,
                horizontal_scroll: field("scroll").unwrap_or(0),
            };
            update.changed_views.push(view);
            views.push(Some(view));
        }
        let find = |index: usize| views.get(index).copied().flatten();
        self.windows = session
            .get("windows")
            .map_or_else(Windows::default, |saved| {
                windows::Windows::load(saved, &find)
            });
        self.recent = list("recent")
            .iter()
            .filter_map(|index| find(index.as_u64()? as usize))
            .collect();
        let active = session
            .get("active")
            .and_then(Value::as_u64)
            .and_then(|index| find(index as usize));
        self.repair_windows();
        if let Some(active) = active {
            self.focus(Some(active));
        }
        // Hooks see each document come, as when it was first opened.
        for document in documents.into_iter().flatten() {
            let Some(view) = views
                .iter()
                .flatten()
                .copied()
                .find(|view| self.views[view].document_id == document)
            else {
                continue;
            };
            let has_path = self
                .workspace
                .file(document)
                .is_some_and(|file| file.path().is_some());
            update.notices.push(if has_path {
                Notice::Opened(view)
            } else {
                Notice::Created(view)
            });
        }
        Ok(problems)
    }
}
