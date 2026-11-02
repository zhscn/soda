use soda::editor::{enter, reindent, type_char};
use soda::{config::*, core::*, cpp::*};
use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicUsize, Ordering},
};
fn parsed(yaml: &str) -> ClangConfig {
    parse_config(
        yaml,
        &preset("LLVM").unwrap(),
        "Cpp",
        false,
        UnknownOptions::Error,
    )
    .unwrap()
    .unwrap()
}
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "soda-config-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn write(&self, path: &str, text: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn yaml_flow_nested_quoted_anchors_and_old_enum_spellings() {
    let c = parsed(
        "{BasedOnStyle: LLVM, IndentWidth: 4, AccessModifierOffset: -2, AlignAfterOpenBracket: BlockIndent, UseTab: ForIndentation}",
    );
    assert_eq!(c.rules.whitespace().indent_width, 4);
    assert_eq!(indent(&c.rules, "class C {\npublic:\n};", 1), 2);
    assert!(c.rules.expression().align_parentheses);
    assert_eq!(c.rules.whitespace().tabs, TabPolicy::ForIndentation);
    let c = parsed(
        "BraceWrapping: &braces\n  AfterExternBlock: true\n  AfterClass: true\nIndentWidth: '3' # comment\nIndentExternBlock: AfterExternBlock\nBreakBeforeBraces: Custom\nIncludeCategories:\n  - Regex: '^<.*>$'\n    Priority: 1\n",
    );
    assert_eq!(c.rules.whitespace().indent_width, 3);
    assert_eq!(c.rules.structure().extern_body, ExternIndentation::Indent);
    assert_eq!(c.values["IncludeCategories"][0]["Regex"], "^<.*>$");
    let c = parsed(
        "IndentWidth: 2\nBraceWrapping: &wrap {AfterClass: true}\nAlignConsecutiveAssignments: {Enabled: true, AcrossEmptyLines: true}\n",
    );
    assert_eq!(c.values["BraceWrapping"]["AfterClass"], true);
    assert_eq!(c.values["BraceWrapping"]["AfterFunction"], false);
    let c = parsed(
        "Cpp11BracedListStyle: false\nAlignOperands: false\nIndentAccessModifiers: true\nBreakConstructorInitializersBeforeComma: true\n",
    );
    assert_eq!(c.rules.initializer().layout, InitializerLayout::Block);
    assert_eq!(
        c.rules.expression().operand_alignment,
        OperandAlignment::None
    );
    assert_eq!(indent(&c.rules, "class C {\nint x;\n};", 1), 4);
    assert_eq!(
        c.rules.constructor().layout,
        ConstructorInitializers::AlignWithColon
    );
    assert_eq!(c.rules.constructor().width, 4);
}
#[test]
fn document_selection_inheritance_and_based_on_reset() {
    let text = "BasedOnStyle: LLVM\nIndentWidth: 3\n---\nLanguage: JavaScript\nIndentWidth: 8\n---\nLanguage: Cpp\nContinuationIndentWidth: 6\n";
    let c = parsed(text);
    assert_eq!(c.rules.whitespace().indent_width, 3);
    assert_eq!(c.rules.expression().continuation_width, 6);
    let c = parsed("IndentWidth: 3\n---\nLanguage: Cpp\nBasedOnStyle: Google\n");
    assert_eq!(c.rules.whitespace().indent_width, 2);
    assert_eq!(indent(&c.rules, "switch (x) {\ncase 1:\n}", 1), 2);
    let base = preset("LLVM").unwrap();
    assert!(
        parse_config(
            "Language: JavaScript\nIndentWidth: 8",
            &base,
            "Cpp",
            false,
            UnknownOptions::Error
        )
        .unwrap()
        .is_none()
    );
    assert!(
        parse_config(
            "Language: C\nIndentWidth: 7",
            &base,
            "Cpp",
            false,
            UnknownOptions::Error
        )
        .unwrap()
        .is_none()
    );
    assert_eq!(
        parse_config(
            "Language: C\nIndentWidth: 7",
            &base,
            "Cpp",
            true,
            UnknownOptions::Error
        )
        .unwrap()
        .unwrap()
        .rules
        .whitespace()
        .indent_width,
        7
    );
    assert_eq!(
        parse_config(
            "Language: Cpp\nIndentWidth: 5",
            &base,
            "C",
            false,
            UnknownOptions::Error
        )
        .unwrap()
        .unwrap()
        .rules
        .whitespace()
        .indent_width,
        5
    );
}
#[test]
fn invalid_configuration_is_atomic_and_diagnostic() {
    let base = preset("LLVM").unwrap();
    for text in [
        "IndentWidth: -1",
        "TabWidth: 0",
        "TabWidth: 99999",
        "UseTab: Sometimes",
        "NamespaceIndentation: true",
        "IndentWidth: x",
        "BasedOnStyle: Unknown",
        "IndentWidth: 2\nIndentWidth: 4",
        "IndentWidth: [2]",
        "IndentWidth: 2\n---\nIndentWidth: 3",
        "Language: Cpp\n---\nLanguage: Cpp",
        "[not, a, mapping]",
        "BraceWrapping: [oops]",
        "BasedOnStyle: &base LLVM\n---\nLanguage: Cpp\nBasedOnStyle: *base",
    ] {
        assert!(
            parse_config(text, &base, "Cpp", false, UnknownOptions::Error).is_err(),
            "{text}"
        );
    }
    assert_eq!(base.rules.whitespace().indent_width, 2);
    let e = parse_config("IndnetWidth: 4", &base, "Cpp", false, UnknownOptions::Error).unwrap_err();
    assert_eq!(e.option.as_deref(), Some("IndnetWidth"));
    let c = parse_config("IndnetWidth: 4", &base, "Cpp", false, UnknownOptions::Warn)
        .unwrap()
        .unwrap();
    assert_eq!(c.diagnostics[0].option, "IndnetWidth");
    assert_eq!(c.values["IndnetWidth"], 4);
    assert_eq!(
        parsed("IndentGotoLabels: false").diagnostics[0].option,
        "IndentGotoLabels"
    );
    assert!(parsed("IndentCaseBlocks: true").diagnostics.is_empty());
}
#[test]
fn directory_resolution_child_override_and_missing_candidates() {
    let t = Temp::new();
    t.write(".clang-format", "BasedOnStyle: Google\nIndentWidth: 3\n");
    t.write(
        "src/.clang-format",
        "BasedOnStyle: InheritParentConfig\nTabWidth: 5\n",
    );
    t.write("src/deep/x.cpp", "");
    let file = t.0.join("src/deep/new.cpp");
    let r = resolve_config(&file, &ConfigOptions::default()).unwrap();
    assert_eq!(r.config.rules.whitespace().indent_width, 3);
    assert_eq!(r.config.rules.whitespace().tab_width.get(), 5);
    assert_eq!(indent(&r.config.rules, "switch (x) {\ncase 1:\n}", 1), 3);
    assert_eq!(r.sources.len(), 2);
    assert!(r.config.inherit.is_none());
    assert!(r.searched.contains(&t.0.join("src/deep/.clang-format")));
    t.write("src/.clang-format", "IndentWidth: 7\n");
    let r = resolve_config(&file, &ConfigOptions::default()).unwrap();
    assert_eq!(r.config.rules.whitespace().indent_width, 7);
    assert_eq!(indent(&r.config.rules, "switch (x) {\ncase 1:\n}", 1), 0);
    assert_eq!(r.sources.len(), 1);
    t.write("src/_clang-format", "IndentWidth: 9\n");
    assert_eq!(
        resolve_config(&file, &ConfigOptions::default())
            .unwrap()
            .config
            .rules
            .whitespace()
            .indent_width,
        7
    );
}
#[test]
fn redirected_inheritance_cycles_unsuitable_language_and_fallback() {
    let t = Temp::new();
    t.write("styles/.clang-format", "BasedOnStyle: WebKit\n");
    t.write(
        "project/.clang-format",
        "BasedOnStyle: InheritParentConfig=../styles\nContinuationIndentWidth: 6\n",
    );
    let file = t.0.join("project/new.cpp");
    let r = resolve_config(&file, &ConfigOptions::default()).unwrap();
    assert_eq!(
        indent(
            &r.config.rules,
            "namespace a {\nnamespace b {\nint x;\n}\n}",
            2
        ),
        4
    );
    assert_eq!(r.config.rules.expression().continuation_width, 6);
    t.write(
        "styles/.clang-format",
        "BasedOnStyle: InheritParentConfig=../project\n",
    );
    assert!(
        resolve_config(&file, &ConfigOptions::default())
            .unwrap_err()
            .message
            .contains("cycle")
    );
    t.write(
        "project/.clang-format",
        "Language: JavaScript\nIndentWidth: 8\n",
    );
    t.write(".clang-format", "BasedOnStyle: LLVM\nIndentWidth: 5\n");
    assert_eq!(
        resolve_config(&file, &ConfigOptions::default())
            .unwrap()
            .config
            .rules
            .whitespace()
            .indent_width,
        5
    );
    t.write(
        "project/.clang-format",
        "BasedOnStyle: InheritParentConfig=../missing\n",
    );
    assert!(resolve_config(&file, &ConfigOptions::default()).is_err());
}
#[test]
fn config_widths_access_levels_and_disabled_format_reach_editor() {
    let c = parsed(
        "IndentWidth: 3\nIndentAccessModifiers: Always\nConstructorInitializerIndentWidth: 7\nBracedInitializerIndentWidth: 5\n",
    );
    let text = "class C {\npublic:\nint x;\n};";
    let state = EditorState::new(text);
    let tree = parse_snapshot_with_options(state.snapshot(), c.rules.parser_options());
    assert_eq!(
        compute_indent(state.snapshot(), &tree, 1, &c.rules)
            .unwrap()
            .target_column,
        3
    );
    assert_eq!(
        compute_indent(state.snapshot(), &tree, 2, &c.rules)
            .unwrap()
            .target_column,
        6
    );
    let c = parsed("IndentWidth: 3\nIndentAccessModifiers: AfterFirstAccessModifier\n");
    let text = "class C {\nint a;\npublic:\nint b;\n};";
    let state = EditorState::new(text);
    let tree = parse_snapshot_with_options(state.snapshot(), c.rules.parser_options());
    assert_eq!(
        compute_indent(state.snapshot(), &tree, 1, &c.rules)
            .unwrap()
            .target_column,
        3
    );
    assert_eq!(
        compute_indent(state.snapshot(), &tree, 3, &c.rules)
            .unwrap()
            .target_column,
        6
    );
    let c = parsed("DisableFormat: true\n");
    let mut editor = StandaloneEditor::new("class C {\n        public:\n};");
    editor
        .dispatch(reindent(editor.state(), 1, &c.rules).unwrap())
        .unwrap();
    assert_eq!(
        editor.state().snapshot().line(1).as_deref(),
        Some("        public:")
    );
}
#[test]
fn bundled_presets_match_llvm_23_when_reference_tool_is_available() {
    match Command::new("clang-format-23").arg("--version").output() {
        Ok(out) => assert!(out.status.success()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => panic!("{e}"),
    }
    for name in [
        "LLVM",
        "Google",
        "Chromium",
        "Mozilla",
        "WebKit",
        "GNU",
        "Microsoft",
        "clang-format",
        "none",
    ] {
        let out = Command::new("clang-format-23")
            .args([&format!("--style={name}"), "--dump-config"])
            .output()
            .unwrap();
        assert!(out.status.success());
        let values: serde_json::Value =
            serde_saphyr::from_str(std::str::from_utf8(&out.stdout).unwrap()).unwrap();
        assert_eq!(
            &preset(name).unwrap().values,
            values.as_object().unwrap(),
            "{name}"
        );
    }
}

#[test]
fn preprocessor_after_hash_spacing_is_a_local_atomic_edit() {
    let style = parsed("IndentPPDirectives: AfterHash\nPPIndentWidth: 2\n").rules;
    let source = "#if A\n#if B\n#define X 1\n#else\n#define X 2\n#endif\n#endif\n";
    let mut editor = StandaloneEditor::new(source);
    for line in 0..7 {
        editor
            .dispatch(reindent(editor.state(), line, &style).unwrap())
            .unwrap();
    }
    assert_eq!(
        editor.state().snapshot().text(),
        "#if A\n#  if B\n#    define X 1\n#  else\n#    define X 2\n#  endif\n#endif\n"
    );
    let mut editor = StandaloneEditor::new("#if A\n    \n#endif\n");
    let mut select = Transaction::new(0, vec![]);
    select.selection = Some(Selection::caret(10));
    editor.dispatch(select).unwrap();
    editor
        .dispatch(type_char(editor.state(), '#', &style).unwrap())
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "#if A\n#  \n#endif\n");
    assert_eq!(editor.state().selection().head, 9);
    editor.undo().unwrap();
    assert_eq!(editor.state().snapshot().text(), "#if A\n    \n#endif\n");
    let mut editor = StandaloneEditor::new("#if A\nbody();#define X 1\n#endif\n");
    let p = editor.state().snapshot().text().find("#define").unwrap();
    let mut select = Transaction::new(0, vec![]);
    select.selection = Some(Selection::caret(p));
    editor.dispatch(select).unwrap();
    editor
        .dispatch(enter(editor.state(), &style).unwrap())
        .unwrap();
    assert_eq!(
        editor.state().snapshot().text(),
        "#if A\nbody();\n#  define X 1\n#endif\n"
    );
}

