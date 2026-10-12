use soda::cpp::*;

#[test]
fn token_classification_corpus() {
    use TokenKind::*;
    let cases: &[(&str, &[TokenKind])] = &[
        (
            "namespace foo { int x; }",
            &[
                NamespaceKw,
                Identifier,
                LBrace,
                Identifier,
                Identifier,
                Semicolon,
                RBrace,
            ],
        ),
        ("classic class classes", &[Identifier, ClassKw, Identifier]),
        (
            "switch case default public private protected",
            &[
                SwitchKw,
                CaseKw,
                DefaultKw,
                PublicKw,
                PrivateKw,
                ProtectedKw,
            ],
        ),
        ("a<<b", &[Identifier, LessLess, Identifier]),
        (
            "a<b>c",
            &[Identifier, Less, Identifier, Greater, Identifier],
        ),
        ("x::y", &[Identifier, ColonColon, Identifier]),
        ("x: y", &[Identifier, Colon, Identifier]),
        ("p->q", &[Identifier, Arrow, Identifier]),
        ("p->*q", &[Identifier, ArrowStar, Identifier]),
        ("a<=>b", &[Identifier, Spaceship, Identifier]),
        (
            "a=b==c",
            &[Identifier, Equals, Identifier, EqualEqual, Identifier],
        ),
        ("f(...)", &[Identifier, LParen, Ellipsis, RParen]),
        (">>=", &[GreaterGreaterEqual]),
        ("a##b", &[Identifier, Punctuator, Identifier]),
        (
            "u8\"x\" L\"y\" U'c'",
            &[StringLiteral, StringLiteral, CharacterLiteral],
        ),
        ("u8R\"(x)\"", &[RawStringLiteral]),
        ("FooR\"(x)\"", &[Identifier, StringLiteral]),
        (
            "1'000'000 0x1.8p-3 1.5e+10f 0b1010 .5",
            &[Number, Number, Number, Number, Number],
        ),
        ("1+2", &[Number, Plus, Number]),
        ("x-1", &[Identifier, Minus, Number]),
        ("a @ b", &[Identifier, Invalid, Identifier]),
        ("`", &[Invalid]),
        ("a \\ b", &[Identifier, Invalid, Identifier]),
        ("operator<<", &[OperatorKw, LessLess]),
        (
            "vector<vector<int>> v",
            &[
                Identifier,
                Less,
                Identifier,
                Less,
                Identifier,
                GreaterGreater,
                Identifier,
            ],
        ),
    ];
    for &(source, expected) in cases {
        let actual: Vec<_> = lex(source)
            .into_iter()
            .filter(|t| !t.kind.is_trivia() && t.kind != EndOfFile)
            .map(|t| t.kind)
            .collect();
        assert_eq!(actual, expected, "{source}");
    }
}

#[test]
fn lexical_protection_and_macro_flags() {
    for source in [
        "R\"ab(line1\n)x\nline2)ab\"",
        "u8R\"(x)\"",
        "R\"d(open\nstill",
    ] {
        let t = lex(source);
        assert_eq!(t[0].kind, TokenKind::RawStringLiteral);
        assert_eq!(t[0].range, 0..source.len());
    }
    assert_eq!(lex("R\"a b(x)\"")[0].kind, TokenKind::StringLiteral);
    assert!(lex("\"open\nnext")[0].unterminated);
    assert!(lex("/* open\n")[0].unterminated);
    let tokens = lex("#define M(x) \\\n    x\nint y;");
    let x = tokens
        .iter()
        .find(|t| t.range.start > 10 && t.kind == TokenKind::Identifier)
        .unwrap();
    assert!(x.preprocessor);
    let int = tokens
        .iter()
        .find(|t| t.kind == TokenKind::Identifier && t.range.len() == 3)
        .unwrap();
    assert!(!int.preprocessor);
    assert!(tokens.iter().any(|t| t.escaped_newline));
    let tokens = lex("// one\\\ntwo\nint x;");
    assert_eq!(tokens[0].kind, TokenKind::LineComment);
    assert_eq!(tokens[0].range, 0..11);
}
