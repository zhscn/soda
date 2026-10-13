use soda::{
    config::{UnknownOptions, parse_config, preset},
    core::Selection,
    cpp::{NodeKind, parse},
    editor::{Command, Editor},
};

fn enter_case(input: &str, expected: &str, yaml: &str) {
    command_case(input, expected, yaml, Command::Enter);
}

fn command_case(input: &str, expected: &str, yaml: &str, command: Command) {
    let run = |input: &str, expected: &str| {
        let config = parse_config(
            yaml,
            &preset("LLVM").unwrap(),
            "Cpp",
            false,
            UnknownOptions::Error,
        )
        .unwrap()
        .unwrap();
        let caret = input.find('^').unwrap();
        let original = input.replacen('^', "", 1);
        let expected_caret = expected.find('^').unwrap();
        let expected_text = expected.replacen('^', "", 1);
        let mut editor = Editor::new(original.clone(), config.rules);
        editor
            .execute(Command::SetSelection(Selection::caret(caret)))
            .unwrap();
        // Prime the document cache so this also exercises the incremental path.
        editor.indentation(0).unwrap();
        editor.execute(command.clone()).unwrap();
        assert_eq!(
            editor.state().snapshot().text(),
            expected_text,
            "input: {input:?}, style: {yaml}"
        );
        assert_eq!(editor.state().selection(), Selection::caret(expected_caret));
        editor.execute(Command::Undo).unwrap();
        assert_eq!(editor.state().snapshot().text(), original);
        assert_eq!(editor.state().selection(), Selection::caret(caret));
        editor.execute(Command::Redo).unwrap();
        assert_eq!(editor.state().snapshot().text(), expected_text);
        assert_eq!(editor.state().selection(), Selection::caret(expected_caret));
    };
    run(input, expected);
    run(
        &input.replace('\n', "\r\n"),
        &expected.replace('\n', "\r\n"),
    );
}

#[test]
fn object_like_namespace_and_extern_macros_keep_structural_roles() {
    let definitions = "#define NAMESPACE_BEGIN namespace foo {\n#define NAMESPACE_END }\n";
    for (yaml, prefix) in [("", ""), ("NamespaceIndentation: All", "  ")] {
        enter_case(
            &format!("{definitions}NAMESPACE_BEGIN^\nNAMESPACE_END\n"),
            &format!("{definitions}NAMESPACE_BEGIN\n{prefix}^\nNAMESPACE_END\n"),
            yaml,
        );
        enter_case(
            &format!("{definitions}NAMESPACE_BEGIN\n{prefix}int x;\nNAMESPACE_END^\n"),
            &format!("{definitions}NAMESPACE_BEGIN\n{prefix}int x;\nNAMESPACE_END\n^\n"),
            yaml,
        );
    }
    enter_case(
        &format!("{definitions}namespace outer {{\nNAMESPACE_BEGIN^\nNAMESPACE_END\n}}\n"),
        &format!("{definitions}namespace outer {{\nNAMESPACE_BEGIN\n  ^\nNAMESPACE_END\n}}\n"),
        "NamespaceIndentation: Inner",
    );
    let definitions = "#define EXTERN_BEGIN extern \"C\" {\n#define EXTERN_END }\n";
    for (yaml, prefix) in [
        ("IndentExternBlock: NoIndent", ""),
        ("IndentExternBlock: Indent", "  "),
    ] {
        enter_case(
            &format!("{definitions}EXTERN_BEGIN^\nEXTERN_END\n"),
            &format!("{definitions}EXTERN_BEGIN\n{prefix}^\nEXTERN_END\n"),
            yaml,
        );
    }
}

#[test]
fn configured_block_macros_work_without_local_definitions() {
    let yaml = "MacroBlockBegin: '^NS_(BEGIN|HEAD)$'\nMacroBlockEnd: '^NS_.*_END$'\nUseTab: ForIndentation\nIndentWidth: 4\nTabWidth: 4";
    enter_case(
        "NS_BEGIN^\nNS_TABLE_END\n",
        "NS_BEGIN\n\t^\nNS_TABLE_END\n",
        yaml,
    );
    enter_case(
        "NS_HEAD(name)^\nNS_TABLE_END(name)\n",
        "NS_HEAD(name)\n\t^\nNS_TABLE_END(name)\n",
        yaml,
    );
    enter_case(
        "NS_BEGIN\n\twork();\nNS_TABLE_END^\n",
        "NS_BEGIN\n\twork();\nNS_TABLE_END\n^\n",
        yaml,
    );
}

