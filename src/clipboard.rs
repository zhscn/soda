//! System clipboard access. A local graphical session uses its clipboard
//! tools, which can also be read; otherwise, and over SSH, copies from a
//! terminal go to it as OSC 52, which most terminals accept but few let
//! programs read. A window without the tools keeps copies inside.
use crate::runtime::SystemClipboard;
use std::{
    io::{Read, Write},
    process::{Command, Stdio},
    sync::mpsc,
    time::Duration,
};

pub(crate) enum Clipboard {
    Tools {
        copy: &'static [&'static str],
        paste: &'static [&'static str],
    },
    Osc52,
    /// Nothing to reach the system clipboard with.
    Internal,
}
impl Clipboard {
    /// The clipboard of a terminal frontend: the tools, or OSC 52.
    pub fn terminal() -> Self {
        match Self::local() {
            Self::Internal => Self::Osc52,
            tools => tools,
        }
    }
    /// The clipboard tools of the graphical session the process runs in.
    pub fn local() -> Self {
        let set = |name| std::env::var_os(name).is_some_and(|value| !value.is_empty());
        let tools: &[(bool, &[&str], &[&str])] = &[
            (
                set("WAYLAND_DISPLAY"),
                &["wl-copy"],
                &["wl-paste", "--no-newline"],
            ),
            (
                set("DISPLAY"),
                &["xclip", "-selection", "clipboard"],
                &["xclip", "-selection", "clipboard", "-o"],
            ),
            (set("DISPLAY"), &["xsel", "-ib"], &["xsel", "-ob"]),
            (cfg!(target_os = "macos"), &["pbcopy"], &["pbpaste"]),
        ];
        // Over SSH the tools would reach the remote machine's display.
        if !set("SSH_CONNECTION") && !set("SSH_TTY") {
            for (usable, copy, paste) in tools {
                if *usable && on_path(copy[0]) && on_path(paste[0]) {
                    return Self::Tools { copy, paste };
                }
            }
        }
        Self::Internal
    }
}
impl SystemClipboard for Clipboard {
    fn store(&mut self, text: &str) {
        match self {
            Self::Tools { copy, .. } => {
                let Ok(mut child) = Command::new(copy[0])
                    .args(&copy[1..])
                    .stdin(Stdio::piped())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                else {
                    return;
                };
                // Some tools serve the selection until another copy replaces
                // it; never wait for them here.
                let mut stdin = child.stdin.take();
                let text = text.to_owned();
                std::thread::spawn(move || {
                    if let Some(stdin) = &mut stdin {
                        let _ = stdin.write_all(text.as_bytes());
                    }
                    drop(stdin);
                    let _ = child.wait();
                });
            }
            Self::Osc52 => {
                let mut out = std::io::stdout();
                let _ = write!(out, "\x1b]52;c;{}\x07", base64(text.as_bytes()));
                let _ = out.flush();
            }
            Self::Internal => {}
        }
    }
    fn load(&mut self) -> Option<String> {
        let Self::Tools { paste, .. } = self else {
            return None;
        };
        let mut child = Command::new(paste[0])
            .args(&paste[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let mut stdout = child.stdout.take()?;
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let mut text = String::new();
            let read = stdout.read_to_string(&mut text).is_ok();
            let _ = sender.send(read.then_some(text));
        });
        // A clipboard owner that does not answer must not freeze the editor.
        let text = receiver
            .recv_timeout(Duration::from_millis(500))
            .ok()
            .flatten();
        if text.is_none() {
            let _ = child.kill();
        }
        let success = child.wait().is_ok_and(|status| status.success());
        text.filter(|_| success)
    }
}

fn on_path(name: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|paths| std::env::split_paths(&paths).any(|dir| dir.join(name).is_file()))
}

fn base64(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, byte)| n | u32::from(*byte) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() {
                DIGITS[(n >> (18 - 6 * i) & 63) as usize] as char
            } else {
                '='
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn base64_pads_partial_groups() {
        assert_eq!(super::base64(b""), "");
        assert_eq!(super::base64(b"f"), "Zg==");
        assert_eq!(super::base64(b"fo"), "Zm8=");
        assert_eq!(super::base64(b"foo"), "Zm9v");
        assert_eq!(super::base64("中".as_bytes()), "5Lit");
    }
}
