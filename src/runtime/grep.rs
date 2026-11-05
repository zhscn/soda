//! Project search on a background thread: the files the project picker
//! lists, in name order, matched line by line with a regular expression.
//! A new search cancels the one before it.
use crate::interaction::grep::GrepRequest;
use std::{
    fmt::Write,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, TryRecvError},
    },
};

/// Matches beyond this are dropped and reported.
const MATCH_LIMIT: usize = 10_000;
/// Longer result lines are cut, so minified files stay readable.
const LINE_LIMIT: usize = 400;

pub struct GrepCompletion {
    pub pattern: String,
    pub regex: regex::Regex,
    /// What the paths in the result are relative to.
    pub root: std::path::PathBuf,
    /// Result lines and the match count, or why the search failed.
    pub result: Result<(String, usize, bool), String>,
}
struct Running {
    pattern: String,
    regex: regex::Regex,
    root: std::path::PathBuf,
    cancel: Arc<AtomicBool>,
    result: Receiver<Result<(String, usize, bool), String>>,
}
#[derive(Default)]
pub struct GrepRunner {
    running: Option<Running>,
}
impl GrepRunner {
    pub fn busy(&self) -> bool {
        self.running.is_some()
    }
    pub fn submit(&mut self, request: GrepRequest) -> Result<(), String> {
        // Lowercase patterns ignore case, as smart case does elsewhere.
        let insensitive = !request.pattern.chars().any(char::is_uppercase);
        let regex = regex::RegexBuilder::new(&request.pattern)
            .case_insensitive(insensitive)
            .build()
            .map_err(|error| format!("grep: {error}"))?;
        if let Some(previous) = self.running.take() {
            previous.cancel.store(true, Ordering::Relaxed);
        }
        let cancel = Arc::new(AtomicBool::new(false));
        let (sender, result) = mpsc::channel();
        let stop = cancel.clone();
        let searched = regex.clone();
        let root = request.root.clone();
        std::thread::spawn(move || {
            let _ = sender.send(search(&request.root, &searched, &stop));
            crate::wake::wake();
        });
        self.running = Some(Running {
            pattern: request.pattern,
            regex,
            root,
            cancel,
            result,
        });
        Ok(())
    }
    /// Abandons the running search. Returns whether one was running.
    pub fn stop(&mut self) -> bool {
        let running = self.running.take();
        if let Some(running) = &running {
            running.cancel.store(true, Ordering::Relaxed);
        }
        running.is_some()
    }
    pub fn poll(&mut self) -> Option<GrepCompletion> {
        let running = self.running.as_ref()?;
        let result = match running.result.try_recv() {
            Ok(result) => result,
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => Err("grep: search stopped".into()),
        };
        let running = self.running.take().unwrap();
        Some(GrepCompletion {
            pattern: running.pattern,
            regex: running.regex,
            root: running.root,
            result,
        })
    }
}

fn search(
    root: &Path,
    regex: &regex::Regex,
    cancel: &AtomicBool,
) -> Result<(String, usize, bool), String> {
    let mut out = String::new();
    let mut count = 0;
    // Sorted, so results come in the same order every time.
    let walk = ignore::WalkBuilder::new(root)
        .sort_by_file_name(|a, b| a.cmp(b))
        .build();
    for entry in walk {
        if cancel.load(Ordering::Relaxed) {
            return Err("grep: cancelled".into());
        }
        let Ok(entry) = entry else {
            continue;
        };
        if !entry.file_type().is_some_and(|kind| kind.is_file()) {
            continue;
        }
        // Binary and non-UTF-8 files are skipped.
        let Ok(text) = std::fs::read_to_string(entry.path()) else {
            continue;
        };
        if text.as_bytes()[..text.len().min(8192)].contains(&0) {
            continue;
        }
        let path = entry.path().strip_prefix(root).unwrap_or(entry.path());
        let mut rows = vec![];
        let mut full = false;
        for (number, line) in text.lines().enumerate() {
            let Some(found) = regex.find(line) else {
                continue;
            };
            if count == MATCH_LIMIT {
                full = true;
                break;
            }
            count += 1;
            rows.push((number + 1, found.start() + 1, shown(line)));
        }
        group(&mut out, path, &rows);
        if full {
            return Ok((out, count, true));
        }
    }
    Ok((out, count, false))
}
/// The text a result shows: without indentation, cut at the limit.
fn shown(line: &str) -> &str {
    let line = line.trim_start();
    let mut end = line.len().min(LINE_LIMIT);
    while !line.is_char_boundary(end) {
        end -= 1;
    }
    &line[..end]
}
/// Writes a file's name and its matches below it, numbers aligned, with an
/// empty line before every file but the first.
fn group(out: &mut String, path: &Path, rows: &[(usize, usize, &str)]) {
    if rows.is_empty() {
        return;
    }
    if !out.is_empty() {
        out.push('\n');
    }
    let _ = writeln!(out, "{}", path.display());
    let width = |value: usize| value.to_string().len();
    let lines = rows.iter().map(|row| width(row.0)).max().unwrap_or(1);
    let columns = rows.iter().map(|row| width(row.1)).max().unwrap_or(1);
    for (line, column, text) in rows {
        let _ = writeln!(out, "  {line:>lines$}:{column:<columns$}  {text}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn results_list_matches_with_relative_paths_and_respect_ignores() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("src")).unwrap();
        std::fs::write(
            root.path().join("src/a.rs"),
            "fn main() {}\nlet Main = 1;\n",
        )
        .unwrap();
        std::fs::write(root.path().join("skip.bin"), b"main\0").unwrap();
        std::fs::write(root.path().join(".ignore"), "ignored.txt\n").unwrap();
        std::fs::write(root.path().join("ignored.txt"), "main\n").unwrap();
        let regex = regex::RegexBuilder::new("main")
            .case_insensitive(true)
            .build()
            .unwrap();
        let (text, count, truncated) =
            search(root.path(), &regex, &AtomicBool::new(false)).unwrap();
        assert_eq!(
            text,
            "src/a.rs\n  1:4  fn main() {}\n  2:5  let Main = 1;\n"
        );
        assert_eq!((count, truncated), (2, false));
    }
    #[test]
    fn groups_align_numbers_and_drop_indentation() {
        let mut out = String::new();
        group(
            &mut out,
            Path::new("a b.rs"),
            &[(9, 5, "x"), (120, 13, "y")],
        );
        group(&mut out, Path::new("c.rs"), &[]);
        group(&mut out, Path::new("d.rs"), &[(1, 1, "z")]);
        assert_eq!(out, "a b.rs\n    9:5   x\n  120:13  y\n\nd.rs\n  1:1  z\n");
        assert_eq!(shown("    x  "), "x  ");
    }
}

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
