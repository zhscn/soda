//! Reuse is restricted to token-equivalent analyses and complete declarations
//! separated by a syntax barrier. Conditional and unfinished contexts fall back.
use super::{K, Parser, SyntaxTree, parse_tokens};
use crate::cpp::Token;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ParseStrategy {
    Full,
    TokenEquivalent,
    Declarations,
}

/// Work performed by the latest analysis, excluding source materialization and
/// rebuilding token ownership. Counts describe work, not stable node identity.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AnalysisWork {
    pub strategy: ParseStrategy,
    pub scanned_bytes: usize,
    pub reparsed_tokens: usize,
    pub reused_nodes: usize,
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
        };
        return (tree, work);
    }
    // Conditional frames and unfinished productions cross declaration boundaries.
    // Keep the whole parser as the authoritative fallback for those documents.
    let safe = !old.nodes.iter().any(|n| n.incomplete)
        && !old.tokens.iter().chain(&tokens).any(|t| t.preprocessor);
    if safe {
        let damage = old
            .tokens
            .iter()
            .zip(&tokens)
            .position(|(a, b)| !equivalent(a, b))
            .unwrap_or(old.tokens.len().min(tokens.len()));
        let children = &old.nodes[0].children;
        let barrier = |id: usize| {
            let node = &old.nodes[id];
            node.tokens.end > node.tokens.start
                && matches!(
                    old.tokens[node.tokens.end - 1].kind,
                    K::Semicolon | K::RBrace
                )
        };
        let keep = children
            .iter()
            .enumerate()
            .filter(|&(_, &id)| old.nodes[id].tokens.end <= damage && barrier(id))
            .map(|(i, _)| i + 1)
            .next_back()
            .unwrap_or(0);
        let node_end = children.get(keep).copied().unwrap_or(old.nodes.len());
        let mut p = Parser::new(source.clone(), &old.parser_options, tokens);
        p.tree.nodes = old.nodes[..node_end].to_vec();
        p.tree.nodes.reserve(old.nodes.len() - node_end);
        p.tree.nodes[0].children.truncate(keep);
        p.stack.push(0);
        p.pos = if keep == 0 {
            0
        } else {
            old.nodes[children[keep - 1]].tokens.end
        };
        let parse_start = p.pos;
        let suffix = old
            .source
            .bytes()
            .rev()
            .zip(source.bytes().rev())
            .take_while(|(a, b)| a == b)
            .count();
        let mut reused_nodes = node_end;
        loop {
            if p.kind() == K::EndOfFile {
                break;
            }
            let position = p.tree.tokens[p.pos].range.start;
            let candidate = if position >= source.len() - suffix {
                let old_position = old.source.len() - (source.len() - position);
                let index = children.partition_point(|&id| old.range(id).start < old_position);
                children
                    .get(index)
                    .filter(|&&id| {
                        index >= keep
                            && index > 0
                            && barrier(children[index - 1])
                            && old.range(id).start == old_position
                    })
                    .map(|id| (index, id))
            } else {
                None
            };
            if let Some((index, &id)) = candidate {
                let token_shift = p.pos as isize - old.nodes[id].tokens.start as isize;
                let node_shift = p.tree.nodes.len() as isize - id as isize;
                for node in &old.nodes[id..] {
                    let mut node = node.clone();
                    node.tokens = node.tokens.start.checked_add_signed(token_shift).unwrap()
                        ..node.tokens.end.checked_add_signed(token_shift).unwrap();
                    node.parent = node.parent.map(|parent| {
                        if parent == 0 {
                            0
                        } else {
                            parent.checked_add_signed(node_shift).unwrap()
                        }
                    });
                    for child in &mut node.children {
                        *child = child.checked_add_signed(node_shift).unwrap();
                    }
                    p.tree.nodes.push(node);
                }
                p.tree.nodes[0].children.extend(
                    children[index..]
                        .iter()
                        .map(|&child| child.checked_add_signed(node_shift).unwrap()),
                );
                reused_nodes += old.nodes.len() - id;
                break;
            }
            p.guarded();
        }
        let reparsed_tokens = p.pos - parse_start;
        // A changed declaration may leave the suffix inside an unfinished scope.
        // Such results are cheap to reject before exposing any partial structure.
        if !p.tree.nodes.iter().any(|n| n.incomplete) {
            p.tree.nodes[0].tokens.end = p.tree.tokens.len();
            p.tree.index_tokens();
            return (
                p.tree,
                AnalysisWork {
                    strategy: ParseStrategy::Declarations,
                    scanned_bytes,
                    reparsed_tokens,
                    reused_nodes,
                },
            );
        }
        let tokens = p.tree.tokens;
        let work = AnalysisWork {
            strategy: ParseStrategy::Full,
            scanned_bytes,
            reparsed_tokens: tokens.len() + reparsed_tokens,
            reused_nodes: 0,
        };
        return (parse_tokens(source, &old.parser_options, tokens), work);
    }
    let work = AnalysisWork {
        strategy: ParseStrategy::Full,
        scanned_bytes,
        reparsed_tokens: tokens.len(),
        reused_nodes: 0,
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
        assert_eq!(work.strategy, ParseStrategy::Declarations);
        assert!(work.reparsed_tokens < 40);
        assert!(work.reused_nodes > 100);
        assert!(work.scanned_bytes < 60);
    }

    #[test]
    fn incremental_analysis_matches_full_parse_under_repeated_utf8_edits() {
        let samples = [
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
}
