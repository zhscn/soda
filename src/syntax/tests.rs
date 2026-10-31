use super::{
    Category,
    textmate::{Lines, Registry},
};
use crate::core::Snapshot;

fn snapshot(text: &str) -> Snapshot {
    Snapshot::new(text.to_owned(), 0)
}
/// Highlighted fragments of each line, as (text, category).
fn fragments(scope: &str, text: &str) -> Vec<Vec<(String, Category)>> {
    let mut registry = Registry::bundled();
    let grammar = registry.grammar(scope).expect("bundled grammar");
    let snapshot = snapshot(text);
    let mut lines = Lines::new(&registry, grammar);
    let runs = lines.highlights(&mut registry, &snapshot, 0..snapshot.line_count());
    assert!(registry.warnings.is_empty(), "{:?}", registry.warnings);
    runs.into_iter()
        .enumerate()
        .map(|(line, runs)| {
            let text = snapshot.line(line).unwrap();
            runs.into_iter()
                .map(|(range, category)| (text[range].to_owned(), category))
                .collect()
        })
        .collect()
}
fn has(lines: &[Vec<(String, Category)>], text: &str, category: Category) -> bool {
    lines
        .iter()
        .flatten()
        .any(|(t, c)| t == text && *c == category)
}

#[test]
fn bundled_languages_are_detected_by_name_and_extension() {
    let registry = Registry::bundled();
    let detect = |path: &str| {
        registry
            .detect(std::path::Path::new(path))
            .map(|l| l.id.clone())
    };
    assert_eq!(detect("src/main.rs").as_deref(), Some("rust"));
    assert_eq!(detect("Makefile").as_deref(), Some("makefile"));
    assert_eq!(detect("a/b.tsx").as_deref(), Some("typescriptreact"));
    assert_eq!(detect("x.unknown"), None);
}

#[test]
fn rust_keywords_strings_comments_and_functions() {
    let lines = fragments(
        "source.rust",
        "// note\nfn main() {\n    let s = \"a\\n\";\n    let n = 42u8;\n}\n",
    );
    assert!(has(&lines, "// note", Category::Comment), "{lines:?}");
    assert!(has(&lines, "fn", Category::Keyword), "{lines:?}");
    assert!(has(&lines, "main", Category::Function), "{lines:?}");
    assert!(has(&lines, "\\n", Category::Escape), "{lines:?}");
    assert!(
        lines[2]
            .iter()
            .any(|(t, c)| t.contains('a') && *c == Category::String)
    );
    assert!(
        lines[3]
            .iter()
            .any(|(t, c)| t.starts_with("42") && *c == Category::Number)
    );
}

#[test]
fn begin_end_rules_carry_state_across_lines() {
    let lines = fragments("source.python", "x = '''\nstill a string\n'''\ny = 1\n");
    assert_eq!(lines[1], [("still a string".to_owned(), Category::String)]);
    assert!(has(&lines, "1", Category::Number), "{lines:?}");
}

#[test]
fn every_bundled_grammar_compiles_and_scans() {
    let mut registry = Registry::bundled();
    let scopes: Vec<String> = [
        "source.rust",
        "source.python",
        "source.go",
        "source.js",
        "source.ts",
        "source.tsx",
        "source.json",
        "source.yaml",
        "source.shell",
        "source.lua",
        "source.makefile",
        "text.html.markdown",
        "source.diff",
    ]
    .map(String::from)
    .to_vec();
    let sample = "a = \"b\" # c\n  - [x](y) `z` { 1, 2 }\n";
    for scope in scopes {
        let grammar = registry
            .grammar(&scope)
            .unwrap_or_else(|| panic!("{scope}"));
        let snapshot = snapshot(sample);
        let mut lines = Lines::new(&registry, grammar);
        lines.highlights(&mut registry, &snapshot, 0..3);
    }
    assert!(registry.warnings.is_empty(), "{:?}", registry.warnings);
}

