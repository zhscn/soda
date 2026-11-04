//! Keyboard macros, as Emacs's kmacro: the keys that were typed, routed
//! again from the top, so whatever they did, including text typed in
//! Insert, happens again. The last macro heads a ring of earlier ones, each
//! with the counter it had; the counter is inserted by `<f3>` while a macro
//! is recorded or played.
use crate::interaction::UserInput;
use std::collections::{BTreeMap, VecDeque};

/// As `kmacro-ring-max`.
const RING: usize = 8;

/// A macro with its counter, as an element of Emacs's `kmacro-ring`.
#[derive(Clone, Debug)]
pub(in crate::interaction) struct Macro {
    pub keys: Vec<UserInput>,
    pub counter: i64,
    pub format: String,
}

pub(in crate::interaction) struct Replay {
    recording: Option<Vec<UserInput>>,
    /// Recording adds to the last macro, as `C-u <f3>`.
    appending: bool,
    /// The last macro, `last-kbd-macro`; empty when there is none.
    last: Vec<UserInput>,
    /// Earlier macros, the most recent first.
    ring: VecDeque<Macro>,
    /// Where the command being read began: the keys from there on are the
    /// command that ends recording, and are left out.
    settled: usize,
    /// `kmacro-counter`, the value before the last change, and the value
    /// when the macro started.
    pub counter: i64,
    pub last_counter: i64,
    pub counter_start: i64,
    /// The format of the counter: `%d` with flags and width, as Emacs's.
    pub format: String,
    /// The format for macros defined from now on.
    pub default_format: String,
    /// A value `macro-set-counter` gave outside a macro, for the next one.
    pub initial: Option<i64>,
    /// Macros given a name, as `kmacro-name-last-macro`.
    named: BTreeMap<String, Vec<UserInput>>,
}
impl Default for Replay {
    fn default() -> Self {
        Self {
            recording: None,
            appending: false,
            last: vec![],
            ring: VecDeque::new(),
            settled: 0,
            counter: 0,
            last_counter: 0,
            counter_start: 0,
            format: "%d".into(),
            default_format: "%d".into(),
            initial: None,
            named: BTreeMap::new(),
        }
    }
}
impl Replay {
    pub fn recording(&self) -> bool {
        self.recording.is_some()
    }
    /// Starts recording, as `kmacro-start-macro`: the last macro goes on the
    /// ring and the counter starts at `counter`, or 0. Appending, the keys
    /// go on after the last macro's and the counter carries on.
    pub fn start(&mut self, counter: Option<i64>, append: bool) {
        self.settled = 0;
        self.appending = append && !self.last.is_empty();
        if self.appending {
            self.recording = Some(self.last.clone());
            self.settled = self.last.len();
            return;
        }
        self.recording = Some(vec![]);
        self.push_ring();
        self.counter = counter.or(self.initial.take()).unwrap_or(0);
        self.counter_start = self.counter;
        self.last_counter = self.counter;
        self.format = self.default_format.clone();
    }
    /// Ends recording; the keys that asked for it are not part of the macro.
    /// An empty macro is ignored, as `kmacro-end-macro` does, and the one
    /// before stays; false then.
    pub fn stop(&mut self) -> bool {
        let Some(mut keys) = self.recording.take() else {
            return false;
        };
        keys.truncate(self.settled);
        if keys.is_empty() {
            self.last.clear();
            while self.last.is_empty()
                && let Some(earlier) = self.ring.pop_front()
            {
                self.split(earlier);
            }
            return false;
        }
        self.last = keys;
        true
    }
    /// Drops what is being recorded, as `C-g` does with
    /// `kmacro-keyboard-quit`: the macro before is the last again.
    pub fn abort(&mut self) {
        if self.recording.take().is_some()
            && !self.appending
            && let Some(earlier) = self.ring.pop_front()
        {
            self.split(earlier);
        }
    }
    pub fn last(&self) -> &[UserInput] {
        &self.last
    }
    /// The second macro, `kmacro-call-ring-2nd`.
    pub fn second(&self) -> Option<&[UserInput]> {
        self.ring.front().map(|earlier| earlier.keys.as_slice())
    }
    /// A command begins, as the command loop says: the keys recorded so
    /// far are the macro's, whatever this command does.
    pub fn command_starts(&mut self) {
        if let Some(keys) = &self.recording {
            self.settled = keys.len();
        }
    }
    /// Records typed input.
    pub fn typed(&mut self, input: &UserInput) {
        if let Some(keys) = &mut self.recording {
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
    fn head(&self) -> Option<Macro> {
        (!self.last.is_empty()).then(|| Macro {
            keys: self.last.clone(),
            counter: self.counter,
            format: self.format.clone(),
        })
    }
    fn push_ring(&mut self) {
        if let Some(head) = self.head() {
            self.ring.push_front(head);
            self.ring.truncate(RING);
        }
    }
    fn split(&mut self, earlier: Macro) {
        self.last = earlier.keys;
        self.counter = earlier.counter;
        self.format = earlier.format;
    }
    /// The ring's next macro becomes the last, the last going to the end,
    /// as `kmacro-cycle-ring-next`; `previous` goes the other way.
    pub fn cycle(&mut self, previous: bool) -> Result<(), &'static str> {
        self.check_ring()?;
        let head = self.head().unwrap();
        if previous {
            let earlier = self.ring.pop_front().unwrap();
            self.split(earlier);
            self.ring.push_back(head);
        } else {
            self.ring.push_front(head);
            let earlier = self.ring.pop_back().unwrap();
            self.split(earlier);
        }
        Ok(())
    }
    /// The first two macros change places, as `kmacro-swap-ring`.
    pub fn swap(&mut self) -> Result<(), &'static str> {
        self.check_ring()?;
        let head = self.head().unwrap();
        let earlier = self.ring.pop_front().unwrap();
        self.split(earlier);
        self.ring.push_front(head);
        Ok(())
    }
    /// The last macro goes, the next one taking its place, as
    /// `kmacro-delete-ring-head`.
    pub fn delete_head(&mut self) -> Result<(), &'static str> {
        if self.last.is_empty() {
            return Err("No keyboard macro defined.");
        }
        match self.ring.pop_front() {
            Some(earlier) => self.split(earlier),
            None => self.last.clear(),
        }
        Ok(())
    }
    fn check_ring(&self) -> Result<(), &'static str> {
        if self.last.is_empty() {
            Err("No keyboard macro defined.")
        } else if self.ring.is_empty() {
            Err("Only one keyboard macro defined.")
        } else {
            Ok(())
        }
    }
    /// The counter as the format writes it.
    pub fn formatted(&self, value: i64) -> String {
        format_counter(&self.format, value)
    }
    /// Gives the last macro a name it keeps when others are recorded.
    pub fn name(&mut self, name: &str) -> Result<(), &'static str> {
        if self.last.is_empty() {
            return Err("No keyboard macro defined");
        }
        self.named.insert(name.to_owned(), self.last.clone());
        Ok(())
    }
    pub fn named(&self, name: &str) -> Option<&[UserInput]> {
        self.named.get(name).map(Vec::as_slice)
    }
}
/// `value` as an Emacs format with one integer directive: `%d`, `%x`,
/// `%X`, `%o`, `%c`, with `0`, `-` and `+` flags and a width; other text
/// stays as it is.
pub(in crate::interaction) fn format_counter(format: &str, value: i64) -> String {
    let mut out = String::new();
    let mut chars = format.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '%' {
            out.push(ch);
            continue;
        }
        if chars.peek() == Some(&'%') {
            chars.next();
            out.push('%');
            continue;
        }
        let (mut zero, mut left, mut plus) = (false, false, false);
        while let Some(&flag) = chars.peek() {
            match flag {
                '0' => zero = true,
                '-' => left = true,
                '+' => plus = true,
                _ => break,
            }
            chars.next();
        }
        let mut width = 0usize;
        while let Some(digit) = chars.peek().and_then(|ch| ch.to_digit(10)) {
            width = width * 10 + digit as usize;
            chars.next();
        }
        let body = match chars.next() {
            Some('x') => format!("{value:x}"),
            Some('X') => format!("{value:X}"),
            Some('o') => format!("{value:o}"),
            Some('c') => char::from_u32(value as u32).map_or(String::new(), String::from),
            _ if plus && value >= 0 => format!("+{value}"),
            _ => value.to_string(),
        };
        let pad = width.saturating_sub(body.chars().count());
        if left {
            out.push_str(&body);
            out.extend(std::iter::repeat_n(' ', pad));
        } else if zero {
            let (sign, digits) = match body.strip_prefix(['-', '+']) {
                Some(digits) => (&body[..1], digits),
                None => ("", body.as_str()),
            };
            out.push_str(sign);
            out.extend(std::iter::repeat_n('0', pad));
            out.push_str(digits);
        } else {
            out.extend(std::iter::repeat_n(' ', pad));
            out.push_str(&body);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(ch: char) -> UserInput {
        UserInput::Key(crate::interaction::KeyStroke::plain(
            crate::interaction::Key::Char(ch),
        ))
    }
    fn text(keys: Option<&[UserInput]>) -> String {
        super::super::kmacro::describe(keys.unwrap_or_default())
    }
    #[test]
    fn counters_format_as_emacs_writes_them() {
        assert_eq!(format_counter("%d", 7), "7");
        assert_eq!(format_counter("%03d.", 7), "007.");
        assert_eq!(format_counter("%-3d|", 7), "7  |");
        assert_eq!(format_counter("#%x", 255), "#ff");
        assert_eq!(format_counter("%c", 97), "a");
        assert_eq!(format_counter("100%%", 1), "100%");
    }
    #[test]
    fn the_ring_keeps_earlier_macros_and_an_empty_one_is_ignored() {
        let mut replay = Replay::default();
        let record = |replay: &mut Replay, keys: &[char]| {
            replay.start(None, false);
            for &ch in keys {
                replay.command_starts();
                replay.typed(&key(ch));
            }
            replay.command_starts();
            replay.typed(&key('z'));
            replay.stop()
        };
        assert!(record(&mut replay, &['a']));
        assert!(record(&mut replay, &['b']));
        assert_eq!(text(Some(replay.last())), "b");
        assert_eq!(text(replay.second()), "a");
        // Nothing recorded: the macro before is back.
        assert!(!record(&mut replay, &[]));
        assert_eq!(text(Some(replay.last())), "b");
        replay.cycle(false).unwrap();
        assert_eq!(text(Some(replay.last())), "a");
        replay.cycle(true).unwrap();
        assert_eq!(text(Some(replay.last())), "b");
        // Dropped while recording: the same.
        replay.start(None, false);
        replay.typed(&key('c'));
        replay.abort();
        assert_eq!(text(Some(replay.last())), "b");
        replay.delete_head().unwrap();
        assert_eq!(text(Some(replay.last())), "a");
    }
}
