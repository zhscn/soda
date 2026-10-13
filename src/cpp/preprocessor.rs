//! Logical directive boundaries and the conventional file-level include guard.
use super::{Token, TokenKind as K};

pub(super) fn directive_end(tokens: &[Token], hash: usize) -> usize {
    hash + tokens[hash..]
        .iter()
        .take_while(|t| t.preprocessor && t.kind != K::Newline)
        .count()
}

pub(super) fn keyword<'a>(source: &'a str, tokens: &[Token], hash: usize) -> Option<&'a str> {
    tokens[hash + 1..directive_end(tokens, hash)]
        .iter()
        .find(|t| !t.kind.is_trivia())
        .map(|t| &source[t.range.clone()])
}

pub(super) fn include_guard(source: &str, tokens: &[Token]) -> bool {
    let significant = tokens
        .iter()
        .filter(|t| !t.kind.is_trivia() && t.kind != K::EndOfFile);
    let first = significant.clone().take(6).collect::<Vec<_>>();
    if first.len() != 6
        || first[0].kind != K::PreprocessorHash
        || &source[first[1].range.clone()] != "ifndef"
        || first[2].kind != K::Identifier
        || first[3].kind != K::PreprocessorHash
        || &source[first[4].range.clone()] != "define"
        || source[first[2].range.clone()] != source[first[5].range.clone()]
    {
        return false;
    }
    let last = significant.rev().take(2).collect::<Vec<_>>();
    if last.len() != 2
        || &source[last[0].range.clone()] != "endif"
        || last[1].kind != K::PreprocessorHash
    {
        return false;
    }
    let mut depth = 0usize;
    for (hash, token) in tokens
        .iter()
        .enumerate()
        .filter(|(_, t)| t.kind == K::PreprocessorHash && t.preprocessor)
    {
        match keyword(source, tokens, hash) {
            Some("if" | "ifdef" | "ifndef") => depth += 1,
            Some("endif") => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return token.range.start == last[1].range.start;
                }
            }
            Some("else" | "elif" | "elifdef" | "elifndef") if depth == 1 => return false,
            _ => {}
        }
    }
    false
}

pub(super) fn conditional_depth(source: &str, tokens: &[Token], before: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (hash, _) in tokens[..before]
        .iter()
        .enumerate()
        .filter(|(_, t)| t.kind == K::PreprocessorHash && t.preprocessor)
    {
        match keyword(source, tokens, hash) {
            Some("if" | "ifdef" | "ifndef") => depth += 1,
            Some("endif") => depth = depth.checked_sub(1)?,
            Some("else" | "elif" | "elifdef" | "elifndef") if depth == 0 => return None,
            _ => {}
        }
    }
    Some(depth)
}
