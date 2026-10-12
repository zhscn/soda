use soda::{core::*, cpp::*};
use std::num::NonZeroUsize;
fn col(text: &str, line: usize, style: &CppStyle) -> IndentDecision {
    let s = EditorState::new(text);
    compute_indent(s.snapshot(), &parse(text), line, &style.compile()).unwrap()
}
fn enter_at(input: &str, style: &CppStyle) -> String {
    let p = input.find('^').unwrap();
    let mut s = input.to_owned();
    s.remove(p);
    let mut e = Editor::new(s);
    let mut tx = Transaction::new(0, vec![]);
    tx.selection = Some(Selection::caret(p));
    e.dispatch(tx).unwrap();
    e.dispatch(enter(e.state(), &style.compile()).unwrap())
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
    let mut e = Editor::new("  return WithColor(OS)\n.get()\n<< \"e\";\n");
    for line in [1, 2] {
        e.dispatch(reindent(e.state(), line, &s.compile()).unwrap())
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
        "int y = f(aa,\n    ^ bb);\n"
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
        let mut e = Editor::new(text);
        let lines = e.state().snapshot().line_count();
        for line in 0..lines - 1 {
            e.dispatch(reindent(e.state(), line, &s.compile()).unwrap())
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
            materialize(structure, structure, target, s.compile().whitespace()),
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
    assert_eq!(materialize(4, 8, 11, s.compile().whitespace()), "\t\t   ");
    s.tabs = TabPolicy::AlignWithSpaces;
    assert_eq!(materialize(4, 8, 11, s.compile().whitespace()), "\t\t   ");
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
            &CppStyle::default().compile()
        )
        .unwrap_err(),
        EditError::AnalysisMismatch
    );
    for text in ["auto s = R\"d(\n  keep\n)d\";", "/* a\n  keep\n*/"] {
        let mut e = Editor::new(text);
        e.dispatch(reindent(e.state(), 1, &CppStyle::default().compile()).unwrap())
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
        let mut e = Editor::new(text);
        let mut select = Transaction::new(0, vec![]);
        select.selection = Some(Selection::caret(caret));
        e.dispatch(select).unwrap();
        for ch in typed.chars() {
            let before = e.state().snapshot().text().to_owned();
            let selection = e.state().selection();
            let tx = type_char(e.state(), ch, &CppStyle::default().compile()).unwrap();
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
        let mut e = Editor::new(&sample[..p]);
        let mut select = Transaction::new(0, vec![]);
        select.selection = Some(Selection::caret(p));
        e.dispatch(select).unwrap();
        let a = enter(e.state(), &CppStyle::default().compile()).unwrap();
        let b = enter(e.state(), &CppStyle::default().compile()).unwrap();
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
    assert_eq!(
        enter_at("    /* abc^", &CppStyle::default()),
        "    /* abc\n    ^"
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
    assert_eq!(materialize(2, 2, 2, style.compile().whitespace()), "\t\t");
    style.tabs = TabPolicy::Always;
    assert_eq!(materialize(1, 1, 1, style.compile().whitespace()), " ");
    assert_eq!(materialize(2, 2, 2, style.compile().whitespace()), "\t\t");
}
