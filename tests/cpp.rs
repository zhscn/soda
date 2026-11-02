use soda::editor::{enter, reindent, type_char};
use soda::{core::*, cpp::*};
use std::num::NonZeroUsize;
fn col(text: &str, line: usize, style: &CppStyle) -> IndentDecision {
    let s = EditorState::new(text);
    compute_indent(s.snapshot(), &parse(text), line, &style.compile().unwrap()).unwrap()
}
fn enter_at(input: &str, style: &CppStyle) -> String {
    let p = input.find('^').unwrap();
    let mut s = input.to_owned();
    s.remove(p);
    let mut e = StandaloneEditor::new(s);
    let mut tx = Transaction::new(0, vec![]);
    tx.selection = Some(Selection::caret(p));
    e.dispatch(tx).unwrap();
    e.dispatch(enter(e.state(), style.compile().unwrap()).unwrap())
        .unwrap();
    let mut out = e.state().snapshot().text().to_owned();
    out.insert(e.state().selection().head, '^');
    out
}
#[test]
fn configured_namespace_access_and_case_columns() {
    let mut s = CppStyle {
        namespace_indentation: NamespaceIndentation::Inner,
        ..CppStyle::default()
    };
    assert_eq!(
        enter_at("namespace out {^\n}\n", &s),
        "namespace out {\n^\n}\n"
    );
    assert_eq!(
        enter_at("namespace out {\nnamespace in {^\n}\n}\n", &s),
        "namespace out {\nnamespace in {\n    ^\n}\n}\n"
    );
    s.access_specifier_offset = 2;
    assert_eq!(col("class C {\npublic:\n};", 1, &s).target_column, 2);
    s.access_specifier_offset = -4;
    assert_eq!(col("    class C {\npublic:\n};", 1, &s).target_column, 0);
    s.indent_case_label = true;
    assert_eq!(col("switch (x) {\ncase 1:\n}", 1, &s).target_column, 4);
}
#[test]
fn expression_replay_uses_actual_layout() {
    let s = CppStyle::default();
    for (text, line, expected) in [
        ("  return \"aaa\"\n\"bbb\";\n", 1, 9),
        ("  x = c\n          ? aaa\n: bbb;\n", 2, 10),
        ("  if (check(setParam(\nx)))\n    ;\n", 1, 10),
        ("  f(a, bb +\ncc);\n", 1, 11),
        ("  struct S c = {\nX,\n  };\n", 1, 6),
        (
            "switch (x) {\ncase 1:\n    a();\n// about case 2\ncase 2:\n}\n",
            3,
            0,
        ),
        (
            "switch (x) {\ncase 1:\n    a();\n        // stray\ncase 2:\n}\n",
            3,
            4,
        ),
    ] {
        assert_eq!(col(text, line, &s).target_column, expected, "{text}");
    }
    let mut e = StandaloneEditor::new("  return WithColor(OS)\n.get()\n<< \"e\";\n");
    for line in [1, 2] {
        e.dispatch(reindent(e.state(), line, s.compile().unwrap()).unwrap())
            .unwrap();
    }
    assert_eq!(
        e.state().snapshot().text(),
        "  return WithColor(OS)\n             .get()\n         << \"e\";\n"
    );
}
#[test]
fn expression_style_and_ctor_variants() {
    let mut s = CppStyle {
        operand_alignment: OperandAlignment::None,
        ..CppStyle::default()
    };
    assert_eq!(enter_at("int x = a +^\n", &s), "int x = a +\n    ^\n");
    s.align_open_bracket = false;
    assert_eq!(
        enter_at("int y = f(aa,^ bb);\n", &s),
        "int y = f(aa,\n    ^bb);\n"
    );
    s = CppStyle {
        indent_width: 2,
        ..CppStyle::default()
    };
    assert_eq!(
        enter_at("int arr[] = {^\n};\n", &s),
        "int arr[] = {\n  ^\n};\n"
    );
    s.brace_init_continuation = true;
    assert_eq!(
        enter_at("int arr[] = {^\n};\n", &s),
        "int arr[] = {\n    ^\n};\n"
    );
    s = CppStyle::default();
    for (kind, n) in [
        (ConstructorInitializers::NormalIndent, 4),
        (ConstructorInitializers::ContinuationIndent, 4),
        (ConstructorInitializers::AlignFirstInitializer, 6),
        (ConstructorInitializers::AlignAfterColon, 6),
        (ConstructorInitializers::AlignWithColon, 4),
    ] {
        s.constructor_initializers = kind;
        assert_eq!(
            enter_at("Foo::Foo()\n    : a_(1),^\n{\n}\n", &s),
            format!("Foo::Foo()\n    : a_(1),\n{}^\n{{\n}}\n", " ".repeat(n))
        );
    }
    s.indent_wrapped_function_names = false;
    assert_eq!(
        col(
            "static std::map<int, int> &\n        foo::bar() {\n}\n",
            1,
            &s
        )
        .target_column,
        0
    );
    assert_eq!(col("int x =\nf();\n", 1, &s).target_column, 4);
}
#[test]
fn macro_continuation_and_conditional_reconciliation() {
    let s = CppStyle {
        indent_width: 2,
        ..CppStyle::default()
    };
    assert_eq!(col("#define F(x) \\\nbody(x)\n", 1, &s).target_column, 2);
    assert_eq!(
        col(
            "#define F(a, b) \\\n  impl((long)(a), \\\n(long)(b))\n",
            2,
            &s
        )
        .target_column,
        7
    );
    let text = "int h() {\n#ifdef WIN\n  if (a) {\n#else\n  if (b) {\n#endif\n    inner();\n  }\n  tail();\n}\n";
    for (line, n) in [(2, 2), (4, 2), (6, 4), (7, 2), (8, 2)] {
        assert_eq!(col(text, line, &s).target_column, n, "line {line}");
    }
    let s = CppStyle::default();
    for text in [
        "void f() {\n    do {\n        g();\n#ifdef A\n        h(x);\n    } while (x);\n#else\n        h(y);\n    } while (y);\n#endif\n    tail();\n}\n",
        "void f() {\n#ifdef A\n    if (x)\n#else\n    if (y)\n#endif\n        return;\n    tail();\n}\n",
    ] {
        let mut e = StandaloneEditor::new(text);
        let lines = e.state().snapshot().line_count();
        for line in 0..lines - 1 {
            e.dispatch(reindent(e.state(), line, s.compile().unwrap()).unwrap())
                .unwrap();
            assert_eq!(e.state().snapshot().text(), text, "line {line}");
        }
    }
}
#[test]
fn directive_depth_and_include_guards() {
    let s = CppStyle {
        indent_width: 2,
        pp_directive_indent: PPDirectiveIndent::BeforeHash,
        ..CppStyle::default()
    };
    let text = "#if A\n#if B\n#define X 1\n#else\n#define X 2\n#endif\n#endif\n";
    for (line, n) in [0, 2, 4, 2, 4, 2, 0].into_iter().enumerate() {
        assert_eq!(col(text, line, &s).target_column, n);
    }
    let guard = "#ifndef FOO\n#define FOO\n#if A\n#define X 1\n#endif\n#endif\n";
    for (line, n) in [0, 0, 0, 2, 0, 0].into_iter().enumerate() {
        assert_eq!(col(guard, line, &s).target_column, n);
    }
    assert_eq!(
        col("#ifndef FOO\n#define BAR\n#define X 1\n#endif", 2, &s).target_column,
        2
    );
}
#[test]
fn mixed_tabs_keep_structural_continuation_and_alignment_distinct() {
    let mut s = CppStyle {
        tabs: TabPolicy::ForIndentation,
        ..CppStyle::default()
    };
    for (iw, tw, structure, target, expected) in [
        (4, 4, 8, 11, "\t\t   "),
        (4, 8, 4, 4, "    "),
        (4, 8, 8, 11, "\t   "),
        (3, 8, 9, 12, "\t    "),
    ] {
        s.indent_width = iw;
        s.tab_width = NonZeroUsize::new(tw).unwrap();
        assert_eq!(
            materialize(
                structure,
                structure,
                target,
                s.compile().unwrap().whitespace()
            ),
            expected
        );
        assert_eq!(column_width(expected, 0, s.tab_width), target);
    }
    s = CppStyle {
        tabs: TabPolicy::ForIndentation,
        ..CppStyle::default()
    };
    assert_eq!(enter_at("void f() {^}\n", &s), "void f() {\n\t^\n}\n");
    assert_eq!(
        enter_at("Foo::Foo()\n\t: a_(1),^\n{\n}\n", &s),
        "Foo::Foo()\n\t: a_(1),\n      ^\n{\n}\n"
    );
    s.tabs = TabPolicy::ForContinuationAndIndentation;
    assert_eq!(
        materialize(4, 8, 11, s.compile().unwrap().whitespace()),
        "\t\t   "
    );
    s.tabs = TabPolicy::AlignWithSpaces;
    assert_eq!(
        materialize(4, 8, 11, s.compile().unwrap().whitespace()),
        "\t\t   "
    );
    assert_eq!(
        column_width("界\te\u{301}", 0, NonZeroUsize::new(8).unwrap()),
        9
    );
}
#[test]
fn stale_analysis_is_rejected_and_literal_contents_are_preserved() {
    let state = EditorState::new("int x;");
    assert_eq!(
        compute_indent(
            state.snapshot(),
            &parse("int y;"),
            0,
            &CppStyle::default().compile().unwrap()
        )
        .unwrap_err(),
        EditError::AnalysisMismatch
    );
    for text in ["auto s = R\"d(\n  keep\n)d\";", "/* a\n  keep\n*/"] {
        let mut e = StandaloneEditor::new(text);
        e.dispatch(reindent(e.state(), 1, CppStyle::default().compile().unwrap()).unwrap())
            .unwrap();
        assert_eq!(e.state().snapshot().text(), text);
    }
    assert_eq!(
        enter_at("void f() {^}\r\n", &CppStyle::default()),
        "void f() {\r\n    ^\r\n}\r\n"
    );
}

