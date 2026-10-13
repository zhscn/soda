//! Reuse is restricted to token-equivalent analyses and complete item containers.
//! Unsafe conditional or unfinished contexts expand the repair or fall back.
use super::{K, Parser, SyntaxTree, parse_tokens};
use crate::cpp::Token;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ParseStrategy {
    Full,
    TokenEquivalent,
    Declarations,
    Container,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AnalysisFallback {
    PreprocessorContext,
    IncompleteStructure,
    ChangedBoundary,
}

/// Work performed by the latest analysis, excluding source materialization and
/// rebuilding token ownership. Counts describe work, not stable node identity.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AnalysisWork {
    pub strategy: ParseStrategy,
    pub scanned_bytes: usize,
    pub reparsed_tokens: usize,
    pub reused_nodes: usize,
    /// Cold full analysis has no fallback; incremental full analysis records why
    /// a reusable context could not be established.
    pub fallback: Option<AnalysisFallback>,
}

pub(crate) fn reparse(old: &SyntaxTree, source: Arc<str>) -> (SyntaxTree, AnalysisWork) {
    let relexed = super::super::lexer::relex(old.source(), old.tokens(), &source);
    let scanned_bytes = relexed.scanned.len();
    let tokens = relexed.tokens;
    let equivalent = |a: &Token, b: &Token| {
        a.kind == b.kind
            && a.preprocessor == b.preprocessor
            && a.unterminated == b.unterminated
            && a.escaped_newline == b.escaped_newline
            && ((!a.preprocessor && a.kind != K::Identifier)
                || a.kind.is_trivia()
                || old.source[a.range.clone()] == source[b.range.clone()])
    };
    if old.tokens.len() == tokens.len()
        && old
            .tokens
            .iter()
            .zip(&tokens)
            .all(|(a, b)| equivalent(a, b))
    {
        let tree = SyntaxTree {
            source,
            parser_options: old.parser_options.clone(),
            tokens,
            nodes: old.nodes.clone(),
            token_owners: old.token_owners.clone(),
            macro_blocks: old.macro_blocks.clone(),
        };
        let work = AnalysisWork {
            strategy: ParseStrategy::TokenEquivalent,
            scanned_bytes,
            reparsed_tokens: 0,
            reused_nodes: tree.nodes.len(),
            fallback: None,
        };
        return (tree, work);
    }
    let damage = old
        .tokens
        .iter()
        .zip(&tokens)
        .position(|(a, b)| !equivalent(a, b))
        .unwrap_or(old.tokens.len().min(tokens.len()));
    let mut parser = Parser::new(source.clone(), &old.parser_options, tokens);
    let mut reparsed = 0;
    let mut fallback = None;
    let owner = old.token_owners[damage.min(old.tokens.len() - 1)];
    let previous = old.tokens[..damage.min(old.tokens.len())]
        .iter()
        .rposition(|t| !t.kind.is_trivia())
        .map(|token| old.token_owners[token]);
    let mut candidates = Vec::new();
    // A caret in trailing trivia can belong to the outer block while the edit
    // still belongs to the preceding case section's logical statement region.
    for owner in [Some(owner), previous].into_iter().flatten() {
        let mut context = Some(owner);
        while let Some(id) = context {
            candidates.push(id);
            context = old.nodes[id].parent;
        }
    }
    candidates.sort_unstable_by(|a, b| b.cmp(a));
    candidates.dedup();
    for container in candidates {
        if container == 0
            || !super::container::eligible(
                old,
                &parser,
                container,
                relexed.unchanged_prefix,
                relexed.unchanged_suffix,
            )
        {
            continue;
        }
        match super::container::repair(
            old,
            &mut parser,
            container,
            damage,
            relexed.unchanged_suffix,
        ) {
            Ok((count, reused)) => {
                return (
                    parser.tree,
                    AnalysisWork {
                        strategy: ParseStrategy::Container,
                        scanned_bytes,
                        reparsed_tokens: reparsed + count,
                        reused_nodes: reused,
                        fallback: None,
                    },
                );
            }
            Err(failure) => {
                reparsed += failure.tokens;
                fallback = Some(failure.reason);
            }
        }
    }
    let safe_root = !old.nodes.iter().any(|n| n.incomplete)
        && !old
            .tokens
            .iter()
            .chain(&parser.tree.tokens)
            .any(|t| t.preprocessor);
    if safe_root {
        match super::container::repair(old, &mut parser, 0, damage, relexed.unchanged_suffix) {
            Ok((count, reused)) => {
                return (
                    parser.tree,
                    AnalysisWork {
                        strategy: ParseStrategy::Declarations,
                        scanned_bytes,
                        reparsed_tokens: reparsed + count,
                        reused_nodes: reused,
                        fallback: None,
                    },
                );
            }
            Err(failure) => {
                reparsed += failure.tokens;
                fallback = Some(failure.reason);
            }
        }
    }
    let tokens = parser.tree.tokens;
    let work = AnalysisWork {
        strategy: ParseStrategy::Full,
        scanned_bytes,
        reparsed_tokens: tokens.len() + reparsed,
        reused_nodes: 0,
        fallback: Some(fallback.unwrap_or_else(|| {
            if old.tokens.iter().chain(&tokens).any(|t| t.preprocessor) {
                AnalysisFallback::PreprocessorContext
            } else {
                AnalysisFallback::IncompleteStructure
            }
        })),
    };
    (parse_tokens(source, &old.parser_options, tokens), work)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cpp::{CppStyle, ParserOptions, compute_indent, parse, parse_with_options};

    fn assert_full(tree: &SyntaxTree) {
        let full = parse_with_options(tree.source(), tree.parser_options());
        assert_eq!(tree.tokens, full.tokens, "tokens: {:?}", tree.source());
        assert_eq!(tree.nodes, full.nodes, "nodes: {:?}", tree.source());
        assert_eq!(tree.token_owners, full.token_owners);
        assert_eq!(tree.macro_blocks, full.macro_blocks);
    }

    #[test]
    fn incremental_analysis_reuses_safe_declarations_and_rescans_only_one_line() {
        let source = (0..100)
            .map(|i| format!("void f{i}() {{\n    work({i});\n}}\n"))
            .collect::<String>();
        let tree = parse(&source);
        let (spaces, work) = reparse(
            &tree,
            source.replacen("    work(50)", "\twork(50)", 1).into(),
        );
        assert_full(&spaces);
        assert_eq!(work.strategy, ParseStrategy::TokenEquivalent);
        assert_eq!(work.reparsed_tokens, 0);
        assert!(work.scanned_bytes < 60);
        let (changed, work) = reparse(&tree, source.replacen("work(50)", "other(50, 1)", 1).into());
        assert_full(&changed);
        assert_eq!(work.strategy, ParseStrategy::Container);
        assert!(work.reparsed_tokens < 40);
        assert!(work.reused_nodes > 100);
        assert!(work.scanned_bytes < 60);
    }

    #[test]
    fn incremental_analysis_matches_full_parse_under_repeated_utf8_edits() {
        let samples = [
            "#if A\nnamespace n { class C { void f() { if (x) { target(); } } }; }\n#else\nvoid g() {}\n#endif\n",
            "void f() { do {\n#if A\n} while (a);\n#else\nif (x) { target(); }\n} while (b);\n#endif\n}\n",
            "#if A\nvoid f() { switch (x) { case 1: a(); b(); case 2: c(); } }\n#endif\n",
            "namespace n { class C { public: void f() { if (x) { a(); } else { b(); } for (;;) if (x) c(); d(); } int x; }; }\n",
            "void f() { switch (x) { case 1: a(); case 2: b(); default: c(); } }\n",
            "enum class E { A = 1, B = f(1, 2), C };\nvoid f() {}\n",
            "namespace n {\nvoid f() { work(); }\n}\nvoid g() {}\n",
            "template <class T>\nvoid f(T x) {\n    work(x);\n}\nvoid g() {}\n",
            "#ifdef __cplusplus\nextern \"C\" {\n#endif\nvoid f();\n#ifdef __cplusplus\n}\n#endif\n",
            "void f() {\n    do {\n#if A\n    } while (a);\n#else\n    } while (b);\n#endif\n}\n",
            "#define F(x) \\\n  work(x)\n/* comment\nend */\nauto s = R\"tag(raw\ntext)tag\";\nvoid f() {}\n",
            "void f() {\r\n    work();\r\n}\r\nvoid g() {}\r\n",
        ];
        let inserts = [
            "", " ", "\n", "\r\n", "\\\n", "{", "}", ";", "/*", "*/", "\"", "R\"(", "#if A\n",
            "#else\n", "#endif\n", "é", "界", "::", "x", "(", ")",
        ];
        let mut seed = 613u64;
        for sample in samples {
            let mut tree = parse(sample);
            for _ in 0..300 {
                let mut next = tree.source().to_owned();
                let boundaries = next
                    .char_indices()
                    .map(|(p, _)| p)
                    .chain([next.len()])
                    .collect::<Vec<_>>();
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                let start = (seed >> 32) as usize % boundaries.len();
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                let end = (start + (seed >> 32) as usize % 4).min(boundaries.len() - 1);
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                next.replace_range(
                    boundaries[start]..boundaries[end],
                    inserts[(seed >> 32) as usize % inserts.len()],
                );
                tree = reparse(&tree, next.into()).0;
                assert_full(&tree);
            }
        }
    }

    #[test]
    fn incremental_boundaries_and_macro_options_match_full_structure_and_indentation() {
        let options = ParserOptions {
            macro_block_begin: "^BEGIN$".into(),
            macro_block_end: "^END$".into(),
            ..Default::default()
        };
        for source in [
            "#if A\nvoid f() { switch (x) { case 1: a(); b(); case 2: c(); } }\n#else\nvoid g() {}\n#endif\n",
            "void f() { do {\n#if A\n} while (a);\n#else\nif (x) { target(); }\n} while (b);\n#endif\n}\n",
            "namespace n { void f() { target(); }\n",
            "namespace n { class C { public: void f() { if (x) { a(); } else { b(); } next(); } int x; }; }\n",
            "void f() { for (;;) if (x) a(); next(); switch (x) { case 1: a(); case 2: b(); } }\n",
            "enum class E { A = 1, B = f(1, 2), C };\nvoid f() {}\n",
            "#include <x>\nnamespace n { void f() { work(); } }\n#if A\nvoid g() {}\n#endif\n",
            "int a;\nvoid f() { work(); }\nvoid g() {}\n",
            "auto s = R\"tag(raw\ntext)tag\";\n/* comment\nend */\nvoid f() {}\n",
            "template <typename T>\nclass C { T x; };\nint z;\n",
            "BEGIN\nvoid f() { work(); }\nEND\nvoid g() {}\n",
            "#define OPEN namespace n {\n#define CLOSE }\nOPEN\nvoid f() {}\nCLOSE\n",
            "#ifndef HEADER\n#define HEADER\n#define OPEN extern \"C\" {\n#define CLOSE }\nOPEN\nvoid f();\nCLOSE\n#endif\n",
        ] {
            let old = parse_with_options(source, &options);
            for position in 0..=source.len() {
                for inserted in [
                    " ", "\n", "{", "}", ";", "//", "/*", "#else\n", "(", "\"", "界",
                ] {
                    let mut next = source.to_owned();
                    next.insert_str(position, inserted);
                    let tree = reparse(&old, next.clone().into()).0;
                    assert_full(&tree);
                    let state = crate::core::EditorState::new(next);
                    let rules = CppStyle {
                        parser: options.clone(),
                        ..Default::default()
                    }
                    .compile()
                    .unwrap();
                    let full = parse_with_options(tree.source(), &options);
                    for line in 0..state.snapshot().line_count() {
                        assert_eq!(
                            compute_indent(state.snapshot(), &tree, line, &rules).unwrap(),
                            compute_indent(state.snapshot(), &full, line, &rules).unwrap()
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn incremental_repairs_include_the_preceding_item_for_cross_item_attachments() {
        for (source, needle, insert) in [
            (
                "void f() { if (a) work(); next(); }",
                "next",
                "else other(); ",
            ),
            (
                "void f() { for (;;) if (a) work(); next(); }",
                "next",
                "else other(); ",
            ),
            (
                "void f() { switch (x) { case 1: work(); case 2: next(); } }",
                "case 2",
                "other(); ",
            ),
            ("class C {}\nint x;", "int x", ";\n"),
        ] {
            let mut next = source.to_owned();
            next.insert_str(source.find(needle).unwrap(), insert);
            let tree = reparse(&parse(source), next.into()).0;
            assert_full(&tree);
        }
    }

    #[test]
    fn container_repairs_reuse_siblings_inside_large_namespaces_and_classes() {
        let functions = (0..500)
            .map(|i| format!("void f{i}() {{\n    work({i});\n}}\n"))
            .collect::<String>();
        for source in [
            format!("namespace n {{\n{functions}}}\n"),
            format!("namespace n {{\nclass C {{\npublic:\n{functions}}};\n}}\n"),
            format!(
                "#include <x>\n#define OPEN namespace n {{\n#define CLOSE }}\nnamespace n {{\n{functions}}}\n"
            ),
        ] {
            let (tree, work) = reparse(
                &parse(&source),
                source.replacen("work(250)", "other(250, 1)", 1).into(),
            );
            assert_full(&tree);
            assert_eq!(work.strategy, ParseStrategy::Container);
            assert_eq!(work.fallback, None);
            assert!(work.reparsed_tokens < 30, "{work:?}");
            assert!(work.scanned_bytes < 60, "{work:?}");
            assert!(work.reused_nodes > 1000, "{work:?}");
        }
    }

    #[test]
    fn incremental_repairs_report_unsafe_conditional_and_unfinished_contexts() {
        for (source, needle, replacement, expected) in [
            (
                "#include <x>\nvoid f() { work(); }\n",
                "work();",
                "} work();",
                AnalysisFallback::ChangedBoundary,
            ),
            (
                "void f() {\n#if A\nwork();\n#else\nnext();\n#endif\n}\n",
                "work()",
                "other()",
                AnalysisFallback::PreprocessorContext,
            ),
            (
                "void f() { work();",
                "work()",
                "other()",
                AnalysisFallback::IncompleteStructure,
            ),
            (
                "namespace n { void f() { work(); } }",
                "work(); }",
                "work();",
                AnalysisFallback::IncompleteStructure,
            ),
        ] {
            let (tree, work) = reparse(
                &parse(source),
                source.replacen(needle, replacement, 1).into(),
            );
            assert_full(&tree);
            assert_eq!(work.strategy, ParseStrategy::Full);
            assert_eq!(work.fallback, Some(expected));
        }
    }

    #[test]
    fn unrelated_unfinished_regions_do_not_disable_complete_container_repairs() {
        let source =
            "#include <x>\nnamespace n { void f() { work(); } }\nvoid unfinished() { call(\n";
        let (tree, work) = reparse(
            &parse(source),
            source.replacen("work()", "other(1)", 1).into(),
        );
        assert_full(&tree);
        assert_eq!(work.strategy, ParseStrategy::Container);
        assert_eq!(work.fallback, None);
        assert!(work.reparsed_tokens < 20);
    }

    #[test]
    fn conditional_and_reopened_scopes_keep_closed_islands_locally_repairable() {
        for source in [
            "#if A\nvoid f() { target(); }\n#else\nvoid g() {}\n#endif\n",
            "#ifndef H\n#define H\n#if A\nclass C { void f() { target(); } };\n#endif\n#endif\n",
            "void f() {\n#if A\nif (a) { target(); }\n#else\nif (b) { other(); }\n#endif\n}\n",
            "void f() { do {\n#if A\n} while (a);\n#else\nif (x) { target(); }\n} while (b);\n#endif\n}\n",
            "class C {\n#if A\nvoid f() {}\n};\n#else\nvoid f() { target(); }\n};\n#endif\n",
            "namespace n { void f() { target(); }\n",
            "void f() { if (x) { target(); }\n",
        ] {
            let (tree, work) = reparse(
                &parse(source),
                source.replacen("target()", "changed(1, 2)", 1).into(),
            );
            assert_full(&tree);
            assert_eq!(
                work.strategy,
                ParseStrategy::Container,
                "{source}\n{work:?}"
            );
            assert_eq!(work.fallback, None);
            assert!(work.reparsed_tokens < 30, "{work:?}");
        }
    }

    #[test]
    fn large_case_sections_repair_only_adjacent_items_and_expand_on_new_labels() {
        let statements = (0..300)
            .map(|i| format!("  stmt_{i}();\n"))
            .collect::<String>();
        let source = format!(
            "#if A\nvoid f() {{ switch (x) {{\ncase 1:\n{statements}case 2: other();\n}} }}\n#endif\n"
        );
        for (needle, replacement) in [
            ("stmt_150()", "changed(1, 2)"),
            ("case 2:", "added();\ncase 2:"),
            ("case 2:", "\ncase 2:"),
        ] {
            let (tree, work) = reparse(
                &parse(&source),
                source.replacen(needle, replacement, 1).into(),
            );
            assert_full(&tree);
            assert_eq!(work.strategy, ParseStrategy::Container);
            assert!(work.reparsed_tokens < 40, "{work:?}");
            assert!(work.reused_nodes > 500, "{work:?}");
        }
        let (tree, work) = reparse(
            &parse(&source),
            source
                .replacen("stmt_150();", "stmt_150(); case 3: added();", 1)
                .into(),
        );
        assert_full(&tree);
        assert_eq!(work.strategy, ParseStrategy::Container);
        // The new label changes sibling ownership: repair expands to the switch.
        assert!(work.reparsed_tokens > 500, "{work:?}");
    }

    #[test]
    fn directives_and_case_boundary_edits_expand_to_full_preprocessor_analysis() {
        for (source, needle, replacement) in [
            (
                "#if A\nvoid f() { target(); }\n#endif\n",
                "target();",
                "\n#if B\ntarget();\n#endif\n",
            ),
            (
                "#if A\nvoid f() { switch(x) { case 1: target(); } }\n#endif\n",
                "target();",
                "\n#if B\ntarget();\n#endif\n",
            ),
            (
                "#if A\nvoid f() { target(); }\n#endif\n",
                "target();",
                "} target();",
            ),
        ] {
            let (tree, work) = reparse(
                &parse(source),
                source.replacen(needle, replacement, 1).into(),
            );
            assert_full(&tree);
            assert_eq!(work.strategy, ParseStrategy::Full, "{work:?}");
            assert!(work.fallback.is_some());
        }
    }
}