#[test]
fn yaml_alias_merge_and_missing_parent_fallback() {
    let c = parsed(
        "AlignConsecutiveAssignments: &alignment {Enabled: true, AcrossEmptyLines: true}\nAlignConsecutiveDeclarations: {<<: *alignment, AcrossComments: true}\n",
    );
    assert_eq!(c.values["AlignConsecutiveDeclarations"]["Enabled"], true);
    assert_eq!(
        c.values["AlignConsecutiveDeclarations"]["AcrossComments"],
        true
    );
    let t = Temp::new();
    t.write(
        ".clang-format",
        "BasedOnStyle: InheritParentConfig\nIndentWidth: 5\n",
    );
    let options = ConfigOptions {
        fallback: "WebKit".into(),
        ..ConfigOptions::default()
    };
    let r = resolve_config(&t.0.join("new.cpp"), &options).unwrap();
    assert_eq!(r.config.rules.whitespace().indent_width, 5);
    assert_eq!(
        indent(
            &r.config.rules,
            "namespace a {\nnamespace b {\nint x;\n}\n}",
            2
        ),
        5
    );
}

#[test]
fn independent_initializer_widths_and_final_access_offset() {
    let c = parsed("BasedOnStyle: LLVM\nIndentWidth: 4\n");
    assert_eq!(indent(&c.rules, "class C {\npublic:\n};", 1), 2);
    let c = parsed("ConstructorInitializerIndentWidth: 7\nBracedInitializerIndentWidth: 5\n");
    for (text, line, target) in [
        ("Foo::Foo()\n: a_(1)\n{}", 1, 7),
        ("int values[] = {\nX,\n};", 1, 5),
    ] {
        let state = EditorState::new(text);
        assert_eq!(
            compute_indent(
                state.snapshot(),
                &parse_snapshot_with_options(state.snapshot(), c.rules.parser_options()),
                line,
                &c.rules
            )
            .unwrap()
            .target_column,
            target
        );
    }
    let c =
        parsed("Cpp11BracedListStyle: Block\nBracedInitializerIndentWidth: 5\nIndentWidth: 2\n");
    let state = EditorState::new("int values[] = {\nX,\n};");
    assert_eq!(
        compute_indent(
            state.snapshot(),
            &parse_snapshot_with_options(state.snapshot(), c.rules.parser_options()),
            1,
            &c.rules
        )
        .unwrap()
        .target_column,
        2
    );
}

