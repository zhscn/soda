//! Indentation examples adapted from LLVM's clang/unittests/Format/FormatTest.cpp.
//! Upstream revision: 8b7a4fb1628138dc89d49b0e4409fd4e1e7f43e5.
//! LLVM source is licensed under Apache-2.0 WITH LLVM-exception.
//! Each marker selects a formatter-chosen line boundary; the editor restores
//! that boundary with Enter and independently repairs its leading whitespace.
use soda::{
    config::{UnknownOptions, parse_config, preset},
    core::Selection,
    editor::{Command, Editor, Language},
};

struct Case {
    upstream: &'static str,
    yaml: &'static str,
    expected: &'static str,
}

const CASES: &[Case] = &[
    Case {
        upstream: "FormatBeginBlockEndMacros/body",
        yaml: "MacroBlockBegin: '^[A-Z_]+_BEGIN$'\nMacroBlockEnd: '^[A-Z_]+_END$'",
        expected: "FOO_BEGIN\n  ^FOO_ENTRY\nFOO_END",
    },
    Case {
        upstream: "FormatBeginBlockEndMacros/nested",
        yaml: "MacroBlockBegin: '^[A-Z_]+_BEGIN$'\nMacroBlockEnd: '^[A-Z_]+_END$'",
        expected: "FOO_BEGIN\n  NESTED_FOO_BEGIN\n    ^NESTED_FOO_ENTRY\n  NESTED_FOO_END\nFOO_END",
    },
    Case {
        upstream: "FormatBeginBlockEndMacros/arguments",
        yaml: "MacroBlockBegin: '^[A-Z_]+_BEGIN$'\nMacroBlockEnd: '^[A-Z_]+_END$'",
        expected: "FOO_BEGIN(Foo, Bar)\n  ^int x;\n  x = 1;\nFOO_END(Baz)",
    },
    Case {
        upstream: "FormatBeginBlockEndMacros/closer",
        yaml: "MacroBlockBegin: '^[A-Z_]+_BEGIN$'\nMacroBlockEnd: '^[A-Z_]+_END$'",
        expected: "FOO_BEGIN(Foo, Bar)\n  int x;\n  x = 1;\n^FOO_END(Baz)",
    },
    Case {
        upstream: "FormatsNamespaces/macro-name",
        yaml: "",
        expected: "namespace M(x)::inline N {\n^class A {};\n}",
    },
    Case {
        upstream: "IndentAccessModifiersAfterFirst/before",
        yaml: "IndentAccessModifiers: AfterFirstAccessModifier",
        expected: "struct S {\n  ^int before;\n  public:\n    int after;\n};",
    },
    Case {
        upstream: "IndentAccessModifiersAfterFirst/after",
        yaml: "IndentAccessModifiers: AfterFirstAccessModifier",
        expected: "struct S {\n  int before;\n  public:\n    ^int after;\n};",
    },
    Case {
        upstream: "ConfigurableUseOfTab/never",
        yaml: "UseTab: Never\nIndentWidth: 8\nTabWidth: 8",
        expected: "class X {\n        void f() {\n                someFunction(parameter1,\n                             ^parameter2);\n        }\n};",
    },
    Case {
        upstream: "ConfigurableUseOfTab/indentation",
        yaml: "UseTab: ForIndentation\nIndentWidth: 8\nTabWidth: 8",
        expected: "class X {\n\tvoid f() {\n\t\tsomeFunction(parameter1,\n\t\t             ^parameter2);\n\t}\n};",
    },
    Case {
        upstream: "ConfigurableUseOfTab/continuation",
        yaml: "UseTab: ForContinuationAndIndentation\nIndentWidth: 8\nTabWidth: 8",
        expected: "class X {\n\tvoid f() {\n\t\tsomeFunction(parameter1,\n\t\t\t     ^parameter2);\n\t}\n};",
    },
    Case {
        upstream: "ConfigurableUseOfTab/align-spaces",
        yaml: "UseTab: AlignWithSpaces\nIndentWidth: 8\nTabWidth: 8",
        expected: "class X {\n\tvoid f() {\n\t\tsomeFunction(parameter1,\n\t\t             ^parameter2);\n\t}\n};",
    },
    Case {
        upstream: "FormatsNamespaces/plain",
        yaml: "",
        expected: "namespace some_namespace {\n^class A {};\n}",
    },
    Case {
        upstream: "FormatsNamespaces/anonymous",
        yaml: "",
        expected: "namespace {\n^class A {};\n}",
    },
    Case {
        upstream: "FormatsNamespaces/inline",
        yaml: "",
        expected: "inline namespace X {\n^class A {};\n}",
    },
    Case {
        upstream: "FormatsNamespaces/nested-name",
        yaml: "",
        expected: "namespace N::inline D::E {\n^class A {};\n}",
    },
    Case {
        upstream: "FormatsNamespaces/attribute",
        yaml: "",
        expected: "namespace [[deprecated(\"foo[bar\")]] some_namespace {\n^class A {};\n}",
    },
    Case {
        upstream: "FormatsNamespaces/all",
        yaml: "NamespaceIndentation: All",
        expected: "namespace N {\n  ^class A {};\n}",
    },
    Case {
        upstream: "FormatsNamespaces/inner",
        yaml: "NamespaceIndentation: Inner",
        expected: "namespace N {\nnamespace M {\n  ^class A {};\n}\n}",
    },
    Case {
        upstream: "NamespaceMacros",
        yaml: "NamespaceMacros: [NS]\nNamespaceIndentation: All",
        expected: "NS(n) {\n  ^int x;\n}",
    },
    Case {
        upstream: "IndentExternBlockStyle/indent",
        yaml: "IndentExternBlock: Indent",
        expected: "extern \"C\" {\n  ^void f();\n}",
    },
    Case {
        upstream: "IndentExternBlockStyle/no-indent",
        yaml: "IndentExternBlock: NoIndent",
        expected: "extern \"C\" {\n^void f();\n}",
    },
    Case {
        upstream: "ConfigurableIndentWidth/function",
        yaml: "IndentWidth: 8\nContinuationIndentWidth: 8",
        expected: "void f() {\n        ^someFunction();\n}",
    },
    Case {
        upstream: "ConfigurableIndentWidth/nested",
        yaml: "IndentWidth: 8\nContinuationIndentWidth: 8",
        expected: "void f() {\n        if (true) {\n                ^f();\n        }\n}",
    },
    Case {
        upstream: "ConfigurableIndentWidth/member",
        yaml: "IndentWidth: 8\nContinuationIndentWidth: 8",
        expected: "class X {\n        ^void f() {}\n};",
    },
    Case {
        upstream: "ConfigurableContinuationIndentWidth/two",
        yaml: "ContinuationIndentWidth: 2",
        expected: "int i =\n  ^longFunction(\n    arg);",
    },
    Case {
        upstream: "ConfigurableContinuationIndentWidth/six",
        yaml: "ContinuationIndentWidth: 6",
        expected: "int i =\n      longFunction(\n            ^arg);",
    },
    Case {
        upstream: "IndentAccessModifiers/member",
        yaml: "IndentAccessModifiers: Always",
        expected: "class C {\n    ^int i;\n};",
    },
    Case {
        upstream: "IndentAccessModifiers/union",
        yaml: "IndentAccessModifiers: Always",
        expected: "union C {\n    int i;\n    ^unsigned u;\n};",
    },
    Case {
        upstream: "IndentAccessModifiers/access",
        yaml: "IndentAccessModifiers: Always",
        expected: "class C {\n  ^public:\n    int i;\n};",
    },
    Case {
        upstream: "IndentAccessModifiers/comment",
        yaml: "IndentAccessModifiers: Always",
        expected: "class C {\n  public /* comment */:\n    ^int i;\n};",
    },
    Case {
        upstream: "IndentAccessModifiers/nested",
        yaml: "IndentAccessModifiers: Always",
        expected: "struct S {\n  private:\n    class C {\n        ^int j;\n    };\n};",
    },
    Case {
        upstream: "ConstructorInitializers/colon",
        yaml: "",
        expected: "Constructor()\n    ^: a_(1), b_(2) {}",
    },
    Case {
        upstream: "ConstructorInitializers/sibling",
        yaml: "",
        expected: "Constructor()\n    : a_(1),\n      ^b_(2) {}",
    },
    Case {
        upstream: "ExpressionIndentation/return",
        yaml: "",
        expected: "return aaaaaaaaaaaaaaaaaaa +\n       ^b;",
    },
    Case {
        upstream: "ExpressionIndentation/comment",
        yaml: "",
        expected: "return aaaaaaaaaaaaaaaaaaa +\n       ^b; //",
    },
    Case {
        upstream: "BracedInitializerIndentWidth",
        yaml: "BracedInitializerIndentWidth: 6",
        expected: "int LooooooooooooooooooooooooongVariable[2] = {\n      ^10000000, 20000000};",
    },
    Case {
        upstream: "IndentsPPDirectiveWithPPIndentWidth/before",
        yaml: "IndentPPDirectives: BeforeHash\nPPIndentWidth: 1",
        expected: "#ifdef __linux__\nvoid foo() {}\n ^#define FOO foo\n#endif",
    },
    Case {
        upstream: "IndentsPPDirectiveWithPPIndentWidth/after",
        yaml: "IndentPPDirectives: AfterHash\nPPIndentWidth: 1",
        expected: "#ifdef __linux__\nvoid foo() {}\n^# define FOO foo\n#endif",
    },
    Case {
        upstream: "ConfigurableUseOfTab/eight",
        yaml: "UseTab: Always\nIndentWidth: 8\nTabWidth: 8",
        expected: "class X {\n\tvoid f() {\n\t\tsomeFunction(parameter1,\n\t\t\t     ^parameter2);\n\t}\n};",
    },
    Case {
        upstream: "ConfigurableUseOfTab/four",
        yaml: "UseTab: Always\nIndentWidth: 4\nTabWidth: 4",
        expected: "class X {\n\tvoid f() {\n\t\tsomeFunction(parameter1,\n\t\t\t\t\t ^parameter2);\n\t}\n};",
    },
    Case {
        upstream: "ConfigurableUseOfTab/mixed-width",
        yaml: "UseTab: Always\nIndentWidth: 4\nTabWidth: 8",
        expected: "class X {\n    void f() {\n\tsomeFunction(parameter1,\n\t\t     ^parameter2);\n    }\n};",
    },
];