#[test]
fn typed_labels_and_closers_are_atomic_and_protected() {
    for (input, typed, expected) in [
        (
            "switch (x) {\n    ^\n}\n",
            "case 1:",
            "switch (x) {\ncase 1:^\n}\n",
        ),
        (
            "class C {\n    int a;\n    ^\n};\n",
            "public:",
            "class C {\n    int a;\npublic:^\n};\n",
        ),
        ("Foo::Foo()\n^\n{\n}\n", ":", "Foo::Foo()\n    :^\n{\n}\n"),
        (
            "void f() {\n    body();\n    ^\n",
            "}",
            "void f() {\n    body();\n}^\n",
        ),
        ("void f() {\n    ^\n}\n", "#", "void f() {\n#^\n}\n"),
        ("    int x = a ? b ^;\n", ":", "    int x = a ? b :^;\n"),
        (
            "void f() {\n    int a[] = {1^\n",
            "}",
            "void f() {\n    int a[] = {1}^\n",
        ),
        (
            "auto s = R\"(\nabc^\n)\";\n",
            ":",
            "auto s = R\"(\nabc:^\n)\";\n",
        ),
    ] {
        let caret = input.find('^').unwrap();
        let mut text = input.to_owned();
        text.remove(caret);
        let mut e = StandaloneEditor::new(text);
        let mut select = Transaction::new(0, vec![]);
        select.selection = Some(Selection::caret(caret));
        e.dispatch(select).unwrap();
        for ch in typed.chars() {
            let before = e.state().snapshot().text().to_owned();
            let selection = e.state().selection();
            let tx = type_char(e.state(), ch, CppStyle::default().compile().unwrap()).unwrap();
            e.dispatch(tx).unwrap();
            let after = e.state().snapshot().text().to_owned();
            e.undo().unwrap();
            assert_eq!(e.state().snapshot().text(), before);
            assert_eq!(e.state().selection(), selection);
            e.redo().unwrap();
            assert_eq!(e.state().snapshot().text(), after);
        }
        let mut out = e.state().snapshot().text().to_owned();
        out.insert(e.state().selection().head, '^');
        assert_eq!(out, expected);
    }
}

