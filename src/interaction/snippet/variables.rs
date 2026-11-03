//! The values of a snippet's variables: the file, the line, the selection,
//! the clock, random numbers.
use crate::{application::Application, editor::DocumentId};
use std::{collections::HashMap, ops::Range};

/// The values of the variables a snippet can use, where it replaces
/// `range` of a document; `selected` when that is the selection, whose text
/// is `TM_SELECTED_TEXT`.
pub(in crate::interaction) fn variables(
    app: &Application,
    document: DocumentId,
    range: Range<usize>,
    selected: bool,
) -> HashMap<&'static str, String> {
    let mut values = HashMap::new();
    let Some(editor) = app.workspace().editor(document) else {
        return values;
    };
    let model = editor.model().document();
    let snapshot = model.snapshot();
    let text = snapshot.text();
    let line = snapshot.line_of(range.start).unwrap_or(0);
    let line_start = snapshot.line_start(line).unwrap_or(0);
    let line_end = text[range.start..]
        .find('\n')
        .map_or(text.len(), |at| range.start + at);
    let is_word = super::super::completion::is_word;
    let word_start = text[..range.start]
        .char_indices()
        .rev()
        .take_while(|(_, ch)| is_word(*ch))
        .last()
        .map_or(range.start, |(at, _)| at);
    let word_end = text[range.start..]
        .char_indices()
        .find(|(_, ch)| !is_word(*ch))
        .map_or(text.len(), |(at, _)| range.start + at);
    let mut set = |name: &'static str, value: String| {
        values.insert(name, value);
    };
    set(
        "TM_SELECTED_TEXT",
        if selected {
            text[range.clone()].to_owned()
        } else {
            String::new()
        },
    );
    set(
        "TM_CURRENT_LINE",
        text[line_start..line_end].trim_end_matches('\r').to_owned(),
    );
    set("TM_CURRENT_WORD", text[word_start..word_end].to_owned());
    set("TM_LINE_INDEX", line.to_string());
    set("TM_LINE_NUMBER", (line + 1).to_string());
    set("CURSOR_INDEX", "0".into());
    set("CURSOR_NUMBER", "1".into());
    let path = app.workspace().file(document).and_then(|file| file.path());
    let root = app.root_of(document);
    let shown = |path: Option<&std::path::Path>| {
        path.map_or_else(String::new, |path| path.to_string_lossy().into_owned())
    };
    set(
        "TM_FILENAME",
        shown(path.and_then(|p| p.file_name()).map(std::path::Path::new)),
    );
    set(
        "TM_FILENAME_BASE",
        shown(path.and_then(|p| p.file_stem()).map(std::path::Path::new)),
    );
    set("TM_DIRECTORY", shown(path.and_then(|p| p.parent())));
    set("TM_FILEPATH", shown(path));
    set(
        "RELATIVE_FILEPATH",
        shown(path.map(|p| p.strip_prefix(&root).unwrap_or(p))),
    );
    set(
        "WORKSPACE_NAME",
        shown(root.file_name().map(std::path::Path::new)),
    );
    set("WORKSPACE_FOLDER", shown(Some(&root)));
    set("CLIPBOARD", app.clipboard().to_owned());
    let comment = model.language().profile().line_comment.clone();
    let block = comment.as_deref() == Some("//");
    set("LINE_COMMENT", comment.unwrap_or_default());
    set("BLOCK_COMMENT_START", if block { "/*" } else { "" }.into());
    set("BLOCK_COMMENT_END", if block { "*/" } else { "" }.into());
    for (name, value) in time_values() {
        set(name, value);
    }
    let mut random = Random::new();
    set("RANDOM", format!("{:06}", random.next() % 1_000_000));
    set("RANDOM_HEX", format!("{:06x}", random.next() & 0xff_ffff));
    let (high, low) = (random.next(), random.next());
    set(
        "UUID",
        format!(
            "{:08x}-{:04x}-4{:03x}-{:04x}-{:012x}",
            high >> 32,
            (high >> 16) & 0xffff,
            high & 0x0fff,
            0x8000 | (low >> 48) & 0x3fff,
            low & 0xffff_ffff_ffff
        ),
    );
    values
}
/// The local date and time.
fn time_values() -> Vec<(&'static str, String)> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let seconds = now as libc::time_t;
    // SAFETY: localtime_r writes only the struct it is given.
    let tm = unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&seconds, &mut tm);
        tm
    };
    let months = "January February March April May June July August September October \
                  November December";
    let days = "Sunday Monday Tuesday Wednesday Thursday Friday Saturday";
    let year = tm.tm_year + 1900;
    let month = months
        .split_whitespace()
        .nth(tm.tm_mon as usize)
        .unwrap_or_default();
    let day = days
        .split_whitespace()
        .nth(tm.tm_wday as usize)
        .unwrap_or_default();
    let offset = tm.tm_gmtoff / 60;
    vec![
        ("CURRENT_YEAR", year.to_string()),
        ("CURRENT_YEAR_SHORT", format!("{:02}", year % 100)),
        ("CURRENT_MONTH", format!("{:02}", tm.tm_mon + 1)),
        ("CURRENT_MONTH_NAME", month.into()),
        ("CURRENT_MONTH_NAME_SHORT", month[..3].into()),
        ("CURRENT_DATE", format!("{:02}", tm.tm_mday)),
        ("CURRENT_DAY_NAME", day.into()),
        ("CURRENT_DAY_NAME_SHORT", day[..3].into()),
        ("CURRENT_HOUR", format!("{:02}", tm.tm_hour)),
        ("CURRENT_MINUTE", format!("{:02}", tm.tm_min)),
        ("CURRENT_SECOND", format!("{:02}", tm.tm_sec)),
        ("CURRENT_SECONDS_UNIX", now.to_string()),
        (
            "CURRENT_TIMEZONE_OFFSET",
            format!(
                "{}{:02}:{:02}",
                if offset < 0 { '-' } else { '+' },
                offset.abs() / 60,
                offset.abs() % 60
            ),
        ),
    ]
}
/// SplitMix64 from the clock, enough for `RANDOM` and `UUID`.
struct Random(u64);
impl Random {
    fn new() -> Self {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64;
        let count = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        Self(nanos ^ count.wrapping_mul(0x9e37_79b9_7f4a_7c15))
    }
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }
}
