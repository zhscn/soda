//! Colours of results documents: file names, numbers and what was found.
use super::{Category, Runs};
use crate::interaction::grep::{location, row};
use regex::Regex;

/// The runs of one line of a results document.
pub(super) fn runs(line: &str, grouped: bool, pattern: Option<&Regex>) -> Runs {
    if grouped && row(line).is_some() {
        let start = line.len() - line.trim_start().len();
        let numbers = start
            + line[start..]
                .find(char::is_whitespace)
                .unwrap_or(line.len() - start);
        let text = numbers + (line[numbers..].len() - line[numbers..].trim_start().len());
        let mut runs = vec![(start..numbers, Category::Number)];
        if let Some(pattern) = pattern {
            runs.extend(
                pattern
                    .find_iter(&line[text..])
                    .filter(|found| !found.is_empty())
                    .map(|found| (text + found.start()..text + found.end(), Category::Match)),
            );
        }
        return runs;
    }
    if let Some((path, ..)) = location(line) {
        let start = line.len() - line.trim_start().len();
        let colon = start + path.len();
        let rest = &line[colon + 1..];
        let mut end = rest
            .find(|c: char| !c.is_ascii_digit() && c != ':')
            .unwrap_or(rest.len());
        if rest[..end].ends_with(':') {
            end -= 1;
        }
        return vec![
            (start..colon, Category::Namespace),
            (colon + 1..colon + 1 + end, Category::Number),
        ];
    }
    if grouped && !line.is_empty() && !line.starts_with(char::is_whitespace) {
        return vec![(0..line.len(), Category::Heading)];
    }
    vec![]
}
