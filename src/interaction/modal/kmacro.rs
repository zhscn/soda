//! Keyboard macro commands, as Emacs's kmacro.el: `<f3>` starts recording,
//! or inserts the counter while recording or playing; `<f4>` ends
//! recording, or plays the last macro; `C-x (`, `C-x )` and `C-x e`; and
//! the `C-x C-k` map of the ring, the counter and names. A count plays a
//! macro that many times, 0 until a command fails; `C-u` before `<f3>`
//! appends to the last macro, before `<f4>` plays the second. After a key
//! sequence that played a macro, its last key alone plays it again.
use super::{execute::Place, replay::format_counter};
use crate::{
    editor::Command as Edit,
    interaction::{Command, EditMode, Layers, Message, Response, UserInput},
};

/// What a macro key does; the names are the commands'.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MacroAction {
    /// `macro-start`, `<f3>`: `kmacro-start-macro-or-insert-counter`.
    StartOrCounter,
    /// `macro-record`, `C-x (`: `kmacro-start-macro`.
    Start,
    /// `macro-end`, `<f4>`: `kmacro-end-or-call-macro`.
    EndOrCall,
    /// `macro-end-repeat`, `C-x C-k C-k`: the same, repeated by `C-k`.
    EndOrCallRepeat,
    /// `macro-stop`, `C-x )`: `kmacro-end-macro`.
    End,
    /// `macro-end-and-call`, `C-x e`: `kmacro-end-and-call-macro`.
    EndAndCall,
    /// `macro-call-second`, `C-x C-k C-l`: `kmacro-call-ring-2nd-repeat`.
    CallSecond,
    /// `macro-ring-next` and `macro-ring-previous`, `C-x C-k C-n`/`C-p`.
    RingNext,
    RingPrevious,
    /// `macro-ring-swap`, `C-x C-k C-t`.
    RingSwap,
    /// `macro-ring-delete`, `C-x C-k C-d`.
    RingDelete,
    /// `macro-view`, `C-x C-k C-v`.
    View,
    /// `macro-insert-counter`, `C-x C-k C-i`.
    InsertCounter,
    /// `macro-set-counter [N]`, `C-x C-k C-c`.
    SetCounter(Option<i64>),
    /// `macro-add-counter [N]`, `C-x C-k C-a`.
    AddCounter(Option<i64>),
}
/// Commands the last key of `C-x C-k` repeats, as those with a
/// `kmacro-repeat` property.
const RING_REPEATS: &[&str] = &[
    "macro-end-repeat",
    "macro-call-second",
    "macro-ring-next",
    "macro-ring-previous",
    "macro-ring-delete",
    "macro-view",
];
/// The prefix argument as a kmacro command reads it.
pub(super) struct Prefix {
    pub count: usize,
    /// Given at all: `C-u`, digits or a count.
    pub given: bool,
    /// Only `C-u`s, which Emacs passes as a list.
    pub raw: bool,
}
impl Layers {
    pub(super) fn macro_action(
        &mut self,
        action: MacroAction,
        at: &Place,
        prefix: Prefix,
        mut response: Response,
    ) -> Response {
        let recording = self.modal.replay.recording();
        let executing = self.command.executing;
        match action {
            MacroAction::StartOrCounter if recording || executing => {
                self.insert_counter(at, &prefix, &mut response);
            }
            MacroAction::StartOrCounter | MacroAction::Start => {
                if recording || executing {
                    return self.fail(response, "Already defining keyboard macro.");
                }
                // As `meow-beacon-start`: keys go to the main selection
                // alone, in Normal, the other places held until it ends.
                if self.mode == EditMode::Beacon {
                    self.mode = EditMode::Normal;
                }
                if prefix.raw {
                    // `C-u` appends after playing the macro again, as if it
                    // were typed; `C-u C-u` appends without.
                    let last = self.modal.replay.last().to_vec();
                    self.modal.replay.start(None, true);
                    if prefix.count <= 4 {
                        response.replay = last;
                    }
                    response.message = Message::Set("Appending to kbd macro...".into());
                } else {
                    let counter = prefix.given.then_some(prefix.count as i64);
                    self.modal.replay.start(counter, false);
                    response.message = Message::Set("Defining kbd macro...".into());
                }
            }
            MacroAction::EndOrCall | MacroAction::EndOrCallRepeat => {
                if action == MacroAction::EndOrCallRepeat {
                    self.command.repeat_on_last_key(RING_REPEATS);
                }
                if recording {
                    return self.end_macro(&prefix, response);
                }
                if prefix.raw {
                    return self.call_second(1, response);
                }
                if self.beacon_active() && !self.modal.replay.last().is_empty() {
                    self.beacon_call_macro(prefix.count.max(1), &mut response);
                    return response;
                }
                return self.call_macro(prefix.count, response);
            }
            MacroAction::End => {
                if !recording {
                    return self.fail(response, "Not defining kbd macro");
                }
                return self.end_macro(&prefix, response);
            }
            MacroAction::EndAndCall => {
                if recording {
                    // In Beacon it goes to the other places, as `<f4>` does.
                    let played = !self.modal.beacons.is_empty();
                    response = self.end_macro(
                        &Prefix {
                            count: 1,
                            given: false,
                            raw: false,
                        },
                        response,
                    );
                    if played {
                        return response;
                    }
                }
                self.command.repeat_on_last_key(&["macro-end-and-call"]);
                let before = std::mem::replace(&mut response.message, Message::Clear);
                response = self.call_macro(prefix.count, response);
                // A failure says so; else what ending said; else the hint,
                // as Emacs gives it when the echo area is free.
                if matches!(response.message, Message::Set(_)) {
                    self.command.transient = None;
                } else if matches!(before, Message::Set(_)) {
                    response.message = before;
                } else if let Some(key) = self.command.repeat_key() {
                    response.message =
                        Message::Set(format!("(Type {} to repeat macro)", key.emacs()));
                }
            }
            MacroAction::CallSecond => {
                self.command.repeat_on_last_key(RING_REPEATS);
                return self.call_second(prefix.count, response);
            }
            MacroAction::RingNext | MacroAction::RingPrevious => {
                self.command.repeat_on_last_key(RING_REPEATS);
                let previous = action == MacroAction::RingPrevious;
                if let Err(message) = self.modal.replay.cycle(previous) {
                    return self.fail(response, message);
                }
                response.message = Message::Set(self.describe_macro("Macro"));
            }
            MacroAction::RingSwap => {
                if let Err(message) = self.modal.replay.swap() {
                    return self.fail(response, message);
                }
                response.message = Message::Set(self.describe_macro("Macro"));
            }
            MacroAction::RingDelete => {
                self.command.repeat_on_last_key(RING_REPEATS);
                if let Err(message) = self.modal.replay.delete_head() {
                    return self.fail(response, message);
                }
                response.message = Message::Set(if self.modal.replay.last().is_empty() {
                    "Keyboard macro ring is now empty.".into()
                } else {
                    self.describe_macro("Macro")
                });
            }
            MacroAction::View => {
                self.command.repeat_on_last_key(RING_REPEATS);
                response.message = Message::Set(if self.modal.replay.last().is_empty() {
                    "No keyboard macros defined".into()
                } else {
                    self.describe_macro("Macro")
                });
            }
            MacroAction::InsertCounter => self.insert_counter(at, &prefix, &mut response),
            MacroAction::SetCounter(value) => {
                let replay = &mut self.modal.replay;
                let value = match value {
                    Some(value) => value,
                    None if prefix.raw && (recording || executing) => replay.counter_start,
                    None if prefix.given => prefix.count as i64,
                    None => return ask(response, "macro-set-counter ", "macro counter value"),
                };
                if recording || executing {
                    replay.last_counter = replay.counter;
                    replay.counter = value;
                } else {
                    replay.initial = Some(value);
                }
                if !executing {
                    response.message = Message::Set(counter_message(replay, value));
                }
            }
            MacroAction::AddCounter(value) => {
                let replay = &mut self.modal.replay;
                if let Some(initial) = replay.initial.take() {
                    replay.counter = initial;
                }
                let last = replay.last_counter;
                replay.last_counter = replay.counter;
                replay.counter = match value {
                    Some(value) => replay.counter + value,
                    None if prefix.raw => last,
                    None if prefix.given => replay.counter + prefix.count as i64,
                    None => {
                        replay.counter = replay.last_counter;
                        replay.last_counter = last;
                        return ask(response, "macro-add-counter ", "add to macro counter");
                    }
                };
                if !executing {
                    let value = replay.counter;
                    response.message = Message::Set(counter_message(replay, value));
                }
            }
        }
        response
    }
    /// Ends recording, as `kmacro-end-macro`: with a count, plays the macro
    /// that many times more, the recording counted as the first. Recorded in
    /// Beacon, it plays at the other places.
    fn end_macro(&mut self, prefix: &Prefix, mut response: Response) -> Response {
        if !self.modal.replay.stop() {
            response.message = Message::Set("Ignore empty macro".into());
            return response;
        }
        response.message = Message::Set("Keyboard macro defined".into());
        if !self.modal.beacons.is_empty() {
            self.beacon_end_macro(&mut response);
            return response;
        }
        let keys = self.modal.replay.last().to_vec();
        if prefix.given && prefix.count == 0 {
            response.replay = keys;
            response.replay_until_failure = true;
        } else if prefix.given && !prefix.raw {
            for _ in 1..prefix.count {
                response.replay.extend(keys.iter().cloned());
            }
        }
        response
    }
    /// Plays the last macro `count` times, 0 until a command fails, as
    /// `kmacro-call-macro`.
    fn call_macro(&mut self, count: usize, response: Response) -> Response {
        let keys = self.modal.replay.last().to_vec();
        self.play(keys, count, response)
    }
    fn call_second(&mut self, count: usize, response: Response) -> Response {
        let Some(keys) = self.modal.replay.second().map(<[_]>::to_vec) else {
            let message = if self.modal.replay.last().is_empty() {
                "No keyboard macro defined."
            } else {
                "Only one keyboard macro defined."
            };
            return self.fail(response, message);
        };
        self.play(keys, count, response)
    }
    fn play(&mut self, keys: Vec<UserInput>, count: usize, mut response: Response) -> Response {
        if self.modal.replay.recording() {
            return self.fail(response, "Can't execute anonymous macro while defining one");
        }
        if keys.is_empty() {
            return self.fail(response, "No kbd macro has been defined");
        }
        if count == 0 {
            response.replay = keys;
            response.replay_until_failure = true;
        } else {
            for _ in 0..count {
                response.replay.extend(keys.iter().cloned());
            }
        }
        response
    }
    /// `macro-call NAME`: a macro `macro-name` named, `count` times.
    pub(in crate::interaction) fn call_named(
        &mut self,
        name: &str,
        response: Response,
    ) -> Response {
        let Some(keys) = self.modal.replay.named(name).map(<[_]>::to_vec) else {
            return self.fail(response, &format!("No keyboard macro named {name}"));
        };
        let (count, _) = self.modal.take_prefix();
        self.play(keys, count, response)
    }
    /// Inserts the counter, then adds the count to it; after `C-u`, the
    /// value before the last change, the counter left as it is.
    fn insert_counter(&mut self, at: &Place, prefix: &Prefix, response: &mut Response) {
        let replay = &mut self.modal.replay;
        if let Some(initial) = replay.initial.take() {
            replay.counter = initial;
        }
        let value = if prefix.raw {
            replay.last_counter
        } else {
            replay.counter
        };
        let text = replay.formatted(value);
        if !prefix.raw {
            replay.last_counter = replay.counter;
            replay.counter += if prefix.given { prefix.count as i64 } else { 1 };
        }
        response.events.push(at.event(Edit::InsertText(text)));
    }
    /// The last macro as `kmacro-display` shows it.
    fn describe_macro(&self, what: &str) -> String {
        let replay = &self.modal.replay;
        let keys = describe(replay.last());
        let keys = if keys.chars().count() > 60 {
            format!("{}...", keys.chars().take(59).collect::<String>())
        } else {
            keys
        };
        let counter = if replay.counter == 0 {
            String::new()
        } else {
            format!(" [{}]", replay.formatted(replay.counter))
        };
        format!("{what}{counter}: {keys}")
    }
}
/// The command line, to ask for what a command needs.
fn ask(mut response: Response, line: &str, note: &str) -> Response {
    response.commands.push(Command::Ask {
        line: line.into(),
        note: note.into(),
    });
    response
}
fn counter_message(replay: &super::replay::Replay, value: i64) -> String {
    format!(
        "New macro counter value: {} ({value})",
        format_counter(&replay.format, value)
    )
}
/// Keys as Emacs writes a macro: `C-a`, `RET`, runs of characters joined.
pub(in crate::interaction) fn describe(keys: &[UserInput]) -> String {
    let mut out: Vec<String> = vec![];
    let mut run = String::new();
    for input in keys {
        match input {
            UserInput::Key(key)
                if !key.control
                    && !key.alt
                    && matches!(key.code, crate::interaction::Key::Char(ch) if ch != ' ') =>
            {
                if let crate::interaction::Key::Char(ch) = key.code {
                    run.push(ch);
                }
            }
            other => {
                if !run.is_empty() {
                    out.push(std::mem::take(&mut run));
                }
                out.push(match other {
                    UserInput::Key(key) => key.emacs(),
                    UserInput::Paste(text) => format!("{text:?}"),
                    _ => "<event>".into(),
                });
            }
        }
    }
    if !run.is_empty() {
        out.push(run);
    }
    out.join(" ")
}
