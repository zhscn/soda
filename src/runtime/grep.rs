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
    /// Result lines and the match count, or why the search failed.
    pub result: Result<(String, usize, bool), String>,
}
struct Running {
    pattern: String,
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
        std::thread::spawn(move || {
            let _ = sender.send(search(&request.root, &regex, &stop));
        });
        self.running = Some(Running {
            pattern: request.pattern,
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
        for (number, line) in text.lines().enumerate() {
            let Some(found) = regex.find(line) else {
                continue;
            };
            if count == MATCH_LIMIT {
                return Ok((out, count, true));
            }
            count += 1;
            let mut end = line.len().min(LINE_LIMIT);
            while !line.is_char_boundary(end) {
                end -= 1;
            }
            let _ = writeln!(
                out,
                "{}:{}:{}: {}",
                path.display(),
                number + 1,
                found.start() + 1,
                &line[..end]
            );
        }
    }
    Ok((out, count, false))
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
            "src/a.rs:1:4: fn main() {}\nsrc/a.rs:2:5: let Main = 1;\n"
        );
        assert_eq!((count, truncated), (2, false));
    }
}
