use soda::cpp::*;

fn check(source: &str) {
    let tree = parse(source);
    assert_eq!(tree.nodes()[0].tokens, 0..tree.tokens().len());
    let mut cursor = 0;
    for t in tree.tokens() {
        assert_eq!(t.range.start, cursor);
        assert!(source.is_char_boundary(t.range.start));
        assert!(source.is_char_boundary(t.range.end));
        cursor = t.range.end;
    }
    assert_eq!(cursor, source.len());
    for (id, n) in tree.nodes().iter().enumerate() {
        let mut cursor = n.tokens.start;
        for &c in &n.children {
            let child = &tree.nodes()[c];
            assert_eq!(child.parent, Some(id));
            assert!(child.tokens.start >= cursor);
            assert!(child.tokens.end <= n.tokens.end);
            assert!(child.tokens.start <= child.tokens.end);
            cursor = child.tokens.end;
        }
    }
}

#[test]
fn structural_corpus_and_all_incomplete_prefixes() {
    let cases: &[&str] = &[
        "",
        "   \n\n  ",
        "// only a comment\n",
        "namespace foo {\nint x;\n}\n",
        "namespace foo {\nint x;\n",
        "class Foo {\npublic:\n    Foo();\nprivate:\n    int x_;\n};\n",
        "switch (x) {\ncase 1:\n    foo();\n    bar();\ndefault:\n    break;\n}\n",
        "Foo::Foo()\n    : a_(1),\n      b_{2}\n{\n}\n",
        "Foo::Foo()\n    :\n",
        "MY_API\nFoo::Foo()\n    : a_(1)\n{\n}\n",
        "#define DECLARE(x) x\n\nDECLARE(\nnamespace foo {\nint x;\n}\n",
        "if (x)\n    foo();\nbar();\n",
        "if (x)\n",
        "if (a)\n    f();\nelse if (b)\n    g();\nelse\n    h();\n",
        "foo([&](int x) {\n    return x;\n});\n",
        "auto f = [](int x) {\n    return x;\n};\n",
        "std::vector<std::vector<int>> v;\n",
        "template <typename T>\nclass Foo {\n};\n",
        "bool b = a < b;\n",
        "foo<bar baz;\nint x;\n",
        "#ifdef A\nvoid f() {\n#else\nvoid g() {\n#endif\n    body();\n}\n",
        "int h() {\n#ifdef _WIN32\n  if (a) {\n#else\n  if (b) {\n#endif\n    inner();\n  }\n  tail();\n}\n",
        "class C {\n    int f(int a) const { return a; }\n    void g() {}\n};\n",
        "auto f(int a) -> int * { return &a; }\n",
        "X::X() noexcept : a_(1) {}\n",
        "E = handleErrors(std::move(E), [&](const X &E) -> Error {\n    use(E);\n    return f();\n});\n",
        "LLVM_DEBUG({\n    dbgs() << x;\n    f();\n});\n",
        "static const struct f_cnvrt Convert = {\n    SETCVTOFF, // cvtcmd\n    0,         // pccsid\n};\n",
        "auto f = [this] { return go(); };\n",
        "void f() {\nretry:\n    if (x)\n        goto retry;\n}\n",
        "struct S {\n    S() : a_(1) {}\n};\n",
        "#define F(a, b) \\\n  impl((long)(a), \\\n       (long)(b))\nint x;\n",
        "#define LPAREN (\nint y;\n",
        "extern \"C\" {\nvoid f(int);\nint g(void) { return 0; }\n}\n",
        "extern \"C\" void f(int);\nextern int x;\n",
        "#ifdef __cplusplus\nextern \"C\" {\n#endif\n\nvoid f(int);\nint g(void);\n\n#ifdef __cplusplus\n}\n#endif\n",
        "enum E {\n    A,\n    B = f(1, 2),\n    C\n};\n",
        "X::X() = default;\nvoid f() {}\n",
        "DEFINE_THING(Kernel::Metadata)\nvoid f() {\n    g();\n}\n",
        "do {\n    f();\n} while (x);\n",
        "void f() {\n  do {\n    g();\n#ifdef A\n  } while (x);\n#else\n  } while (y);\n#endif\n  tail();\n}\n",
        "void f() {\n  do {\n    g();\n#if A\n  } while (x);\n#elif B\n  } while (y);\n#else\n  } while (z);\n#endif\n  tail();\n}\n",
        "void f() {\n#ifdef A\n  if (x)\n#else\n  if (y)\n#endif\n    return;\n}\n",
        "void f() {\n  if (c(s, (struct sockaddr *)&a, sizeof(a)) == -1)\n    return;\n}\n",
        "void g() {\n  h(x, y\n  struct S { int a; };\n}\n",
    ];
    for source in cases {
        for p in (0..=source.len()).filter(|&p| source.is_char_boundary(p)) {
            check(&source[..p]);
        }
    }
}

#[test]
fn arbitrary_utf8_and_deep_nesting_are_bounded() {
    let alphabet = [
        ' ', '\t', '\n', '\r', 'a', 'R', '"', '\'', '(', ')', '{', '}', '[', ']', '<', '>', ':',
        ';', ',', '#', '\\', '/', '*', '=', '+', '-', '.', '0', '_', '界', 'é', '\u{301}', '\0',
    ];
    let mut seed = 987654321u64;
    for _ in 0..1000 {
        let mut source = String::new();
        for _ in 0..200 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            source.push(alphabet[(seed >> 32) as usize % alphabet.len()]);
        }
        check(&source);
    }
    check(&"{".repeat(10000));
    check(&"(".repeat(10000));
}

#[test]
fn roles_recover_macros_lambdas_templates_and_struct_initializers() {
    for (source, kind) in [
        ("namespace n {\nint x;\n}", NodeKind::NamespaceBody),
        (
            "auto f = [this] { return go(); };",
            NodeKind::CompoundStatement,
        ),
        (
            "LLVM_DEBUG({ dbgs() << x; f(); });",
            NodeKind::CompoundStatement,
        ),
        (
            "static const struct S value = { A, 0 };",
            NodeKind::BraceGroup,
        ),
        (
            "std::vector<std::vector<int>> value;",
            NodeKind::TemplateArgumentList,
        ),
        (
            "Foo::Foo() : a_(1), b_{2} {}",
            NodeKind::CtorInitializerList,
        ),
        ("#define OPEN (\nnamespace n {}", NodeKind::NamespaceDecl),
    ] {
        let t = parse(source);
        assert!(
            t.nodes().iter().any(|n| n.kind == kind),
            "{source}: {kind:?}"
        );
    }
}
#[test]
fn using_directives_open_no_namespace() {
    for source in [
        "using namespace clang;\nint x;\n",
        "using namespace llvm::omp;\n",
        "void f() {\n  using namespace std;\n  g();\n}\n",
    ] {
        let tree = parse(source);
        assert!(
            tree.nodes().iter().all(|n| !n.incomplete && n.kind != NodeKind::NamespaceDecl),
            "{source:?}: {:?}",
            tree.nodes()
        );
    }
    // A namespace still opens after a using declaration ends.
    let tree = parse("using std::string;\nnamespace a {\nint x;\n}\n");
    assert!(tree.nodes().iter().any(|n| n.kind == NodeKind::NamespaceBody));
    assert!(tree.nodes().iter().all(|n| !n.incomplete));
}
