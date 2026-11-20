//! Finds the files that may contain matches on a worker thread.
use std::{
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, TryRecvError},
    },
};

/// The files of a project with a match, in name order, for a replacement
/// over the project; searched as the documents will be, by the query.
#[derive(Default)]
pub struct FileSearch {
    running: Option<(Arc<AtomicBool>, Receiver<Vec<std::path::PathBuf>>)>,
}
impl FileSearch {
    /// Starts looking, after stopping the search before.
    pub fn submit(&mut self, root: std::path::PathBuf, query: crate::editor::search::SearchQuery) {
        self.stop();
        let cancel = Arc::new(AtomicBool::new(false));
        let (sender, result) = mpsc::channel();
        let stop = cancel.clone();
        std::thread::spawn(move || {
            let _ = sender.send(files_with(&root, &query, &stop));
            crate::wake::wake();
        });
        self.running = Some((cancel, result));
    }
    pub fn stop(&mut self) -> bool {
        let running = self.running.take();
        if let Some((cancel, _)) = &running {
            cancel.store(true, Ordering::Relaxed);
        }
        running.is_some()
    }
    pub fn poll(&mut self) -> Option<Vec<std::path::PathBuf>> {
        let (_, result) = self.running.as_ref()?;
        let files = match result.try_recv() {
            Ok(files) => files,
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => vec![],
        };
        self.running = None;
        Some(files)
    }
}
fn files_with(
    root: &Path,
    query: &crate::editor::search::SearchQuery,
    cancel: &AtomicBool,
) -> Vec<std::path::PathBuf> {
    let walk = ignore::WalkBuilder::new(root)
        .sort_by_file_name(|a, b| a.cmp(b))
        .build();
    let mut files = vec![];
    for entry in walk {
        if cancel.load(Ordering::Relaxed) {
            return vec![];
        }
        let Ok(entry) = entry else {
            continue;
        };
        if !entry.file_type().is_some_and(|kind| kind.is_file()) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(entry.path()) else {
            continue;
        };
        if text.as_bytes()[..text.len().min(8192)].contains(&0) {
            continue;
        }
        let snapshot = crate::core::Snapshot::new(text, 0);
        if query.cursor(&snapshot).next().is_some() {
            files.push(entry.path().to_owned());
        }
    }
    files
}

impl Drop for FileSearch {
    fn drop(&mut self) {
        self.stop();
    }
}
