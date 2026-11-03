//! Colours of results documents: file names, numbers and what was found.
use crate::{
    interaction::grep::{location, row},
    syntax::{Category, Runs},
};
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn results_color_names_numbers_and_matches() {
        use Category::*;
        let pattern = regex::Regex::new("needle").unwrap();
        // A file's name, then a row: the number 12 is not a match of 12.
        assert_eq!(runs("src/a.rs", true, Some(&pattern)), [(0..8, Heading)]);
        assert_eq!(runs("", true, None), []);
        assert_eq!(
            runs("  12:5  a needle, needle", true, Some(&pattern)),
            [(2..6, Number), (10..16, Match), (18..24, Match)]
        );
        let digits = regex::Regex::new("12").unwrap();
        assert_eq!(runs("  12:5  x", true, Some(&digits)), [(2..6, Number)]);
        // Compiler output names the location in the line.
        assert_eq!(
            runs("src/a.c:3:7: error: x", false, None),
            [(0..7, Namespace), (8..11, Number)]
        );
        assert_eq!(
            runs("src/a.c:3: note", true, None),
            [(0..7, Namespace), (8..9, Number)]
        );
        // Without rows, plain lines stay plain.
        assert_eq!(runs("  12:5  x", false, None), []);
        assert_eq!(runs("make: done", false, None), []);
    }
}
