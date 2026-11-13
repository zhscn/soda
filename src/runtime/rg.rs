//! Ripgrep runs outside the editor thread. JSON output keeps file names and
//! byte columns unambiguous; the result renderer shares grep's grouped layout.
use super::grep::{GrepCompletion, group, shown};
use crate::interaction::grep::RipgrepRequest;
use serde_json::Value;
use std::{
    collections::BTreeMap,
    io::{BufRead, BufReader, Read},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver, TryRecvError},
};

const MATCH_LIMIT: usize = 10_000;
type SearchResult = Result<(String, usize, bool), String>;
struct Running {
    pid: u32,
    request: RipgrepRequest,
    regex: regex::Regex,
    result: Receiver<SearchResult>,
}
#[derive(Default)]
pub(super) struct RgRunner {
    running: Option<Running>,
}
impl Drop for RgRunner {
    fn drop(&mut self) {
        self.stop();
    }
}
impl RgRunner {
    pub fn busy(&self) -> bool {
        self.running.is_some()
    }
    pub fn submit(&mut self, request: RipgrepRequest) -> Result<(), String> {
        let insensitive = request.case_insensitive()?;
        let pattern = if request.literal {
            regex::escape(&request.pattern)
        } else {
            request.pattern.clone()
        };
        let regex = regex::RegexBuilder::new(&pattern)
            .case_insensitive(insensitive)
            .build()
            .map_err(|error| format!("rg: {error}"))?;
        let mut command = Command::new("rg");
        command.args(["--no-config", "--json", "--color=never"]);
        command.arg(if insensitive {
            "--ignore-case"
        } else {
            "--case-sensitive"
        });
        if request.literal {
            command.arg("--fixed-strings");
        }
        if request.hidden {
            command.arg("--hidden");
        }
        if request.no_ignore {
            command.arg("--no-ignore");
        }
        match request.files.as_str() {
            "everything" | "" => {}
            files if files.starts_with("glob:") => {
                command.arg("--glob").arg(&files[5..]);
            }
            files => {
                command.arg("--type").arg(files);
            }
        }
        command
            .args(["--regexp", &request.pattern, "--", "."])
            .current_dir(&request.root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(unix)]
        std::os::unix::process::CommandExt::process_group(&mut command, 0);
        self.stop();
        let child = command.spawn().map_err(|error| format!("rg: {error}"))?;
        let pid = child.id();
        let (sender, result) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = sender.send(search(child));
            crate::wake::wake();
        });
        self.running = Some(Running {
            pid,
            request,
            regex,
            result,
        });
        Ok(())
    }
    pub fn stop(&mut self) -> bool {
        if let Some(running) = self.running.take() {
            super::process::terminate(running.pid);
            true
        } else {
            false
        }
    }
    pub fn poll(&mut self) -> Option<GrepCompletion> {
        let running = self.running.as_ref()?;
        let result = match running.result.try_recv() {
            Ok(result) => result,
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => Err("rg: search stopped".into()),
        };
        let Running { request, regex, .. } = self.running.take().unwrap();
        let header = format!(
            "# Query: {}\n# Files: {}\n# Directory: {}\n# Mode: {}; case: {}; hidden: {}; no-ignore: {}\n\n",
            request.pattern,
            request.files,
            request.root.display(),
            if request.literal { "literal" } else { "regexp" },
            request.case,
            request.hidden,
            request.no_ignore
        );
        Some(GrepCompletion {
            kind: "rg",
            pattern: request.pattern,
            regex,
            root: request.root,
            result: result.map(|(text, count, truncated)| (header + &text, count, truncated)),
        })
    }
}

fn search(mut child: Child) -> SearchResult {
    let stderr = child.stderr.take().unwrap();
    let errors = std::thread::spawn(move || {
        let mut reader = BufReader::new(stderr);
        let mut kept = String::new();
        let _ = reader.by_ref().take(8192).read_to_string(&mut kept);
        let _ = std::io::copy(&mut reader, &mut std::io::sink());
        kept
    });
    let output = read_matches(BufReader::new(child.stdout.take().unwrap()));
    if !output.as_ref().is_ok_and(|(_, _, truncated)| !*truncated) {
        let _ = child.kill();
    }
    let status = child.wait().map_err(|error| format!("rg: {error}"));
    let errors = errors.join().unwrap_or_default();
    let result = output?;
    let status = status?;
    if !result.2 && !matches!(status.code(), Some(0 | 1)) {
        return Err(format!(
            "rg: {}",
            if errors.trim().is_empty() {
                super::process::describe(status)
            } else {
                errors.trim().to_owned()
            }
        ));
    }
    Ok(result)
}

fn read_matches(reader: impl BufRead) -> SearchResult {
    let mut files: BTreeMap<PathBuf, Vec<(usize, usize, String)>> = BTreeMap::new();
    let mut count = 0;
    let mut truncated = false;
    for line in reader.lines() {
        let line = line.map_err(|error| format!("rg: {error}"))?;
        let message: Value =
            serde_json::from_str(&line).map_err(|error| format!("rg: invalid JSON: {error}"))?;
        if message["type"] != "match" {
            continue;
        }
        let data = &message["data"];
        // Ripgrep encodes non-UTF-8 paths and lines as base64; soda's
        // result documents represent UTF-8 text and skip those entries.
        let (Some(path), Some(text), Some(line), Some(start)) = (
            data["path"]["text"].as_str(),
            data["lines"]["text"].as_str(),
            data["line_number"].as_u64(),
            data["submatches"][0]["start"].as_u64(),
        ) else {
            continue;
        };
        if path.contains(['\n', '\r']) {
            return Err("rg: result file name contains a newline".into());
        }
        if count == MATCH_LIMIT {
            truncated = true;
            break;
        }
        let path = PathBuf::from(path.strip_prefix("./").unwrap_or(path));
        let text = text.trim_end_matches(['\n', '\r']);
        files.entry(path).or_default().push((
            line as usize,
            start as usize + 1,
            shown(text).into(),
        ));
        count += 1;
    }
    let mut out = String::new();
    for (path, rows) in files {
        let rows: Vec<_> = rows
            .iter()
            .map(|(line, column, text)| (*line, *column, text.as_str()))
            .collect();
        group(&mut out, &path, &rows);
    }
    Ok((out, count, truncated))
}