#[test]
fn edits_rescan_only_until_line_states_converge() {
    let mut registry = Registry::bundled();
    let grammar = registry.grammar("source.rust").unwrap();
    let text: String = (0..200).map(|i| format!("let x{i} = {i};\n")).collect();
    let before = snapshot(&text);
    let mut lines = Lines::new(&registry, grammar);
    lines.highlights(&mut registry, &before, 0..200);
    // An edit inside line 10 converges at line 11 and keeps the rest.
    let after = snapshot(&text.replacen("let x10 = 10;", "let x10 = 99;", 1));
    lines.update(&after);
    assert_eq!(lines.computed(), 10);
    let runs = lines.highlights(&mut registry, &after, 10..11);
    assert_eq!(lines.computed(), 200);
    assert!(!runs[0].is_empty());
    // Inserted lines shift the kept results.
    let inserted = snapshot(&after.text().replacen(
        "let x50 = 50;\n",
        "let x50 = 50;\n// new\n\n",
        1,
    ));
    lines.update(&inserted);
    assert_eq!(lines.computed(), 51);
    lines.highlights(&mut registry, &inserted, 51..53);
    assert_eq!(lines.computed(), 202);
    let mut fresh = Lines::new(&registry, grammar);
    assert_eq!(
        fresh.highlights(&mut registry, &inserted, 0..202),
        lines.highlights(&mut registry, &inserted, 0..202)
    );
    lines.update(&after);
    lines.highlights(&mut registry, &after, 0..200);
    // Text inserted at a line start keeps that line's start state.
    let at_start = snapshot(&after.text().replacen("let x20", "x; let x20", 1));
    lines.update(&at_start);
    let mut fresh = Lines::new(&registry, grammar);
    assert_eq!(
        fresh.highlights(&mut registry, &at_start, 0..200),
        lines.highlights(&mut registry, &at_start, 0..200)
    );
    lines.update(&after);
    lines.highlights(&mut registry, &after, 0..200);
    // Opening a block comment changes every following line until it closes.
    let open = snapshot(&text.replacen("let x10", "/* let x10", 1));
    lines.update(&open);
    let runs = lines.highlights(&mut registry, &open, 150..151);
    assert_eq!(runs[0], [(0.."let x150 = 150;".len(), Category::Comment)]);
    // Equal results to a fresh scan.
    let mut fresh = Lines::new(&registry, grammar);
    assert_eq!(
        fresh.highlights(&mut registry, &open, 0..200),
        lines.highlights(&mut registry, &open, 0..200)
    );
}

#[test]
fn a_scan_budget_leaves_unreached_lines_for_the_next_request() {
    let mut registry = Registry::bundled();
    let grammar = registry.grammar("source.rust").unwrap();
    let text: String = (0..5000).map(|i| format!("let x{i} = {i};\n")).collect();
    let snapshot = snapshot(&text);
    let mut lines = Lines::new(&registry, grammar);
    let range = 4990..5000;
    let runs = lines.highlights_within(
        &mut registry,
        &snapshot,
        range.clone(),
        Some(std::time::Duration::ZERO),
    );
    assert!(!lines.complete(&range, &snapshot));
    assert!(runs.iter().all(Vec::is_empty));
    while !lines.complete(&range, &snapshot) {
        lines.highlights_within(
            &mut registry,
            &snapshot,
            range.clone(),
            Some(std::time::Duration::from_millis(1)),
        );
    }
    assert!(
        lines
            .highlights(&mut registry, &snapshot, range)
            .iter()
            .all(|r| !r.is_empty())
    );
}

#[test]
fn every_bundled_pattern_compiles_with_oniguruma() {
    let mut registry = Registry::bundled();
    registry.compile_all();
    assert!(registry.warnings.is_empty(), "{:#?}", registry.warnings);
}

/// `SODA_BENCH_FILE=path cargo test --release -- --ignored bench --nocapture`
#[test]
#[ignore]
fn bench_full_and_incremental_highlighting() {
    let path = std::env::var("SODA_BENCH_FILE").unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    let mut registry = Registry::bundled();
    let scope = registry
        .detect(std::path::Path::new(&path))
        .unwrap()
        .scope
        .clone();
    let grammar = registry.grammar(&scope).unwrap();
    let before = snapshot(&text);
    let count = before.line_count();
    let mut lines = Lines::new(&registry, grammar);
    let start = std::time::Instant::now();
    lines.highlights(&mut registry, &before, 0..count);
    let full = start.elapsed();
    let middle = before.line_start(count / 2).unwrap();
    let mut edited = text.clone();
    edited.insert(middle, ' ');
    let after = snapshot(&edited);
    let start = std::time::Instant::now();
    lines.update(&after);
    lines.highlights(&mut registry, &after, count / 2..count / 2 + 60);
    let incremental = start.elapsed();
    println!(
        "{path}: {count} lines, {} KiB; full {full:?} ({:.0} lines/s); edit + screen {incremental:?}; cached {}",
        text.len() / 1024,
        count as f64 / full.as_secs_f64(),
        lines.computed()
    );
}
#[test]
fn line_comments_come_from_language_configurations() {
    let comment = |name: &str| super::line_comment(std::path::Path::new(name));
    assert_eq!(comment("a.rs").as_deref(), Some("//"));
    assert_eq!(comment("a.py").as_deref(), Some("#"));
    assert_eq!(comment("a.lua").as_deref(), Some("--"));
    // Written as an object with settings.
    assert_eq!(comment("Makefile").as_deref(), Some("#"));
    // Block comments only, and no language at all.
    assert_eq!(comment("a.md"), None);
    assert_eq!(comment("a.unknown"), None);
}
#[test]
fn every_language_configuration_parses() {
    for language in Registry::bundled().languages() {
        if let Some(source) = language.configuration {
            let parsed: Result<serde_json::Value, _> =
                serde_json::from_str(&super::textmate::plain_json(source));
            assert!(parsed.is_ok(), "{}: {parsed:?}", language.id);
        }
    }
}
#[test]
fn results_color_names_numbers_and_matches() {
    use super::results::runs;
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