fn indent(rules: &CppRules, text: &str, line: usize) -> usize {
    let state = EditorState::new(text);
    let tree = parse_snapshot_with_options(state.snapshot(), rules.parser_options());
    compute_indent(state.snapshot(), &tree, line, rules)
        .unwrap()
        .target_column
}

#[test]
fn capability_diagnostics_follow_effective_presets_overrides_and_sources() {
    let base = preset("LLVM").unwrap();
    let from_preset = preset("GNU").unwrap();
    assert!(
        from_preset
            .diagnostics
            .iter()
            .any(|d| d.option == "BraceWrapping" && d.document == 0)
    );
    for yaml in ["BasedOnStyle: GNU", "BreakBeforeBraces: GNU"] {
        let c = parsed(yaml);
        assert!(
            c.diagnostics
                .iter()
                .any(|d| d.option == "BraceWrapping" && d.document == 1)
        );
    }
    let inherited = parsed("BreakBeforeBraces: GNU\nAlignOperands: AlignAfterOperator");
    let c = parse_config(
        "IndentWidth: 3",
        &inherited,
        "Cpp",
        false,
        UnknownOptions::Error,
    )
    .unwrap()
    .unwrap();
    assert!(c.diagnostics.iter().any(|d| d.option == "BraceWrapping"));
    assert!(c.diagnostics.iter().any(|d| d.option == "AlignOperands"));
    let c = parse_config(
        "BreakBeforeBraces: Attach\nAlignOperands: DontAlign",
        &inherited,
        "Cpp",
        false,
        UnknownOptions::Error,
    )
    .unwrap()
    .unwrap();
    assert!(
        !c.diagnostics
            .iter()
            .any(|d| matches!(d.option.as_str(), "BraceWrapping" | "AlignOperands"))
    );
    let c = parse_config(
        "AlignOperands: AlignAfterOperator\n---\nLanguage: Cpp\nIndentWidth: 3",
        &base,
        "Cpp",
        false,
        UnknownOptions::Error,
    )
    .unwrap()
    .unwrap();
    assert_eq!(
        c.diagnostics
            .iter()
            .find(|d| d.option == "AlignOperands")
            .unwrap()
            .document,
        1
    );
    let c = parsed(
        "BraceWrapping: {IndentBraces: true}\n---\nLanguage: Cpp\nBreakBeforeBraces: Custom",
    );
    assert_eq!(
        c.diagnostics
            .iter()
            .find(|d| d.option == "BraceWrapping")
            .unwrap()
            .document,
        1
    );
    let c = parsed("BasedOnStyle: GNU\nBreakBeforeBraces: Attach");
    assert!(!c.diagnostics.iter().any(|d| d.option == "BraceWrapping"));
}