#[test]
fn macro_bindings_follow_definitions_undef_and_agreeing_conditional_branches() {
    let source = "#if A\n#define OPEN namespace n {\n#else\n#define OPEN namespace n {\n#endif\n#define CLOSE }\nOPEN^\nCLOSE\n";
    enter_case(
        source,
        &source.replace("OPEN^", "OPEN\n  ^"),
        "NamespaceIndentation: All",
    );
    let source = "#ifndef HEADER_H\n#define HEADER_H\n#define OPEN namespace n {\n#define CLOSE }\nOPEN^\nCLOSE\n#endif\n";
    enter_case(
        source,
        &source.replace("OPEN^", "OPEN\n  ^"),
        "NamespaceIndentation: All",
    );
    for source in [
        "#define OPEN namespace n {\n#undef OPEN\nOPEN\nint x;\n",
        "#if A\n#define OPEN namespace n {\n#else\n#define OPEN\n#endif\nOPEN\nint x;\n",
        "#if A\n#define OPEN namespace n {\n#endif\nOPEN\nint x;\n",
        "#define OPEN(x) namespace x {\nOPEN(n)\nint x;\n",
        "#define OPEN namespace n { int x;\nOPEN\nint y;\n",
    ] {
        assert!(
            !parse(source)
                .nodes()
                .iter()
                .any(|n| n.kind == NodeKind::NamespaceBody),
            "{source}"
        );
    }
}

#[test]
fn conditional_directives_can_split_linkage_and_control_blocks() {
    enter_case(
        "#ifdef __cplusplus\nextern \"C\" {\n#endif^\nvoid f();\n#ifdef __cplusplus\n}\n#endif\n",
        "#ifdef __cplusplus\nextern \"C\" {\n#endif\n  ^\nvoid f();\n#ifdef __cplusplus\n}\n#endif\n",
        "IndentExternBlock: Indent",
    );
    enter_case(
        "void f() {\n#if A\n  if (x) {\n#else\n  if (y) {\n#endif^\n    work();\n  }\n  tail();\n}\n",
        "void f() {\n#if A\n  if (x) {\n#else\n  if (y) {\n#endif\n    ^\n    work();\n  }\n  tail();\n}\n",
        "",
    );
}

#[test]
fn block_macro_configuration_is_validated_and_has_no_unsupported_diagnostic() {
    let base = preset("LLVM").unwrap();
    let config = parse_config(
        "MacroBlockBegin: '^BEGIN$'\nMacroBlockEnd: '^END$'",
        &base,
        "Cpp",
        false,
        UnknownOptions::Error,
    )
    .unwrap()
    .unwrap();
    assert!(
        !config
            .diagnostics
            .iter()
            .any(|d| matches!(d.option.as_str(), "MacroBlockBegin" | "MacroBlockEnd"))
    );
    for key in ["MacroBlockBegin", "MacroBlockEnd"] {
        assert!(
            parse_config(
                &format!("{key}: '['"),
                &base,
                "Cpp",
                false,
                UnknownOptions::Error
            )
            .is_err()
        );
    }
    let mut style = soda::cpp::CppStyle::default();
    style.parser.macro_block_begin = "[".into();
    assert_eq!(style.compile().unwrap_err().field, "macro_block_begin");
}

