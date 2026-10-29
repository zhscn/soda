//! Shell commands in their own process group, so that stopping one also
//! stops the processes it started.
use crate::interaction::shell::ShellRequest;
use std::process::{Command, ExitStatus, Stdio};

pub(super) fn shell(request: &ShellRequest) -> Command {
    let mut command = Command::new("sh");
    command
        .arg("-c")
        .arg(&request.command)
        .current_dir(&request.cwd)
        .envs(request.env.iter().map(|(k, v)| (k, v)));
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut command, 0);
    command
}
/// Asks a process group started by `shell` to stop.
pub(super) fn terminate(pid: u32) {
    #[cfg(unix)]
    let _ = Command::new("kill")
        .args(["-TERM", "--", &format!("-{pid}")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}
pub(super) fn describe(status: ExitStatus) -> String {
    status
        .code()
        .map_or_else(|| "was stopped".into(), |code| format!("exited {code}"))
}