#[test]
fn enter_on_each_input_prefix_is_safe_and_reversible() {
    let sample = "namespace n {\nclass C {\npublic:\n    C();\n};\nC::C()\n    : a_(1),\n      b_{2}\n{\n    switch (x) {\n    case 1:\n        f([&] { return 1; });\n    default:\n        break;\n    }\n}\n}\n";
    for p in 0..=sample.len() {
        let mut e = StandaloneEditor::new(&sample[..p]);
        let mut select = Transaction::new(0, vec![]);
        select.selection = Some(Selection::caret(p));
        e.dispatch(select).unwrap();
        let a = enter(e.state(), CppStyle::default().compile().unwrap()).unwrap();
        let b = enter(e.state(), CppStyle::default().compile().unwrap()).unwrap();
        assert_eq!(a.changes, b.changes);
        assert_eq!(a.selection, b.selection);
        e.dispatch(a).unwrap();
        e.undo().unwrap();
        assert_eq!(e.state().snapshot().text(), &sample[..p]);
        assert_eq!(e.state().selection(), Selection::caret(p));
    }
}

#[test]
fn enter_at_unterminated_protected_eof_preserves_content() {
    assert_eq!(
        enter_at("auto s = R\"(abc^", &CppStyle::default()),
        "auto s = R\"(abc\n^"
    );
    // The comment continues with its stars under the opening `/*`.
    assert_eq!(
        enter_at("    /* abc^", &CppStyle::default()),
        "    /* abc\n     * ^"
    );
}