#[test]
fn native_and_yaml_styles_reject_invalid_widths_before_editing() {
    for key in [
        "IndentWidth",
        "ContinuationIndentWidth",
        "TabWidth",
        "ConstructorInitializerIndentWidth",
        "BracedInitializerIndentWidth",
        "PPIndentWidth",
    ] {
        assert!(
            parse_config(
                &format!("{key}: 4097"),
                &preset("LLVM").unwrap(),
                "Cpp",
                false,
                UnknownOptions::Error
            )
            .is_err(),
            "{key}"
        );
    }
    let candidates = [
        CppStyle {
            indent_width: usize::MAX,
            access_indent: AccessIndent::Always,
            ..CppStyle::default()
        },
        CppStyle {
            continuation_indent: usize::MAX,
            ..CppStyle::default()
        },
        CppStyle {
            tab_width: std::num::NonZeroUsize::new(usize::MAX).unwrap(),
            ..CppStyle::default()
        },
        CppStyle {
            constructor_indent: Some(4097),
            ..CppStyle::default()
        },
        CppStyle {
            braced_initializer_indent: Some(4097),
            ..CppStyle::default()
        },
        CppStyle {
            pp_indent_width: Some(4097),
            ..CppStyle::default()
        },
        CppStyle {
            access_specifier_offset: isize::MIN,
            ..CppStyle::default()
        },
        CppStyle {
            access_specifier_offset: isize::MAX,
            ..CppStyle::default()
        },
    ];
    for style in candidates {
        assert!(style.compile().is_err());
    }
    for width in [0, 4096] {
        let style = CppStyle {
            indent_width: width,
            access_specifier_offset: 0,
            ..CppStyle::default()
        };
        assert!(style.compile().is_ok());
        assert!(
            parsed(&format!(
                "IndentWidth: {width}\nAccessModifierOffset: -{width}"
            ))
            .rules
            .enabled()
        );
    }
}

