//! `run`: a long command, such as a build, whose output and errors stream
//! into the `*run*` document while it runs. A new run stops the one before
//! it, as does `stop`.
use crate::interaction::shell::ShellRequest;
use std::{
    io::{BufRead, BufReader},
    process::Stdio,
    sync::mpsc::{self, Receiver, TryRecvError},
};

/// Output lines beyond this are dropped, and the run says so.
const LINE_LIMIT: usize = 100_000;
/// Lines taken per poll, so a chatty command cannot hold up input.
const BATCH: usize = 4096;

enum Message {
    Line(String),
    Exit(String),
}
/// What arrived since the last poll.
pub struct RunOutput {
    pub command: String,
    /// Lines without their line breaks.
    pub lines: Vec<String>,
    /// How the command ended, once it has.
    pub exit: Option<String>,
}
struct Running {
    command: String,
    pid: u32,
    messages: Receiver<Message>,
}
#[derive(Default)]
pub struct RunRunner {
    running: Option<Running>,
}
impl RunRunner {
    pub fn busy(&self) -> bool {
        self.running.is_some()
    }
    pub fn submit(&mut self, request: ShellRequest) -> Result<(), String> {
        self.stop();
        let error = |e: std::io::Error| format!("cannot run sh: {e}");
        let (reader, writer) = std::io::pipe().map_err(error)?;
        let mut command = super::process::shell(&request);
        command
            .stdin(Stdio::null())
            .stdout(writer.try_clone().map_err(error)?)
            .stderr(writer);
        let mut child = command.spawn().map_err(error)?;
        // The command keeps copies of the pipe's write end; the reader sees
        // the end of output only once they are gone.
        drop(command);
        let pid = child.id();
        let (send, messages) = mpsc::channel();
        std::thread::Builder::new()
            .name("soda-run".into())
            .spawn(move || {
                let mut reader = BufReader::new(reader);
                let mut line = vec![];
                let mut count = 0;
                while reader.read_until(b'\n', &mut line).is_ok_and(|n| n > 0) {
                    count += 1;
                    if count <= LINE_LIMIT {
                        let text = String::from_utf8_lossy(&line);
                        let text = text.trim_end_matches(['\n', '\r']).to_owned();
                        let _ = send.send(Message::Line(text));
                        crate::wake::wake();
                    } else if count == LINE_LIMIT + 1 {
                        let _ = send.send(Message::Line(format!(
                            "[output after {LINE_LIMIT} lines dropped]"
                        )));
                        crate::wake::wake();
                    }
                    line.clear();
                }
                let exit = match child.wait() {
                    Ok(status) => super::process::describe(status),
                    Err(error) => error.to_string(),
                };
                let _ = send.send(Message::Exit(exit));
                crate::wake::wake();
            })
            .map_err(|_| "cannot start a run thread")?;
        self.running = Some(Running {
            command: request.command,
            pid,
            messages,
        });
        Ok(())
    }
    /// Stops the running command; it reports nothing more. Returns whether
    /// one was running.
    pub fn stop(&mut self) -> bool {
        let running = self.running.take();
        if let Some(running) = &running {
            super::process::terminate(running.pid);
        }
        running.is_some()
    }
    pub fn poll(&mut self) -> Option<RunOutput> {
        let running = self.running.as_ref()?;
        let mut lines = vec![];
        let mut exit = None;
        while lines.len() < BATCH {
            match running.messages.try_recv() {
                Ok(Message::Line(line)) => lines.push(line),
                Ok(Message::Exit(status)) => {
                    exit = Some(status);
                    break;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    exit = Some("run thread failed".into());
                    break;
                }
            }
        }
        if lines.is_empty() && exit.is_none() {
            return None;
        }
        let command = running.command.clone();
        if exit.is_some() {
            self.running = None;
        }
        Some(RunOutput {
            command,
            lines,
            exit,
        })
    }
}
