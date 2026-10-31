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
    let profile = crate::language::catalog()
        .detect(std::path::Path::new(&path))
        .unwrap();
    let crate::language::Analyzer::TextMate { scope } = &profile.analyzer else {
        panic!("{path} is not in a TextMate language");
    };
    let grammar = registry.grammar(scope).unwrap();
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
/// Whether the place marked `|` in `text` is inside a comment or a string.
fn literal(scope: &str, text: &str) -> bool {
    let position = text.find('|').unwrap();
    let text = text.replacen('|', "", 1);
    super::Tokens::new(scope).in_literal(&snapshot(&text), position)
}
#[test]
fn literals_are_told_from_code_between_characters() {
    let rust = |text| literal("source.rust", text);
    assert!(rust("let a = \"x|y\";"));
    assert!(rust("let a = \"x\\n|y\";"));
    // Finished, or not yet.
    assert!(!rust("let a = \"x\"|;"));
    assert!(!rust("let a = \"x\"|"));
    assert!(rust("let a = \"x|"));
    assert!(!rust("let a = |\"x\";"));
    assert!(rust("/* a| b */"));
    assert!(rust("/* a|"));
    assert!(!rust("/* a */|"));
    assert!(rust("/* a\n b| */"));
    assert!(!rust("/* a\n */ b|"));
    assert!(rust("x(); // a| b"));
    assert!(rust("x(); // a|"));
    assert!(rust(
        "x(); // a|
b"
    ));
    assert!(!rust("x(); // a\nb|"));
    assert!(!rust("fn |main() {}"));
    let python = |text| literal("source.python", text);
    assert!(python("# a|"));
    assert!(python("x = 'a|"));
    assert!(!python("x = 'a'|"));
    let lua = |text| literal("source.lua", text);
    assert!(lua("-- a|"));
    assert!(!lua("local a|"));
}
#[test]
fn tokens_share_one_cache_and_follow_the_snapshot() {
    let tokens = super::Tokens::new("source.rust");
    let copy = tokens.clone();
    let before = snapshot("fn a() {}\n");
    let (runs, complete) = tokens.lines(&before, 0..1, None);
    assert!(complete && !runs[0].is_empty());
    // A speculative clone asking about other text leaves no trace.
    let other = snapshot("// fn a() {}\n");
    assert!(copy.in_literal(&other, 5));
    assert!(!tokens.in_literal(&before, 5));
    let (runs, _) = tokens.lines(&before, 0..1, None);
    assert_eq!(runs[0][0].1, Category::Keyword);
}
#[test]
fn a_literal_out_of_reach_counts_as_code_until_scanning_gets_there() {
    use std::time::Duration;
    let text = format!("{}// a\n", "x\n".repeat(200));
    let text = snapshot(&text);
    let position = text.len_bytes() - 2;
    let mut registry = Registry::bundled();
    let grammar = registry.grammar("source.rust").unwrap();
    let mut lines = Lines::new(&registry, grammar);
    let budget = Some(Duration::ZERO);
    assert!(!lines.in_literal(&mut registry, &text, position, budget));
    assert!(lines.in_literal(&mut registry, &text, position, None));
    // Nothing is left to scan, so no budget is too small now.
    assert!(lines.in_literal(&mut registry, &text, position, budget));
}
#[test]
fn a_grammar_that_does_not_exist_has_no_tokens() {
    let tokens = super::Tokens::new("source.nothing");
    let text = snapshot("x\n");
    assert_eq!(tokens.lines(&text, 0..1, None), (vec![], true));
    assert!(!tokens.in_literal(&text, 0));
}