#[test]
fn tab_policies_keep_actual_parameter_alignment_as_spaces() {
    let text = "void f() {\n    call(first,\nnext);\n}\n";
    let mut s = CppStyle {
        tabs: TabPolicy::AlignWithSpaces,
        ..CppStyle::default()
    };
    let d = col(text, 2, &s);
    assert_eq!(d.target_column, 9);
    assert_eq!(d.structural_column, 4);
    assert_eq!(d.whitespace, "\t     ");
    s.tabs = TabPolicy::ForContinuationAndIndentation;
    assert_eq!(col(text, 2, &s).whitespace, "\t\t ");
    s.tabs = TabPolicy::ForIndentation;
    s.align_open_bracket = false;
    let d = col(text, 2, &s);
    assert_eq!(d.target_column, 8);
    assert_eq!(d.whitespace, "\t    ");
}

#[test]
fn unicode_sequences_and_single_column_tabs_follow_policy() {
    assert_eq!(
        column_width("👩‍💻\te\u{301}", 0, NonZeroUsize::new(4).unwrap()),
        5
    );
    let mut style = CppStyle {
        tab_width: NonZeroUsize::new(1).unwrap(),
        tabs: TabPolicy::ForIndentation,
        ..CppStyle::default()
    };
    assert_eq!(
        materialize(2, 2, 2, style.compile().unwrap().whitespace()),
        "\t\t"
    );
    style.tabs = TabPolicy::Always;
    assert_eq!(
        materialize(1, 1, 1, style.compile().unwrap().whitespace()),
        " "
    );
    assert_eq!(
        materialize(2, 2, 2, style.compile().unwrap().whitespace()),
        "\t\t"
    );
}

