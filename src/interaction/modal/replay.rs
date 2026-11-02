//! Keyboard macros: the keys that were typed, routed again from the top, so
//! whatever they did, including text typed in Insert, happens again.
use crate::interaction::UserInput;

#[derive(Default)]
pub(in crate::interaction) struct Replay {
    recording: Option<Vec<UserInput>>,
    last: Vec<UserInput>,
    /// Keys held before the sequence being typed, which may end recording.
    settled: usize,
}
impl Replay {
    pub fn recording(&self) -> bool {
        self.recording.is_some()
    }
    pub fn start(&mut self) {
        self.recording = Some(vec![]);
        self.settled = 0;
    }
    /// Ends recording; the keys that asked for it are not part of the macro.
    pub fn stop(&mut self) {
        if let Some(mut keys) = self.recording.take() {
            keys.truncate(self.settled);
            self.last = keys;
        }
    }
    pub fn last(&self) -> &[UserInput] {
        &self.last
    }
    /// Records typed input; `fresh` says no key sequence was pending.
    pub fn typed(&mut self, input: &UserInput, fresh: bool) {
        if let Some(keys) = &mut self.recording {
            if fresh {
                self.settled = keys.len();
            }
            keys.push(input.clone());
        }
    }
    /// Takes back the key just typed: it chose from a list, which a replay
    /// has no use for.
    pub fn unrecord(&mut self) {
        if let Some(keys) = &mut self.recording {
            keys.pop();
        }
    }
    /// Records input that did not come from a key.
    pub fn record(&mut self, input: UserInput) {
        if let Some(keys) = &mut self.recording {
            keys.push(input);
        }
    }
}