fn run_case(case: &Case, crlf: bool, reindent: bool) -> Result<(), String> {
    let golden = format!("{}\n", case.expected);
    let expected = if crlf {
        golden.replace('\n', "\r\n")
    } else {
        golden
    };
    let caret = expected.find('^').unwrap();
    let expected_text = expected.replacen('^', "", 1);
    let line_start = expected[..caret].rfind('\n').unwrap() + 1;
    let config = parse_config(
        case.yaml,
        &preset("LLVM").unwrap(),
        "Cpp",
        false,
        UnknownOptions::Error,
    )
    .unwrap()
    .unwrap();
    let (input, input_caret, command) = if reindent {
        let mut input = expected_text.clone();
        input.replace_range(line_start..caret, " \t ");
        let row = expected[..line_start]
            .bytes()
            .filter(|&b| b == b'\n')
            .count();
        (input, line_start + 3, Command::Reindent(row))
    } else {
        let boundary = line_start - if crlf { 2 } else { 1 };
        let mut input = expected_text.clone();
        input.replace_range(boundary..caret, "");
        (input, boundary, Command::Enter)
    };
    let mut editor = Editor::new(input.clone(), Language::Cpp(config.rules.into()));
    editor
        .execute(Command::SetSelection(Selection::caret(input_caret)))
        .unwrap();
    editor.execute(command).unwrap();
    let result = (
        editor.state().snapshot().text().to_owned(),
        editor.state().selection(),
    );
    let wanted = (expected_text, Selection::caret(caret));
    if result != wanted {
        return Err(format!(
            "{} crlf={crlf} reindent={reindent}\ninput: {input:?}\nactual: {result:?}\nexpected: {wanted:?}",
            case.upstream
        ));
    }
    editor.execute(Command::Undo).unwrap();
    assert_eq!(
        editor.state().snapshot().text(),
        input,
        "{} undo",
        case.upstream
    );
    assert_eq!(editor.state().selection(), Selection::caret(input_caret));
    editor.execute(Command::Redo).unwrap();
    assert_eq!(editor.state().snapshot().text(), wanted.0);
    assert_eq!(editor.state().selection(), wanted.1);
    Ok(())
}

fn run_corpus(reindent: bool) {
    let mut failures = Vec::new();
    for case in CASES {
        for crlf in [false, true] {
            if let Err(failure) = run_case(case, crlf, reindent) {
                failures.push(failure);
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

#[test]
fn upstream_indentation_through_enter() {
    run_corpus(false);
}

#[test]
fn upstream_indentation_through_reindent() {
    run_corpus(true);
}
