//! Option spellings captured from the pinned LLVM Format.cpp mapping traits.
use serde_json::{Value, json};
use soda::config::{UnknownOptions, parse_config, preset};
fn fixture() -> Value {
    serde_json::from_str(include_str!("fixtures/clang_format_options.json")).unwrap()
}
fn patch(path: &str, value: Value) -> Value {
    path.split('.').rev().fold(value, |value, key| {
        if let Some(key) = key.strip_suffix("[]") {
            json!({key: [value]})
        } else {
            json!({key: value})
        }
    })
}
#[test]
fn all_llvm_enum_spellings_are_accepted() {
    let base = preset("LLVM").unwrap();
    let mut errors = Vec::new();
    for case in fixture()["cases"].as_array().unwrap() {
        let path = case["option"].as_str().unwrap();
        for spelling in case["values"].as_array().unwrap() {
            let yaml = patch(path, spelling.clone()).to_string();
            if let Err(error) = parse_config(&yaml, &base, "Cpp", false, UnknownOptions::Error) {
                errors.push(format!("{path}: {spelling}: {error}"));
            }
        }
    }
    assert!(errors.is_empty(), "{}", errors.join("\n"));
}
#[test]
fn option_inventory_matches_the_llvm_mapping() {
    let fixture = fixture();
    let expected: std::collections::BTreeSet<_> = fixture["keys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|key| key.as_str().unwrap().to_owned())
        .collect();
    let actual: std::collections::BTreeSet<_> = serde_json::from_str::<Value>(include_str!(
        "../src/config/schema.json"
    ))
    .unwrap()["options"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    assert_eq!(actual, expected);
}
#[test]
fn nested_compatibility_keys_are_accepted() {
    let base = preset("LLVM").unwrap();
    for (path, _) in fixture()["nested_aliases"].as_object().unwrap() {
        let yaml = patch(path, json!(3)).to_string();
        parse_config(&yaml, &base, "Cpp", false, UnknownOptions::Error).unwrap();
    }
}

#[test]
fn optional_sequences_and_nested_fields_have_types_independent_of_presets() {
    let base = preset("LLVM").unwrap();
    for yaml in [
        "TypeNames: 123",
        "TypenameMacros: true",
        "RawStringFormats: [42]",
        "RawStringFormats: [{Unknown: true}]",
        "IncludeCategories: [{Priority: bad}]",
        "BreakBinaryOperations: {PerOperator: [{Operators: ['not-an-operator']}]}",
        "BraceWrapping: {AfterExternBlock: invalid}",
        "IndentCaseBlocks: invalid",
        "AlignConsecutiveShortCaseStatements: None",
        "SortIncludes: Invalid",
    ] {
        assert!(
            parse_config(yaml, &base, "Cpp", false, UnknownOptions::Error).is_err(),
            "{yaml}"
        );
    }
    for yaml in [
        "RawStringFormats: [{Language: Cpp, Delimiters: [cpp], BasedOnStyle: LLVM}]",
        "IncludeCategories: [{Regex: '^<.*>$', Priority: 1, SortPriority: 0, CaseSensitive: true}]",
        "BreakBinaryOperations: {Default: Never, PerOperator: [{Operators: ['+', '-'], Style: OnePerLine, MinChainLength: 3}]}",
        "SortIncludes: {Enabled: true, Natural: true}",
    ] {
        parse_config(yaml, &base, "Cpp", false, UnknownOptions::Error).unwrap();
    }
}

#[test]
fn reference_layouts_restore_indentation_for_each_rule_profile() {
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/clang_format_indent_options.json")).unwrap();
    let base = preset("LLVM").unwrap();
    let mut failures = Vec::new();
    for case in fixture["cases"].as_array().unwrap() {
        let expected = case["expected"].as_str().unwrap();
        let config = parse_config(
            &case["options"].to_string(),
            &base,
            "Cpp",
            false,
            UnknownOptions::Error,
        )
        .unwrap()
        .unwrap();
        let perturbed: String = expected
            .split_inclusive('\n')
            .map(|line| line.trim_start_matches([' ', '\t']))
            .collect();
        let mut editor = soda::editor::Editor::new(perturbed, config.rules);
        for line in 0..editor.state().snapshot().line_count() {
            // Blank editing lines carry indentation for the next input; a full
            // formatter's empty-line whitespace cleanup is a separate behavior.
            if editor
                .state()
                .snapshot()
                .line(line)
                .unwrap()
                .trim()
                .is_empty()
            {
                continue;
            }
            editor
                .execute(soda::editor::Command::Reindent(line))
                .unwrap();
        }
        if editor.state().snapshot().text() != expected {
            failures.push(format!(
                "{}\nexpected: {:?}\nactual: {:?}",
                case["name"],
                expected,
                editor.state().snapshot().text()
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

fn drop_continuation(editor: &mut soda::editor::Editor) {
    let state = editor.state();
    let snapshot = state.snapshot();
    let head = state.selection().head;
    let line = snapshot.line_of(head).unwrap();
    let start =
        snapshot.line_start(line).unwrap() + snapshot.leading_whitespace(line).unwrap().len_bytes();
    if start < head {
        let tx = soda::core::Transaction::new(
            snapshot.version(),
            vec![soda::core::Change::new(start..head, "")],
        );
        editor.execute(soda::editor::Command::Apply(tx)).unwrap();
    }
}
#[test]
fn reference_layouts_survive_typing_from_scratch() {
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/clang_format_indent_options.json")).unwrap();
    let base = preset("LLVM").unwrap();
    let mut failures = Vec::new();
    for case in fixture["cases"].as_array().unwrap() {
        // Enter after a wrapped return type cannot know that a function name,
        // not an ordinary continuation, follows; reindent covers that layout.
        // Likewise a link of a conditional chain whose condition wraps
        // shows that it is a link only when the `?` on the next line comes.
        if case["name"] == "wrapped-name-False" || case["name"] == "conditional-wrapped-link" {
            continue;
        }
        let expected = case["expected"].as_str().unwrap();
        let config = parse_config(
            &case["options"].to_string(),
            &base,
            "Cpp",
            false,
            UnknownOptions::Error,
        )
        .unwrap()
        .unwrap();
        let mut editor = soda::editor::Editor::new("", config.rules);
        for line in expected.split_inclusive('\n') {
            for ch in line.trim_start_matches([' ', '\t']).chars() {
                let command = if ch == '\n' {
                    soda::editor::Command::Enter
                } else {
                    soda::editor::Command::TypeChar(ch)
                };
                let enter = matches!(command, soda::editor::Command::Enter);
                editor.execute(command).unwrap();
                // The replay types comment markers itself, so it takes back
                // the marker Enter continues a comment with.
                if enter {
                    drop_continuation(&mut editor);
                }
            }
        }
        if editor.state().snapshot().text() != expected {
            failures.push(case["name"].as_str().unwrap().to_owned());
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
