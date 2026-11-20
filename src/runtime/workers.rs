//! Background services owned by the runtime and drained on its owner thread.
use super::{completion, grep, lsp, rg, run, shell};
use crate::{
    files::{FileRunner, paths::PathRunner},
    interaction::picker::PickerRunner,
};
use std::io;

pub(super) struct Workers {
    pub(super) files: FileRunner,
    pub(super) shell: shell::ShellRunner,
    pub(super) grep: grep::GrepRunner,
    pub(super) rg: rg::RgRunner,
    pub(super) completions: completion::Completions,
    pub(super) lsp: lsp::Lsp,
    pub(super) run: run::RunRunner,
    pub(super) picker: PickerRunner,
    pub(super) paths: PathRunner,
}

impl Workers {
    pub(super) fn new() -> io::Result<Self> {
        Ok(Self {
            files: FileRunner::new()?,
            shell: shell::ShellRunner::default(),
            grep: grep::GrepRunner::default(),
            rg: rg::RgRunner::default(),
            completions: completion::Completions::default(),
            lsp: lsp::Lsp::default(),
            run: run::RunRunner::default(),
            picker: PickerRunner::new()?,
            paths: PathRunner::new()?,
        })
    }

    pub(super) fn stop_processes(&mut self) -> bool {
        [
            self.run.stop(),
            self.shell.stop(),
            self.grep.stop(),
            self.rg.stop(),
        ]
        .contains(&true)
    }
}
