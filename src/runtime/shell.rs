//! One external command at a time on a background thread. Completion carries
//! the pipe target so the owner thread can reject output for a newer revision.
use crate::interaction::shell::{PipeTarget, ShellRequest};
use std::{
    io::Write,
    process::{Command, Stdio},
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
fn execute(request: &ShellRequest, input: Option<String>) -> Result<String, String> {
    let mut command = Command::new("sh");
    command
        .arg("-c")
        .arg(&request.command)
        .current_dir(&request.cwd)
        .envs(request.env.iter().map(|(k, v)| (k, v)))
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|e| format!("cannot run sh: {e}"))?;
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
        let status = output
            .status
            .code()
            .map_or_else(|| "was terminated".into(), |code| format!("exited {code}"));
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
    pub fn submit(&mut self, mut request: ShellRequest) -> Result<(), &'static str> {
        if self.busy() {
            return Err("Another shell command is still running");
        }
        let (send, receive) = mpsc::channel();
        let mut pipe = request.pipe.take();
        let input = pipe
            .as_mut()
            .map(|target| std::mem::take(&mut target.input));
        let command = request.command.clone();
        std::thread::Builder::new()
            .name("soda-shell".into())
            .spawn(move || {
                let _ = send.send(execute(&request, input));
            })
            .map_err(|_| "cannot start a shell thread")?;
        self.running = Some(Running {
            command,
            pipe,
            result: receive,
        });
        Ok(())
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
