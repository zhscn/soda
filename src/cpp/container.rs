//! Resume item parsing only at complete, unchanged brace boundaries. Reuse is
//! spliced into the preorder arena; ancestor ranges and sibling IDs are remapped.
use super::{K, N, Parser, SyntaxTree};

pub(super) struct RepairFailure {
    pub tokens: usize,
    pub reason: super::AnalysisFallback,
}

fn subtree_end(tree: &SyntaxTree, mut id: usize) -> usize {
    while let Some(&child) = tree.nodes[id].children.last() {
        id = child;
    }
    id + 1
}

fn path(tree: &SyntaxTree, mut id: usize) -> Vec<usize> {
    let mut path = vec![id];
    while let Some(parent) = tree.nodes[id].parent {
        path.push(parent);
        id = parent;
    }
    path.reverse();
    path
}

pub(super) fn eligible(
    old: &SyntaxTree,
    parser: &Parser,
    id: usize,
    prefix: usize,
    suffix: usize,
) -> bool {
    let node = &old.nodes[id];
    if !matches!(
        node.kind,
        N::NamespaceBody | N::ClassBody | N::CompoundStatement
    ) || node.reclassified
        || node.tokens.len() < 2
    {
        return false;
    }
    let opener = &old.tokens[node.tokens.start];
    let closer = &old.tokens[node.tokens.end - 1];
    if opener.kind != K::LBrace
        || closer.kind != K::RBrace
        || opener.range.end > prefix
        || closer.range.start < old.source.len() - suffix
        || old.nodes[id..subtree_end(old, id)]
            .iter()
            .any(|node| node.incomplete)
        || path(old, id)
            .iter()
            .any(|&id| old.nodes[id].incomplete || old.nodes[id].kind == N::PPReopenedScope)
        || old.tokens[node.tokens.clone()]
            .iter()
            .any(|t| t.preprocessor)
        || super::super::preprocessor::conditional_depth(
            &old.source,
            &old.tokens,
            node.tokens.start,
        ) != Some(0)
    {
        return false;
    }
    let new_close = parser.tree.source.len() - (old.source.len() - closer.range.start);
    let index = parser
        .tree
        .tokens
        .partition_point(|t| t.range.start < new_close);
    parser
        .tree
        .tokens
        .get(index)
        .is_some_and(|t| t.kind == K::RBrace && t.range.start == new_close)
        && parser.tree.tokens.get(node.tokens.start) == Some(opener)
        && !parser.tree.tokens[node.tokens.start..=index]
            .iter()
            .any(|t| t.preprocessor)
}

fn shifted(index: usize, boundary: usize, delta: isize) -> usize {
    if index < boundary {
        index
    } else {
        index
            .checked_add_signed(delta)
            .expect("reused index stays within the arena")
    }
}

