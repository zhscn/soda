//! Process groups and ownership of editor-managed children.
use crate::interaction::shell::ShellRequest;
use std::{
    io,
    process::{Child, ChildStderr, ChildStdin, ChildStdout, Command, ExitStatus},
    sync::{Arc, Mutex, Weak},
    time::Duration,
};

pub(super) fn shell(request: &ShellRequest) -> Command {
    let mut command = Command::new("sh");
    command
        .arg("-c")
        .arg(&request.command)
        .current_dir(&request.cwd)
        .envs(request.env.iter().map(|(k, v)| (k, v)));
    isolate(&mut command);
    command
}

pub(super) fn isolate(_command: &mut Command) {
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(_command, 0);
}

/// Asks a process group created by `isolate` to stop.
pub(super) fn terminate(_pid: u32) {
    #[cfg(unix)]
    let _ = signal_group(_pid, libc::SIGTERM);
}

#[cfg(unix)]
fn signal_group(pid: u32, signal: libc::c_int) -> io::Result<()> {
    let group = libc::pid_t::try_from(pid)
        .ok()
        .filter(|pid| *pid > 1)
        .ok_or(io::ErrorKind::InvalidInput)?;
    // A negative PID addresses the group whose leader has that PID.
    if unsafe { libc::kill(-group, signal) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

struct State {
    child: Child,
    reaped: bool,
}

impl State {
    fn force_stop(&mut self) {
        // The PID can be reused once we reap the leader. Serialize signaling
        // and reaping so a cancellation handle cannot target a reused group.
        if self.reaped {
            return;
        }
        #[cfg(unix)]
        if signal_group(self.child.id(), libc::SIGKILL).is_ok() {
            return;
        }
        let _ = self.child.kill();
    }

    fn stop_and_wait(&mut self) {
        if !self.reaped {
            self.force_stop();
            self.reaped = self.child.wait().is_ok();
        }
    }
}

pub(super) struct Cancellation(Weak<Mutex<State>>);

impl Cancellation {
    pub fn force_stop(&self) {
        if let Some(state) = self.0.upgrade() {
            state.lock().unwrap().force_stop();
        }
    }

    pub fn stop_and_wait(&self) {
        if let Some(state) = self.0.upgrade() {
            state.lock().unwrap().stop_and_wait();
        }
    }
}

/// Owns the child until it is reaped. Callers control the pipes and can
/// attempt protocol-specific shutdown before dropping the child.
pub(super) struct ManagedChild {
    state: Arc<Mutex<State>>,
    pub stdin: Option<ChildStdin>,
    pub stdout: Option<ChildStdout>,
    pub stderr: Option<ChildStderr>,
}

impl ManagedChild {
    pub fn spawn(command: &mut Command) -> io::Result<Self> {
        isolate(command);
        let mut child = command.spawn()?;
        Ok(Self {
            stdin: child.stdin.take(),
            stdout: child.stdout.take(),
            stderr: child.stderr.take(),
            state: Arc::new(Mutex::new(State {
                child,
                reaped: false,
            })),
        })
    }

    pub fn cancellation(&self) -> Cancellation {
        Cancellation(Arc::downgrade(&self.state))
    }

    pub fn force_stop(&self) {
        self.state.lock().unwrap().force_stop();
    }

    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        let mut state = self.state.lock().unwrap();
        let status = state.child.try_wait()?;
        state.reaped |= status.is_some();
        Ok(status)
    }

    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        self.stdin.take();
        loop {
            if let Some(status) = self.try_wait()? {
                return Ok(status);
            }
            // A child may close its output before exiting. Release the lock
            // between checks so another thread can still cancel it.
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for ManagedChild {
    fn drop(&mut self) {
        self.state.lock().unwrap().stop_and_wait();
    }
}

pub(super) fn describe(status: ExitStatus) -> String {
    status
        .code()
        .map_or_else(|| "was stopped".into(), |code| format!("exited {code}"))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Read},
        process::Stdio,
        sync::mpsc,
    };

    #[test]
    fn dropping_a_child_closes_pipes_inherited_by_its_worker() {
        let mut child = ManagedChild::spawn(
            Command::new("sh")
                .args(["-c", "sleep 30 & echo $!; wait"])
                .stdout(Stdio::piped()),
        )
        .unwrap();
        let mut output = BufReader::new(child.stdout.take().unwrap());
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        let worker: libc::pid_t = line.trim().parse().unwrap();

        drop(child);

        let (done, result) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            let _ = done.send(output.read_to_end(&mut Vec::new()));
        });
        let eof = result.recv_timeout(Duration::from_secs(2));
        if eof.is_err() {
            // Clean up the worker if group termination regresses.
            unsafe { libc::kill(worker, libc::SIGKILL) };
        }
        reader.join().unwrap();
        assert_eq!(eof.unwrap().unwrap(), 0);
    }
}