fn assert_atomic_input(
    input: &str,
    selected_bytes: usize,
    typed: Option<char>,
    style: &CppStyle,
    expected: &str,
) {
    let caret = input.find('^').unwrap();
    let text = input.replacen('^', "", 1);
    let selection = Selection {
        anchor: caret + selected_bytes,
        head: caret,
    };
    let mut editor = StandaloneEditor::new(text.clone());
    let mut select = Transaction::new(0, vec![]);
    select.selection = Some(selection);
    editor.dispatch(select).unwrap();
    let rules = style.compile().unwrap();
    let tx = match typed {
        Some(ch) => type_char(editor.state(), ch, &rules),
        None => enter(editor.state(), &rules),
    }
    .unwrap();
    editor.dispatch(tx).unwrap();
    let mut result = editor.state().snapshot().text().to_owned();
    result.insert(editor.state().selection().head, '^');
    assert_eq!(result, expected, "{input}");
    assert!(editor.undo().unwrap());
    assert_eq!(editor.state().snapshot().text(), text);
    assert_eq!(editor.state().selection(), selection);
    assert!(!editor.undo().unwrap());
}

#[test]
fn enter_replaces_existing_code_prefix_and_composes_auxiliary_spacing() {
    for disable_format in [false, true] {
        let style = CppStyle {
            disable_format,
            ..CppStyle::default()
        };
        for (input, selected_bytes, expected) in [
            (
                "void f() {\n    ^ \tfoo();\n}",
                0,
                // Structural indentation clears the line left blank; disabled
                // formatting only inherits and keeps it.
                if disable_format {
                    "void f() {\n    \n    ^foo();\n}"
                } else {
                    "void f() {\n\n    ^foo();\n}"
                },
            ),
            (
                "void f() {\n^old\ntext    foo();\n}",
                8,
                if disable_format {
                    "void f() {\n\n^foo();\n}"
                } else {
                    "void f() {\n\n    ^foo();\n}"
                },
            ),
        ] {
            assert_atomic_input(input, selected_bytes, None, &style, expected);
        }
    }
    for (input, expected) in [
        ("void f() {\n^    foo();\n}", "void f() {\n\n    ^foo();\n}"),
        (
            "void f() {\r\n^ \tfoo();\r\n}",
            "void f() {\r\n\r\n    ^foo();\r\n}",
        ),
        // A second Enter on an auto-indented blank line leaves it empty.
        (
            "void f() {\n    a();\n    ^\n}",
            "void f() {\n    a();\n\n    ^\n}",
        ),
    ] {
        assert_atomic_input(input, 0, None, &CppStyle::default(), expected);
    }
    let style = CppStyle {
        indent_width: 3,
        pp_directive_indent: PPDirectiveIndent::AfterHash,
        ..CppStyle::default()
    };
    assert_atomic_input(
        "#if X\n^old\ntext \t#define Y\n#endif",
        8,
        None,
        &style,
        "#if X\n\n^#   define Y\n#endif",
    );
}

#[test]
fn enter_preserves_literal_suffix_bytes_with_formatting_enabled_or_disabled() {
    for disable_format in [false, true] {
        let style = CppStyle {
            disable_format,
            ..CppStyle::default()
        };
        for (input, selected_bytes, expected) in [
            (
                "    auto s = R\"(a^  \tb)\";",
                0,
                "    auto s = R\"(a\n^  \tb)\";",
            ),
            (
                "    auto s = R\"(a^xxx  b)\";",
                3,
                "    auto s = R\"(a\n^  b)\";",
            ),
            ("    auto s = R\"(a^", 0, "    auto s = R\"(a\n^"),
            ("    auto s = \"a^  b\";", 0, "    auto s = \"a\n^  b\";"),
            (
                "    auto s = R\"(a\nb^  c)\";",
                0,
                "    auto s = R\"(a\nb\n^  c)\";",
            ),
        ] {
            assert_atomic_input(input, selected_bytes, None, &style, expected);
        }
        assert_atomic_input("    /* a^  b */", 0, None, &style, "    /* a\n    ^  b */");
    }
}

