//! One external command at a time on a background thread. Completion carries
//! the pipe target so the owner thread can reject output for a newer revision.
//! `stop` ends the command's process group.
use crate::interaction::shell::{PipeTarget, ShellRequest};
use std::{
    io::Write,
    process::{Child, Stdio},
    sync::mpsc::{self, Receiver, TryRecvError},
};

const OUTPUT_LIMIT: usize = 16 * 1024 * 1024;

pub struct ShellCompletion {
    pub command: String,
    pub pipe: Option<PipeTarget>,
    /// Stdout on success; otherwise a one-line failure description.
    pub result: Result<String, String>,
}
struct Running {
    command: String,
    pid: u32,
    pipe: Option<PipeTarget>,
    result: Receiver<Result<String, String>>,
}
#[derive(Default)]
pub struct ShellRunner {
    running: Option<Running>,
}
fn first_line(text: &[u8]) -> String {
    String::from_utf8_lossy(text)
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("")
        .trim()
        .to_owned()
}
fn execute(mut child: Child, input: Option<String>) -> Result<String, String> {
    // Feed stdin from another thread so a full stdout pipe cannot deadlock.
    let writer = input.zip(child.stdin.take()).map(|(input, mut stdin)| {
        std::thread::spawn(move || {
            let _ = stdin.write_all(input.as_bytes());
        })
    });
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if let Some(writer) = writer {
        let _ = writer.join();
    }
    if !output.status.success() {
        let detail = first_line(&output.stderr);
        let status = super::process::describe(output.status);
        return Err(if detail.is_empty() {
            status
        } else {
            format!("{status}: {detail}")
        });
    }
    if output.stdout.len() > OUTPUT_LIMIT {
        return Err("output exceeds 16 MiB".into());
    }
    String::from_utf8(output.stdout).map_err(|_| "output is not UTF-8".into())
}
impl ShellRunner {
    pub fn busy(&self) -> bool {
        self.running.is_some()
    }
    pub fn submit(&mut self, mut request: ShellRequest) -> Result<(), String> {
        if self.busy() {
            return Err("Another shell command is still running".into());
        }
        let (send, receive) = mpsc::channel();
        let mut pipe = request.pipe.take();
        let input = pipe
            .as_mut()
            .map(|target| std::mem::take(&mut target.input));
        let child = super::process::shell(&request)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("cannot run sh: {e}"))?;
        let pid = child.id();
        std::thread::Builder::new()
            .name("soda-shell".into())
            .spawn(move || {
                let _ = send.send(execute(child, input));
                crate::wake::wake();
            })
            .map_err(|_| "cannot start a shell thread")?;
        self.running = Some(Running {
            command: request.command,
            pid,
            pipe,
            result: receive,
        });
        Ok(())
    }
    /// Stops the running command; its completion still arrives. Returns
    /// whether one was running.
    pub fn stop(&mut self) -> bool {
        if let Some(running) = &self.running {
            super::process::terminate(running.pid);
        }
        self.running.is_some()
    }
    pub fn poll(&mut self) -> Option<ShellCompletion> {
        let result = match self.running.as_ref()?.result.try_recv() {
            Ok(result) => result,
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => Err("shell thread failed".into()),
        };
        let Running { command, pipe, .. } = self.running.take().unwrap();
        Some(ShellCompletion {
            command,
            pipe,
            result,
        })
    }
}
