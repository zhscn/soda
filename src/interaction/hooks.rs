//! Hooks map editor notices back to command lines: `hook EVENT FILTER
//! COMMAND` runs COMMAND when EVENT fires with a parameter that FILTER, a
//! regular expression, matches in full.
use regex::Regex;

pub struct Hook {
    pub event: &'static str,
    pub filter: String,
    matcher: Regex,
    pub command: String,
}
impl Hook {
    pub(super) fn new(event: &'static str, filter: &str, command: String) -> Result<Self, String> {
        let matcher = Regex::new(&format!("^(?:{filter})$")).map_err(|e| e.to_string())?;
        Ok(Self {
            event,
            filter: filter.into(),
            matcher,
            command,
        })
    }
}
/// Hooks in the order they were added, which is the order they run in.
#[derive(Default)]
pub struct Hooks(Vec<Hook>);
impl Hooks {
    pub(super) fn add(&mut self, hook: Hook) {
        self.0.push(hook);
    }
    /// Removes an event's hooks, or only those with this filter. Returns how
    /// many went.
    pub(super) fn remove(&mut self, event: &str, filter: Option<&str>) -> usize {
        let before = self.0.len();
        self.0
            .retain(|hook| hook.event != event || filter.is_some_and(|f| f != hook.filter));
        before - self.0.len()
    }
    pub fn matching(&self, event: &str, parameter: &str) -> Vec<String> {
        self.0
            .iter()
            .filter(|hook| hook.event == event && hook.matcher.is_match(parameter))
            .map(|hook| hook.command.clone())
            .collect()
    }
}
