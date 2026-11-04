//! The command loop, as Emacs's `command_loop_1`: input is read into
//! commands, one at a time, and each command has a beginning and an end.
//! What Emacs hangs on those edges hangs here, in one place:
//!
//! - **Beginning.** The keys of the command start over; a keyboard macro
//!   being recorded marks where the command began, so that the keys which
//!   end the macro, prefix argument and all, are left out
//!   (`finalize_kbd_macro_chars`); a transient keymap gets its one key
//!   (`set-transient-map`); `C-g` drops the macro being recorded
//!   (`keyboard-quit`).
//! - **End.** `last-command` becomes what this command was, and a command
//!   the user typed asks for the post-command work (`post-command-hook`),
//!   such as Beacon following the caret.
//!
//! A command is read while a prefix argument or a key sequence is pending;
//! it ends with the input that leaves neither. Commands run by Lua, hooks,
//! timers and frontends do not pass through here: they are no command of
//! the user's, as timers in Emacs run outside the command loop.
use super::{Command, KeyStroke};

/// Keys bound for the next key only, as `set-transient-map`: the last key
/// of `keys` alone runs again whichever of `commands` the sequence ending
/// in it is bound to.
#[derive(Clone, Debug)]
pub(super) struct Transient {
    pub keys: Vec<KeyStroke>,
    pub commands: &'static [&'static str],
}

#[derive(Default)]
pub(super) struct CommandLoop {
    /// The key sequence of the command, past its prefix argument, as
    /// `this-single-command-keys`.
    pub keys: Vec<KeyStroke>,
    /// The command being run, as `this-command`; none for typed text.
    pub this_command: Option<Command>,
    /// The command before it, as `last-command`: typed text in between
    /// leaves none.
    pub last_command: Option<Command>,
    /// The input comes from a keyboard macro being played, as
    /// `executing-kbd-macro`.
    pub executing: bool,
    pub transient: Option<Transient>,
    /// The last input the user typed ended a command, and the post-command
    /// work is due.
    pub ended: bool,
}
impl CommandLoop {
    /// A command begins with this input.
    pub fn begin(&mut self) {
        self.keys.clear();
        self.this_command = None;
    }
    /// The command ends.
    pub fn end(&mut self) {
        self.last_command = self.this_command.take();
    }
    /// The transient keymap the command sets, from its own keys: only a
    /// command read from more than one key has a last key to repeat.
    pub fn repeat_on_last_key(&mut self, commands: &'static [&'static str]) {
        self.transient = (self.keys.len() > 1).then(|| Transient {
            keys: self.keys.clone(),
            commands,
        });
    }
    /// The key the transient keymap repeats, for telling the user.
    pub fn repeat_key(&self) -> Option<KeyStroke> {
        self.transient.as_ref()?.keys.last().copied()
    }
    /// Whether the command before ran something `test` accepts. Keys hold
    /// commands parsed already; a line not yet parsed is tried against
    /// `names`.
    pub fn after(&self, test: impl Fn(&Command) -> bool, names: &[&str]) -> bool {
        match &self.last_command {
            Some(Command::Named(line)) => {
                names.contains(&line.split_whitespace().next().unwrap_or(""))
            }
            Some(command) => test(command),
            None => false,
        }
    }
}