#[test]
fn short_function_style_accepts_llvm_scalar_and_mapping_forms() {
    for style in [
        "None",
        "Empty",
        "Inline",
        "InlineOnly",
        "All",
        "true",
        "false",
        "'true'",
        "'false'",
    ] {
        let config = parsed(&format!("AllowShortFunctionsOnASingleLine: {style}\n"));
        assert!(!config.values["AllowShortFunctionsOnASingleLine"].is_object());
    }
    let config =
        parsed("AllowShortFunctionsOnASingleLine: {Empty: false, Inline: true, Other: false}\n");
    assert_eq!(
        config.values["AllowShortFunctionsOnASingleLine"]["Empty"],
        false
    );
    assert_eq!(
        config.values["AllowShortFunctionsOnASingleLine"]["Inline"],
        true
    );
    assert_eq!(
        config.values["AllowShortFunctionsOnASingleLine"]["Other"],
        false
    );
    for invalid in ["Unknown", "42", "[]", "{Unknown: true}", "{Empty: invalid}"] {
        let error = parse_config(
            &format!("AllowShortFunctionsOnASingleLine: {invalid}\n"),
            &preset("LLVM").unwrap(),
            "Cpp",
            false,
            UnknownOptions::Error,
        )
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("AllowShortFunctionsOnASingleLine")
        );
    }
}

