use soda::editor::enter;
use soda::{
    core::{Editor, Selection, Transaction},
    cpp::CppStyle,
};

#[test]
fn enter_regression_corpus() {
    let cases: &[(&str, &str, &str)] = &[
        (
            "unclosed macro invocation does not swallow a following namespace",
            "#define DECLARE(x) x\n\nDECLARE(\nnamespace foo {^\nint x;\n}\n",
            "#define DECLARE(x) x\n\nDECLARE(\nnamespace foo {\n^\nint x;\n}\n",
        ),
        (
            "namespace body is not indented by default",
            "namespace foo {^\nint x;\n}\n",
            "namespace foo {\n^\nint x;\n}\n",
        ),
        (
            "enter between braces expands and places the caret on the middle line",
            "void f() {^}\n",
            "void f() {\n    ^\n}\n",
        ),
        (
            "enter between braces expands and places the caret on the middle line",
            "namespace foo {^}\n",
            "namespace foo {\n^\n}\n",
        ),
        (
            "enter between braces expands and places the caret on the middle line",
            "class Foo {^};\n",
            "class Foo {\n    ^\n};\n",
        ),
        (
            "enter between braces expands and places the caret on the middle line",
            "void f() {\n    if (x) {^}\n}\n",
            "void f() {\n    if (x) {\n        ^\n    }\n}\n",
        ),
        (
            "enter between braces expands and places the caret on the middle line",
            "foo([&](int x) {^});\n",
            "foo([&](int x) {\n    ^\n});\n",
        ),
        (
            "class body and access specifiers",
            "class Foo {\npublic:^\n};\n",
            "class Foo {\npublic:\n    ^\n};\n",
        ),
        (
            "switch, case labels and case bodies",
            "switch (x) {\ncase 1:^\n}\n",
            "switch (x) {\ncase 1:\n    ^\n}\n",
        ),
        (
            "switch, case labels and case bodies",
            "switch (x) {\ncase 1:\n    foo();^\n}\n",
            "switch (x) {\ncase 1:\n    foo();\n    ^\n}\n",
        ),
        (
            "bare colon initializer keeps a stable continuation indent",
            "Foo::Foo()\n    :^\n",
            "Foo::Foo()\n    :\n    ^\n",
        ),
        (
            "declaration-prefix macro does not disturb initializer alignment",
            "MY_API\nFoo::Foo()\n    : a_(1),^\n{\n}\n",
            "MY_API\nFoo::Foo()\n    : a_(1),\n      ^\n{\n}\n",
        ),
        (
            "if without braces indents one level and closes back",
            "if (x)^\n",
            "if (x)\n    ^\n",
        ),
        (
            "if without braces indents one level and closes back",
            "if (x)\n    foo();^\n",
            "if (x)\n    foo();\n^\n",
        ),
        (
            "if without braces indents one level and closes back",
            "if (a)\n    f();\nelse^\n",
            "if (a)\n    f();\nelse\n    ^\n",
        ),
        (
            "statement continuation",
            "int x = a +^\n",
            "int x = a +\n        ^\n",
        ),
        (
            "statement continuation",
            "foo(a,^ b);\n",
            "foo(a,\n    ^b);\n",
        ),
        (
            "wrapped signature anchors the body on the declaration line",
            "void long_name(int a,\n               int b) {^}\n",
            "void long_name(int a,\n               int b) {\n    ^\n}\n",
        ),
        (
            "wrapped signature anchors the body on the declaration line",
            "for (;;)\n    if (x) {^}\n",
            "for (;;)\n    if (x) {\n        ^\n    }\n",
        ),
        (
            "open-bracket alignment",
            "int y = f(aa,^ bb);\n",
            "int y = f(aa,\n          ^bb);\n",
        ),
        ("open-bracket alignment", "foo(^a);\n", "foo(\n    ^a);\n"),
        (
            "enumerators indent as siblings",
            "enum E {\n    A,^\n};\n",
            "enum E {\n    A,\n    ^\n};\n",
        ),
        (
            "extern block follows namespace indent style",
            "extern \"C\" {^\nvoid f(int);\n}\n",
            "extern \"C\" {\n^\nvoid f(int);\n}\n",
        ),
        (
            "extern block follows namespace indent style",
            "#ifdef __cplusplus\nextern \"C\" {\n#endif\nvoid f(int);^\n#ifdef __cplusplus\n}\n#endif\n",
            "#ifdef __cplusplus\nextern \"C\" {\n#endif\nvoid f(int);\n^\n#ifdef __cplusplus\n}\n#endif\n",
        ),
        (
            "macro callback block indents as a block",
            "LLVM_DEBUG({\n    f();^\n});\n",
            "LLVM_DEBUG({\n    f();\n    ^\n});\n",
        ),
        (
            "statement after a goto label stays at block level",
            "void f() {\nout:^\n}\n",
            "void f() {\nout:\n    ^\n}\n",
        ),
        (
            "preprocessor directives stay at column zero",
            "void f() {\n    body();^\n}\n",
            "void f() {\n    body();\n    ^\n}\n",
        ),
        (
            "raw strings and block comments are protected",
            "auto s = R\"(ab^cd)\";\n",
            "auto s = R\"(ab\n^cd)\";\n",
        ),
        (
            "raw strings and block comments are protected",
            "void f() {\n    /* comment^ */\n}\n",
            "void f() {\n    /* comment\n    ^ */\n}\n",
        ),
    ];
    let mut failures = Vec::new();
    for &(name, input, expected) in cases {
        let caret = input.find('^').unwrap();
        let mut text = input.to_owned();
        text.remove(caret);
        let mut editor = Editor::new(text.clone());
        let mut select = Transaction::new(0, vec![]);
        select.selection = Some(Selection::caret(caret));
        editor.dispatch(select).unwrap();
        let tx = enter(editor.state(), CppStyle::default().compile().unwrap()).unwrap();
        editor.dispatch(tx).unwrap();
        let mut output = editor.state().snapshot().text().to_owned();
        output.insert(editor.state().selection().head, '^');
        if output != expected {
            failures.push(format!(
                "{name}\ninput: {input:?}\nactual: {output:?}\nexpected: {expected:?}"
            ));
        }
        assert!(editor.undo().unwrap());
        assert_eq!(editor.state().snapshot().text(), text);
        assert_eq!(editor.state().selection(), Selection::caret(caret));
    }
    assert!(
        failures.is_empty(),
        "{} failures / {} cases\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n\n")
    );
}