pub(super) fn repair(
    old: &SyntaxTree,
    parser: &mut Parser,
    id: usize,
    damage: usize,
    suffix: usize,
) -> Result<(usize, usize), RepairFailure> {
    let children = &old.nodes[id].children;
    let ancestors = path(old, id);
    let enum_body = ancestors
        .iter()
        .rev()
        .find(|&&id| old.nodes[id].kind == N::ClassBody)
        .and_then(|&id| old.nodes[id].parent)
        .is_some_and(|parent| old.tokens[old.nodes[parent].tokens.start].kind == K::EnumKw);
    let barrier = |child: usize| {
        let node = &old.nodes[child];
        node.tokens.end > node.tokens.start
            && (matches!(
                old.tokens[node.tokens.end - 1].kind,
                K::Semicolon | K::RBrace
            ) || (enum_body && old.tokens[node.tokens.end - 1].kind == K::Comma))
    };
    let keep = children
        .iter()
        .enumerate()
        .filter(|&(_, &child)| old.nodes[child].tokens.end <= damage && barrier(child))
        .map(|(i, _)| i + 1)
        .next_back()
        .unwrap_or(0)
        // An else, a following case-body statement, or a class semicolon can
        // attach to the preceding item. Replay that item across the edit edge.
        .saturating_sub(1);
    let old_end = subtree_end(old, id);
    let prefix_nodes = children.get(keep).copied().unwrap_or(old_end);
    parser.tree.nodes = old.nodes[..prefix_nodes].to_vec();
    parser.tree.nodes.reserve(old.nodes.len() - prefix_nodes);
    parser.tree.nodes[id].children.truncate(keep);
    parser.stack = ancestors;
    parser.enum_body = enum_body;
    parser.pp.clear();
    parser.phantoms.clear();
    parser.unwind = None;
    parser.pos = if keep > 0 {
        old.nodes[children[keep - 1]].tokens.end
    } else if id == 0 {
        0
    } else {
        old.nodes[id].tokens.start + 1
    };
    let parse_start = parser.pos;
    let old_close = if id == 0 {
        old.tokens.len() - 1
    } else {
        old.nodes[id].tokens.end - 1
    };
    let close_offset =
        parser.tree.source.len() - (old.source.len() - old.tokens[old_close].range.start);
    let (suffix_index, suffix_node, suffix_token) = loop {
        let kind = parser.kind();
        let position = parser.tree.tokens[parser.pos].range.start;
        if kind == K::EndOfFile || (id != 0 && kind == K::RBrace) {
            if position != close_offset || (id != 0 && kind != K::RBrace) {
                return Err(RepairFailure {
                    tokens: parser.pos.saturating_sub(parse_start),
                    reason: super::AnalysisFallback::ChangedBoundary,
                });
            }
            break (children.len(), old_end, old_close);
        }
        if position >= parser.tree.source.len() - suffix {
            let old_position = old.source.len() - (parser.tree.source.len() - position);
            let index = children.partition_point(|&child| old.range(child).start < old_position);
            if let Some(&child) = children.get(index)
                && index >= keep
                && (index == 0 || barrier(children[index - 1]))
                && old.range(child).start == old_position
            {
                break (index, child, old.nodes[child].tokens.start);
            }
        }
        let first_new = parser.tree.nodes.len();
        parser.guarded();
        if parser.tree.nodes[first_new..].iter().any(|n| n.incomplete) {
            return Err(RepairFailure {
                tokens: parser.pos.saturating_sub(parse_start),
                reason: super::AnalysisFallback::IncompleteStructure,
            });
        }
    };
    let reparsed = parser.pos - parse_start;
    let token_delta = parser.pos as isize - suffix_token as isize;
    let node_delta = parser.tree.nodes.len() as isize - suffix_node as isize;
    // Prefix nodes outside the repaired container can span it or own following
    // siblings. Only their old references are remapped; new child IDs stay local.
    for (index, node) in parser.tree.nodes[..prefix_nodes].iter_mut().enumerate() {
        if node.tokens.end > suffix_token {
            node.tokens.end = shifted(node.tokens.end, suffix_token, token_delta);
        }
        if index != id {
            for child in &mut node.children {
                *child = shifted(*child, suffix_node, node_delta);
            }
        }
    }
    for node in &old.nodes[suffix_node..] {
        let mut node = node.clone();
        node.tokens = shifted(node.tokens.start, suffix_token, token_delta)
            ..shifted(node.tokens.end, suffix_token, token_delta);
        node.parent = node
            .parent
            .map(|parent| shifted(parent, suffix_node, node_delta));
        for child in &mut node.children {
            *child = shifted(*child, suffix_node, node_delta);
        }
        parser.tree.nodes.push(node);
    }
    parser.tree.nodes[id].children.extend(
        children[suffix_index..]
            .iter()
            .map(|&child| shifted(child, suffix_node, node_delta)),
    );
    parser.tree.nodes[0].tokens.end = parser.tree.tokens.len();
    parser.tree.index_tokens();
    Ok((reparsed, prefix_nodes + old.nodes.len() - suffix_node))
}