#[test]
fn google_cpp_config_with_legacy_short_function_style_loads_from_disk() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::write(directory.path().join(".clang-format"), "---\nLanguage: Cpp\nBasedOnStyle: Google\nAccessModifierOffset: -2\nAllowShortFunctionsOnASingleLine: Empty\nAllowShortIfStatementsOnASingleLine: Never\nAllowShortLoopsOnASingleLine: false\nIncludeBlocks: Preserve\nIndentCaseLabels: false\n...\n").unwrap();
    let path = directory.path().join("file.cpp");
    std::fs::write(&path, "class A {\npublic:\n};\n").unwrap();
    let mut workspace = soda::files::Workspace::default();
    let document = workspace.open(&path).unwrap();
    let editor = workspace.editor(document).unwrap();
    assert_eq!(editor.model().document().whitespace().indent_width, 2);
    let configuration = workspace.file(document).unwrap().configuration().unwrap();
    assert_eq!(
        configuration.config.values["AllowShortFunctionsOnASingleLine"],
        "Empty"
    );
}

#[test]
fn bool_tab_and_extern_styles_compile_to_their_llvm_equivalents() {
    for (old, new) in [("true", "Always"), ("false", "Never")] {
        assert_eq!(
            parsed(&format!("UseTab: {old}")).rules,
            parsed(&format!("UseTab: {new}")).rules
        );
    }
    for (old, new) in [("true", "Indent"), ("false", "NoIndent")] {
        assert_eq!(
            parsed(&format!("IndentExternBlock: {old}")).rules,
            parsed(&format!("IndentExternBlock: {new}")).rules
        );
    }
}

#[test]
fn legacy_indent_aliases_reach_rules_and_capability_diagnostics() {
    assert_eq!(
        parsed("IndentFunctionDeclarationAfterType: true").rules,
        parsed("IndentWrappedFunctionNames: true").rules
    );
    assert!(
        !parsed("IndentFunctionDeclarationAfterType: true\nIndentWrappedFunctionNames: false")
            .rules
            .structure()
            .indent_wrapped_function_names
    );
    let c = parsed("IndentRequires: false");
    assert_eq!(c.values["IndentRequiresClause"], false);
    assert!(!c.rules.structure().indent_requires_clause);
    assert!(c.diagnostics.is_empty());
    assert_eq!(
        parsed("BreakConstructorInitializers: AfterComma")
            .rules
            .constructor()
            .layout,
        ConstructorInitializers::AlignFirstInitializer
    );
    assert_eq!(parsed("BreakConstructorInitializersBeforeComma: true\nBreakConstructorInitializers: BeforeColon").rules.constructor().layout, ConstructorInitializers::AlignWithColon);
    assert_eq!(parsed("BreakConstructorInitializersBeforeComma: true\nBreakConstructorInitializers: AfterColon").rules.constructor().layout, ConstructorInitializers::AlignFirstInitializer);
}

