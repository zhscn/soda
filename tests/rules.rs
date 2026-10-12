use soda::editor::enter;
use soda::{config::*, core::*, cpp::*};
fn config(yaml: &str) -> ClangConfig {
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
fn query(text: &str, line: usize, rules: &CppRules) -> IndentDecision {
    let state = EditorState::new(text);
    let tree = parse_snapshot_with_options(state.snapshot(), rules.parser_options());
    compute_indent(state.snapshot(), &tree, line, rules).unwrap()
}
#[test]
fn clang_options_resolve_behavior_and_independent_widths() {
    let c = config(
        "IndentWidth: 3\nContinuationIndentWidth: 5\nNamespaceIndentation: Inner\nAccessModifierOffset: -2\nConstructorInitializerIndentWidth: 7\nBracedInitializerIndentWidth: -1\nPPIndentWidth: -1\n",
    );
    let r = &c.rules;
    assert_eq!(r.structure().namespace, NamespaceIndentation::Inner);
    assert_eq!(r.structure().access_offset, -2);
    assert_eq!(r.constructor().width, 7);
    assert_eq!(
        r.constructor().layout,
        ConstructorInitializers::AlignFirstInitializer
    );
    assert_eq!(r.initializer().width, 5);
    assert_eq!(r.directive().width, 3);
    for (text, line, target) in [
        ("namespace outer {\nint x;\n}", 1, 0),
        ("namespace outer {\nnamespace inner {\nint x;\n}\n}", 2, 3),
        ("class C {\npublic:\nint x;\n};", 1, 1),
        ("class C {\nint x;\n};", 1, 3),
        ("C::C()\n: a_(1) {}", 1, 7),
    ] {
        assert_eq!(query(text, line, r).target_column, target, "{text}");
    }
    let c = config("IndentWidth: 3\nIndentAccessModifiers: AfterFirstAccessModifier\n");
    assert_eq!(
        c.rules.structure().access,
        AccessIndent::AfterFirstAccessModifier
    );
    for (text, line, target) in [
        ("class C {\nint x;\npublic:\nint y;\n};", 1, 3),
        ("class C {\nint x;\npublic:\nint y;\n};", 2, 3),
        ("class C {\nint x;\npublic:\nint y;\n};", 3, 6),
    ] {
        assert_eq!(query(text, line, &c.rules).target_column, target, "{text}");
    }
}
#[test]
fn initializer_alignment_uses_actual_layout_and_missing_anchor_fallback() {
    let r =
        config("BreakConstructorInitializers: BeforeComma\nConstructorInitializerIndentWidth: 6\n")
            .rules;
    assert_eq!(
        r.constructor().layout,
        ConstructorInitializers::AlignWithColon
    );
    assert_eq!(r.constructor().width, 6);
    assert_eq!(
        query("C::C()\n    : a_(1),\nb_(2) {}", 2, &r).target_column,
        4
    );
    let r = config("ConstructorInitializerIndentWidth: 6\n").rules;
    assert_eq!(query("C::C()\n    :\n", 2, &r).target_column, 6);
    assert_eq!(
        query("C::C()\n    : a_(1),\nb_(2) {}", 2, &r).target_column,
        6
    );
}
#[test]
fn parser_macro_classification_is_typed_and_affects_structure() {
    let r=config("ForEachMacros: [EACH]\nIfMacros: [WHEN]\nStatementMacros: [my_statement]\nNamespaceMacros: [NS]\nAttributeMacros: [MY_ATTR]\nWhitespaceSensitiveMacros: [STR]\n").rules;
    let tree = parse_with_options(
        "EACH(x, values) work();\nWHEN(x) yes(); else no();\nNS(n) { int x; }\nMY_ATTR(x)\nvoid f() {}\n",
        r.parser_options(),
    );
    for kind in [
        NodeKind::ForStatement,
        NodeKind::IfStatement,
        NodeKind::NamespaceDecl,
        NodeKind::FunctionDefinition,
    ] {
        assert!(tree.nodes().iter().any(|n| n.kind == kind), "{kind:?}");
    }
    assert_eq!(
        query("void f() {\n  EACH(x, values)\nwork();\n}\n", 2, &r).target_column,
        4
    );
    assert_eq!(query("my_statement(x)\nnext();", 1, &r).target_column, 0);
    assert_eq!(query("NS(n) {\nint x;\n}", 1, &r).target_column, 0);
    let d = query("STR(a,\n x);", 1, &r);
    assert!(d.preserve);
    assert_eq!(d.role, IndentRole::PreservedMacro);
    for key in [
        "ForEachMacros",
        "IfMacros",
        "StatementMacros",
        "NamespaceMacros",
        "AttributeMacros",
        "WhitespaceSensitiveMacros",
    ] {
        assert!(
            parse_config(
                &format!("{key}: [bad-name]"),
                &preset("LLVM").unwrap(),
                "Cpp",
                false,
                UnknownOptions::Error
            )
            .is_err()
        );
    }
}
#[test]
fn parser_results_are_invalidated_by_grammar_changes_not_indent_changes() {
    let state = EditorState::new("EACH(x) work();");
    let a = config("ForEachMacros: [EACH]\n");
    let b = config("ForEachMacros: [OTHER]\n");
    let tree = parse_snapshot_with_options(state.snapshot(), a.rules.parser_options());
    assert_eq!(
        compute_indent(state.snapshot(), &tree, 0, &b.rules).unwrap_err(),
        EditError::AnalysisMismatch
    );
    let c = config("ForEachMacros: [EACH]\nIndentWidth: 4\n");
    assert!(compute_indent(state.snapshot(), &tree, 0, &c.rules).is_ok());
}

#[test]
fn record_member_rules_do_not_change_enum_indentation() {
    let c = config(
        "IndentWidth: 3\nIndentAccessModifiers: Always\nAlignOperands: AlignAfterOperator\n",
    );
    assert_eq!(
        c.rules.expression().operand_alignment,
        OperandAlignment::AfterOperator
    );
    assert!(c.diagnostics.iter().any(|d| d.option == "AlignOperands"));
    assert_eq!(query("enum E {\nA,\n};", 1, &c.rules).target_column, 3);
    assert_eq!(query("class C {\nint x;\n};", 1, &c.rules).target_column, 6);
}

#[test]
fn file_and_editor_styles_produce_identical_atomic_edits_with_mixed_tabs() {
    for (name, tabs) in [
        ("Never", TabPolicy::Never),
        ("ForIndentation", TabPolicy::ForIndentation),
        (
            "ForContinuationAndIndentation",
            TabPolicy::ForContinuationAndIndentation,
        ),
        ("AlignWithSpaces", TabPolicy::AlignWithSpaces),
        ("Always", TabPolicy::Always),
    ] {
        let c = config(&format!(
            "IndentWidth: 3\nContinuationIndentWidth: 5\nTabWidth: 8\nUseTab: {name}\nNamespaceIndentation: Inner\nAccessModifierOffset: -2\nIndentExternBlock: NoIndent\nIndentWrappedFunctionNames: true\nBreakBeforeTernaryOperators: true\nCpp11BracedListStyle: FunctionCall\nBracedInitializerIndentWidth: -1\nConstructorInitializerIndentWidth: 6\nBreakConstructorInitializers: BeforeComma\nPPIndentWidth: -1\n"
        ));
        let native = CppStyle {
            indent_width: 3,
            continuation_indent: 5,
            tab_width: std::num::NonZeroUsize::new(8).unwrap(),
            tabs,
            namespace_indentation: NamespaceIndentation::Inner,
            access_specifier_offset: 1,
            indent_extern_body: Some(false),
            brace_init_continuation: true,
            constructor_indent: Some(6),
            constructor_initializers: ConstructorInitializers::AlignWithColon,
            ..CppStyle::default()
        }
        .compile()
        .unwrap();
        assert_eq!(native.structure(), c.rules.structure());
        assert_eq!(native.expression(), c.rules.expression());
        assert_eq!(native.initializer(), c.rules.initializer());
        assert_eq!(native.constructor(), c.rules.constructor());
        assert_eq!(native.directive(), c.rules.directive());
        assert_eq!(native.whitespace(), c.rules.whitespace());
        for input in [
            "void f() {\n \tcall(first,|second);\n}",
            "class C {\npublic:|\n};",
            "C::C()\n \t: a_(1),|b_(2) {}",
        ] {
            let position = input.find('|').unwrap();
            let text = input.replace('|', "");
            let mut results = Vec::new();
            for rules in [&native, &c.rules] {
                let mut editor = Editor::new(text.clone());
                let mut selection = Transaction::new(0, vec![]);
                selection.selection = Some(Selection::caret(position));
                editor.dispatch(selection).unwrap();
                let tx = enter(editor.state(), rules).unwrap();
                editor.dispatch(tx).unwrap();
                results.push((
                    editor.state().snapshot().text().to_owned(),
                    editor.state().selection(),
                ));
                assert!(editor.undo().unwrap());
                assert_eq!(editor.state().snapshot().text(), text);
                assert_eq!(editor.state().selection(), Selection::caret(position));
            }
            assert_eq!(results[0], results[1], "{name}: {input}");
        }
    }
}