#[test]
fn punctuation_inside_literals_comments_and_compound_tokens_does_not_trigger_indent() {
    for input in [
        "switch (x) {\n    case f(\"a^b\"):\n        break;\n}",
        "switch (x) {\n    case '^': break;\n}",
        "switch (x) {\n    case f(R\"(a^b)\"):\n        break;\n}",
        "switch (x) {\n    case 1: // a^b\n        break;\n}",
        "switch (x) {\n    case 1: /* a^b */ break;\n}",
        "switch (x) {\n    case ns^:value: break;\n}",
    ] {
        let expected = input.replace('^', ":^");
        assert_atomic_input(input, 0, Some(':'), &CppStyle::default(), &expected);
    }
    assert_atomic_input(
        "switch (x) {\n    case 1^\n}",
        0,
        Some(':'),
        &CppStyle::default(),
        "switch (x) {\ncase 1:^\n}",
    );
}
#[test]
fn comments_right_of_a_line_start_continue_its_trailing_comment() {
    let s = CppStyle::default();
    let text = "void f() {\n    return; // first line\n             // second line\n             // third line\n    int i; // trailing\n    // own comment\n    if (x) { // brace\n              // under the brace\n    }\n}\n";
    // As clang-format's continuesLineCommentSection: a comment right of
    // where the line above starts continues the comment ending it, and one
    // that continues a comment can be continued in turn.
    assert_eq!(col(text, 2, &s).target_column, 12);
    assert_eq!(col(text, 3, &s).target_column, 12);
    // At the code's column it is a comment of its own.
    assert_eq!(col(text, 5, &s).target_column, 4);
    // After `{`, the brace is where the line starts for this.
    assert_eq!(col(text, 7, &s).target_column, 13);
    // A label ends its line before the comment under it.
    let text = "void f() {
    switch (x) {
    case 1: // label
        // body
        g();
    }
}
";
    assert_eq!(col(text, 3, &s).target_column, 8);
}
#[test]
fn a_name_typed_as_a_label_returns_with_the_scope_operator() {
    let mut editor = soda::editor::Editor::new("", CppRules::default());
    for ch in "void f() {\nstd:".chars() {
        if ch == '\n' {
            editor.execute(soda::editor::Command::Enter).unwrap();
        } else {
            editor.execute(soda::editor::Command::TypeChar(ch)).unwrap();
        }
    }
    assert_eq!(editor.state().snapshot().text(), "void f() {\nstd:");
    editor
        .execute(soda::editor::Command::TypeChar(':'))
        .unwrap();
    assert_eq!(editor.state().snapshot().text(), "void f() {\n    std::");
}
#[test]
fn enter_after_the_body_of_a_do_goes_to_its_while() {
    for brace_indent in [BraceIndent::None, BraceIndent::Control] {
        let style = CppStyle {
            indent_width: 2,
            brace_indent,
            ..CppStyle::default()
        };
        let mut editor = soda::editor::Editor::new("", style.compile().unwrap());
        for ch in "void f()\n{\ndo\n{\nit();\n}\n".chars() {
            if ch == '\n' {
                editor.execute(soda::editor::Command::Enter).unwrap();
            } else {
                editor.execute(soda::editor::Command::TypeChar(ch)).unwrap();
            }
        }
        assert!(
            editor.state().snapshot().text().ends_with("}\n  "),
            "{:?}",
            editor.state().snapshot().text()
        );
    }
}
#[test]
fn skipped_macro_definitions_keep_their_lines() {
    let text = "#define A(x)   \\\n     do {      \\\n  x;           \\\n        } while (0)\nvoid f() {\nint y;\n}\n";
    let style = CppStyle {
        skip_macro_definition_body: true,
        ..CppStyle::default()
    };
    for line in 1..4 {
        let d = col(text, line, &style);
        assert!(d.preserve, "{line}");
        assert_eq!(d.role, IndentRole::PreservedMacro);
    }
    assert_eq!(col(text, 5, &style).target_column, 4);
    assert!(!col(text, 1, &CppStyle::default()).preserve);
}