#[test]
fn preprocessor_leave_preserves_both_sides_of_hash_and_after_hash_uses_tabs() {
    let original = "  #  if A\n\t#\t define X 1\n  # endif\n";
    let c = parsed("IndentPPDirectives: Leave\nUseTab: Always");
    let mut editor = soda::editor::Editor::new(original, c.rules);
    for line in 0..3 {
        editor
            .execute(soda::editor::Command::Reindent(line))
            .unwrap();
    }
    assert_eq!(editor.state().snapshot().text(), original);
    let code = "#if A\n#define X 1\n#if B\n#define Y 2\n#endif\n#endif\n";
    for tabs in [
        "Never",
        "ForIndentation",
        "ForContinuationAndIndentation",
        "AlignWithSpaces",
        "Always",
    ] {
        let c = parsed(&format!(
            "IndentWidth: 4\nTabWidth: 4\nUseTab: {tabs}\nIndentPPDirectives: AfterHash"
        ));
        let mut editor = soda::editor::Editor::new(code, c.rules);
        for line in 0..6 {
            editor
                .execute(soda::editor::Command::Reindent(line))
                .unwrap();
        }
        let unit = if tabs == "Never" { "    " } else { "\t" };
        let expected = format!(
            "#if A\n#{unit}define X 1\n#{unit}if B\n#{unit}{unit}define Y 2\n#{unit}endif\n#endif\n"
        );
        assert_eq!(editor.state().snapshot().text(), expected, "{tabs}");
        editor.execute(soda::editor::Command::Undo).unwrap();
        editor.execute(soda::editor::Command::Redo).unwrap();
        assert_eq!(editor.state().snapshot().text(), expected, "{tabs}");
    }
}

#[test]
fn accepted_grammar_and_brace_options_report_unimplemented_behavior() {
    for yaml in [
        "IndentExportBlock: false",
        "RequiresExpressionIndentation: Keyword",
        "StatementAttributeLikeMacros: [SIGNAL]",
        "TypenameMacros: [TYPE]",
        "TypeNames: [Type]",
        "TemplateNames: [List]",
        "VariableTemplates: [variable]",
        "Macros: ['A=B']",
        "SkipMacroDefinitionBody: true",
        "BreakBeforeBraces: Whitesmiths",
    ] {
        let c = parsed(yaml);
        assert!(!c.diagnostics.is_empty(), "{yaml}");
    }
}

#[test]
fn negative_optional_widths_use_llvm_fallbacks_and_partial_style_diagnostics_clear() {
    for key in ["PPIndentWidth", "BracedInitializerIndentWidth"] {
        for sentinel in [-2, -100] {
            assert_eq!(
                parsed(&format!("{key}: {sentinel}")).rules,
                parsed(&format!("{key}: -1")).rules
            );
        }
    }
    let partial = parsed("Cpp11BracedListStyle: AlignFirstComment");
    assert!(
        partial
            .diagnostics
            .iter()
            .any(|d| d.option == "Cpp11BracedListStyle")
    );
    let supported = parse_config(
        "Cpp11BracedListStyle: FunctionCall",
        &partial,
        "Cpp",
        false,
        UnknownOptions::Error,
    )
    .unwrap()
    .unwrap();
    assert!(
        !supported
            .diagnostics
            .iter()
            .any(|d| d.option == "Cpp11BracedListStyle")
    );
}