#[test]
fn adjacent_directives_and_unmatched_define_braces_keep_separate_ranges() {
    let source =
        "#define OPEN namespace n {\n#define CLOSE }\n#if A\n#else\n#endif\nOPEN\nint x;\nCLOSE\n";
    let tree = parse(source);
    let directives = tree
        .nodes()
        .iter()
        .enumerate()
        .filter(|(_, n)| n.kind == NodeKind::PreprocessorDirective)
        .map(|(id, _)| &source[tree.range(id)])
        .collect::<Vec<_>>();
    assert_eq!(
        directives,
        [
            "#define OPEN namespace n {",
            "#define CLOSE }",
            "#if A",
            "#else",
            "#endif"
        ]
    );
    let body = tree
        .nodes()
        .iter()
        .find(|n| n.kind == NodeKind::NamespaceBody)
        .unwrap();
    assert!(!body.incomplete);
}

#[test]
fn typing_inside_a_macro_namespace_reindents_function_closers_atomically() {
    let definitions = "#define OPEN namespace n {\n#define CLOSE }\n";
    let config = parse_config(
        "NamespaceIndentation: All",
        &preset("LLVM").unwrap(),
        "Cpp",
        false,
        UnknownOptions::Error,
    )
    .unwrap()
    .unwrap();
    let mut editor = Editor::new(format!("{definitions}OPEN\nCLOSE\n"), config.rules);
    editor
        .execute(Command::SetSelection(Selection::caret(
            definitions.len() + "OPEN".len(),
        )))
        .unwrap();
    editor.execute(Command::Enter).unwrap();
    for ch in "void f() {".chars() {
        editor.execute(Command::TypeChar(ch)).unwrap();
    }
    editor.execute(Command::Enter).unwrap();
    assert_eq!(
        editor.state().snapshot().text(),
        format!("{definitions}OPEN\n  void f() {{\n    \nCLOSE\n")
    );
    let before = editor.state().snapshot().text().to_owned();
    let selection = editor.state().selection();
    // Selection explicitly fences input history so this assertion covers one key.
    editor.execute(Command::SetSelection(selection)).unwrap();
    editor.execute(Command::TypeChar('}')).unwrap();
    assert_eq!(
        editor.state().snapshot().text(),
        format!("{definitions}OPEN\n  void f() {{\n  }}\nCLOSE\n")
    );
    editor.execute(Command::Undo).unwrap();
    assert_eq!(editor.state().snapshot().text(), before);
    assert_eq!(editor.state().selection(), selection);
    editor.execute(Command::Redo).unwrap();
    editor.execute(Command::Enter).unwrap();
    assert_eq!(
        editor.state().snapshot().text(),
        format!("{definitions}OPEN\n  void f() {{\n  }}\n  \nCLOSE\n")
    );
}

#[test]
fn explicit_reindent_repairs_macro_bodies_and_closers() {
    let definitions = "#define OPEN namespace n {\n#define CLOSE }\n";
    command_case(
        &format!("{definitions}OPEN\n \t ^int x;\nCLOSE\n"),
        &format!("{definitions}OPEN\n  ^int x;\nCLOSE\n"),
        "NamespaceIndentation: All",
        Command::Reindent(3),
    );
    command_case(
        &format!("{definitions}OPEN\n  int x;\n \t ^CLOSE\n"),
        &format!("{definitions}OPEN\n  int x;\n^CLOSE\n"),
        "NamespaceIndentation: All",
        Command::Reindent(4),
    );
}

#[test]
fn enter_inside_conditional_case_and_reopened_scope_is_atomic() {
    enter_case(
        "#if A\nvoid f() {\n  switch (x) {\n  case 1:\n    first();^\n    second();\n  case 2:\n    other();\n  }\n}\n#endif\n",
        "#if A\nvoid f() {\n  switch (x) {\n  case 1:\n    first();\n    ^\n    second();\n  case 2:\n    other();\n  }\n}\n#endif\n",
        "",
    );
    enter_case(
        "void f() {\n  do {\n#if A\n  } while (a);\n#else\n    if (x) {\n      target();^\n    }\n  } while (b);\n#endif\n}\n",
        "void f() {\n  do {\n#if A\n  } while (a);\n#else\n    if (x) {\n      target();\n      ^\n    }\n  } while (b);\n#endif\n}\n",
        "",
    );
    enter_case(
        "namespace n {\nvoid f() {\n  target();^\n}\n",
        "namespace n {\nvoid f() {\n  target();\n  ^\n}\n",
        "",
    );
}
