//! Structural macro facts over original tokens; no synthetic source or general
//! preprocessor evaluation is involved. Branches merge only agreeing bindings.
use super::{ParserOptions, Token, TokenKind as K};
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum BlockMacro {
    Namespace,
    Extern,
    Open,
    Close,
}
impl BlockMacro {
    pub fn kind(self) -> K {
        if self == Self::Close {
            K::RBrace
        } else {
            K::LBrace
        }
    }
}

type Bindings = BTreeMap<String, BlockMacro>;
struct Branch {
    base: Bindings,
    agreed: Option<Bindings>,
    has_else: bool,
    guard: bool,
}
impl Branch {
    fn merge(&mut self, current: &Bindings) {
        match &mut self.agreed {
            Some(agreed) => agreed.retain(|name, kind| current.get(name) == Some(kind)),
            None => self.agreed = Some(current.clone()),
        }
    }
}

fn replacement(source: &str, tokens: &[Token], indices: &[usize]) -> Option<BlockMacro> {
    let kinds = indices.iter().map(|&i| tokens[i].kind).collect::<Vec<_>>();
    match kinds.as_slice() {
        [K::RBrace] => Some(BlockMacro::Close),
        [K::LBrace] => Some(BlockMacro::Open),
        [K::Identifier, K::StringLiteral, K::LBrace]
            if &source[tokens[indices[0]].range.clone()] == "extern"
                && matches!(
                    &source[tokens[indices[1]].range.clone()],
                    "\"C\"" | "\"C++\""
                ) =>
        {
            Some(BlockMacro::Extern)
        }
        [K::NamespaceKw, rest @ ..]
            if rest.last() == Some(&K::LBrace)
                && rest[..rest.len() - 1]
                    .iter()
                    .all(|k| matches!(k, K::Identifier | K::ColonColon)) =>
        {
            Some(BlockMacro::Namespace)
        }
        _ => None,
    }
}

pub(super) fn classify(
    source: &str,
    tokens: &[Token],
    options: &ParserOptions,
) -> Vec<Option<BlockMacro>> {
    let compile = |pattern: &str| {
        (!pattern.is_empty())
            .then(|| regex::Regex::new(pattern).ok())
            .flatten()
    };
    let begin = compile(&options.macro_block_begin);
    let end = compile(&options.macro_block_end);
    let mut bindings = Bindings::new();
    let mut branches = Vec::<Branch>::new();
    let mut result = vec![None; tokens.len()];
    let guard = super::preprocessor::include_guard(source, tokens);
    let guard_start = tokens.iter().position(|t| !t.kind.is_trivia());
    let mut i = 0;
    let mut overflow = 0usize;
    while i < tokens.len() {
        if tokens[i].kind == K::PreprocessorHash && tokens[i].preprocessor {
            let start = i;
            i = super::preprocessor::directive_end(tokens, start);
            let indices = (start + 1..i)
                .filter(|&i| !tokens[i].kind.is_trivia())
                .collect::<Vec<_>>();
            let Some(&keyword) = indices.first() else {
                continue;
            };
            let text = |index: usize| &source[tokens[index].range.clone()];
            match text(keyword) {
                "if" | "ifdef" | "ifndef" => {
                    if branches.len() == 128 || overflow > 0 {
                        overflow += 1;
                        bindings.clear();
                    } else {
                        branches.push(Branch {
                            base: bindings.clone(),
                            agreed: None,
                            has_else: false,
                            guard: guard && Some(start) == guard_start,
                        });
                    }
                }
                "else" | "elif" | "elifdef" | "elifndef" if overflow == 0 => {
                    if let Some(branch) = branches.last_mut() {
                        branch.merge(&bindings);
                        bindings = branch.base.clone();
                        branch.has_else |= text(keyword) == "else";
                    }
                }
                "endif" => {
                    if overflow > 0 {
                        overflow -= 1;
                    } else if let Some(mut branch) = branches.pop() {
                        branch.merge(&bindings);
                        if !branch.has_else && !branch.guard {
                            let base = std::mem::take(&mut branch.base);
                            branch.merge(&base);
                        }
                        bindings = branch.agreed.unwrap_or_default();
                    }
                }
                "define" | "undef" if overflow == 0 => {
                    if let Some(&name) = indices.get(1)
                        && tokens[name].kind == K::Identifier
                    {
                        bindings.remove(text(name));
                        if text(keyword) == "define" {
                            let body = &indices[2..];
                            // An adjacent '(' denotes a function-like definition.
                            let function_like = body.first().is_some_and(|&first| {
                                tokens[first].kind == K::LParen
                                    && tokens[name].range.end == tokens[first].range.start
                            });
                            if !function_like && let Some(kind) = replacement(source, tokens, body)
                            {
                                bindings.insert(text(name).into(), kind);
                            }
                        }
                    }
                }
                _ => {}
            }
            continue;
        }
        if tokens[i].kind == K::Identifier && !tokens[i].preprocessor {
            let name = &source[tokens[i].range.clone()];
            result[i] = bindings.get(name).copied().or_else(|| {
                if begin.as_ref().is_some_and(|re| re.is_match(name)) {
                    Some(BlockMacro::Open)
                } else if end.as_ref().is_some_and(|re| re.is_match(name)) {
                    Some(BlockMacro::Close)
                } else {
                    None
                }
            });
        }
        i += 1;
    }
    result
}