#[test]
fn llvm_boolean_and_quoted_integer_spellings_compile_consistently() {
    for spelling in ["y", "yes", "on", "True", "TRUE"] {
        assert_eq!(
            parsed(&format!("IndentCaseLabels: '{spelling}'")).rules,
            parsed("IndentCaseLabels: true").rules
        );
    }
    for spelling in ["n", "no", "off", "False", "FALSE"] {
        assert_eq!(
            parsed(&format!("IndentCaseLabels: '{spelling}'")).rules,
            parsed("IndentCaseLabels: false").rules
        );
    }
    for spelling in ["0x4", "0b100", "0o4", "04"] {
        assert_eq!(
            parsed(&format!("IndentWidth: '{spelling}'")).rules,
            parsed("IndentWidth: 4").rules
        );
    }
    assert_eq!(
        parsed("AccessModifierOffset: '-0x2'").rules,
        parsed("AccessModifierOffset: -2").rules
    );
    assert_eq!(
        parsed("IndentWidth: '010'").rules.whitespace().indent_width,
        8
    );
    for yaml in [
        "ColumnLimit: 4294967296",
        "IntegerLiteralSeparator: {Binary: 2147483648}",
        "IndentWidth: '0xBADVALUE'",
    ] {
        assert!(
            parse_config(
                yaml,
                &preset("LLVM").unwrap(),
                "Cpp",
                false,
                UnknownOptions::Error
            )
            .is_err(),
            "{yaml}"
        );
    }
}

#[test]
fn typed_allman_brace_corrects_only_a_structural_opening_line_atomically() {
    let rules = parsed("BreakBeforeBraces: Allman").rules;
    let before = "void f()\n    ";
    let mut editor = soda::editor::Editor::new(before, rules.clone());
    editor
        .execute(soda::editor::Command::SetSelection(Selection::caret(
            before.len(),
        )))
        .unwrap();
    editor
        .execute(soda::editor::Command::TypeChar('{'))
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "void f()\n{");
    assert_eq!(editor.state().selection().head, "void f()\n{".len());
    editor.execute(soda::editor::Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), before);
    editor.execute(soda::editor::Command::Redo).unwrap();
    assert_eq!(editor.state().snapshot().text(), "void f()\n{");
    for before in ["const char *s = \"", "int values[] =\n    "] {
        let mut editor = soda::editor::Editor::new(before, rules.clone());
        editor
            .execute(soda::editor::Command::SetSelection(Selection::caret(
                before.len(),
            )))
            .unwrap();
        editor
            .execute(soda::editor::Command::TypeChar('{'))
            .unwrap();
        assert_eq!(editor.state().snapshot().text(), format!("{before}{{"));
    }
}

#[test]
fn completing_pp_branch_keyword_corrects_hash_spacing_without_touching_literals() {
    for layout in ["BeforeHash", "AfterHash"] {
        let rules = parsed(&format!(
            "IndentPPDirectives: {layout}\nIndentWidth: 4\nTabWidth: 4\nUseTab: ForIndentation"
        ))
        .rules;
        let before = "#if A\n";
        let mut editor = soda::editor::Editor::new(before, rules.clone());
        editor
            .execute(soda::editor::Command::SetSelection(Selection::caret(
                before.len(),
            )))
            .unwrap();
        for ch in "#endif".chars() {
            editor.execute(soda::editor::Command::TypeChar(ch)).unwrap();
        }
        assert_eq!(
            editor.state().snapshot().text(),
            "#if A\n#endif",
            "{layout}"
        );
        assert_eq!(editor.state().selection().head, "#if A\n#endif".len());
        editor.execute(soda::editor::Command::Undo).unwrap();
        assert_eq!(editor.state().snapshot().text(), before);
        editor.execute(soda::editor::Command::Redo).unwrap();
        assert_eq!(editor.state().snapshot().text(), "#if A\n#endif");
        let before = "#if A\n  #define TEXT \"";
        let mut editor = soda::editor::Editor::new(before, rules);
        editor
            .execute(soda::editor::Command::SetSelection(Selection::caret(
                before.len(),
            )))
            .unwrap();
        editor
            .execute(soda::editor::Command::TypeChar('e'))
            .unwrap();
        assert_eq!(editor.state().snapshot().text(), format!("{before}e"));
    }
}
