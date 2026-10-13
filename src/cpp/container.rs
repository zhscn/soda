//! Resume item parsing at unchanged brace or case-label boundaries. Reuse is
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

struct Region {
    start: usize,
    boundary: usize,
    case_section: bool,
}
fn region(tree: &SyntaxTree, id: usize) -> Option<Region> {
    let node = &tree.nodes[id];
    if id == 0 {
        return Some(Region {
            start: 0,
            boundary: tree.tokens.len() - 1,
            case_section: false,
        });
    }
    if node.kind == N::CaseSection {
        let label = tree.nodes.get(*node.children.first()?)?;
        if label.kind != N::CaseLabel
            || label.tokens.is_empty()
            || tree.tokens[label.tokens.end - 1].kind != K::Colon
        {
            return None;
        }
        let boundary =
            (node.tokens.end..tree.tokens.len()).find(|&i| !tree.tokens[i].kind.is_trivia())?;
        return matches!(
            tree.format_kind(boundary),
            K::CaseKw | K::DefaultKw | K::RBrace | K::EndOfFile
        )
        .then_some(Region {
            start: label.tokens.end,
            boundary,
            case_section: true,
        });
    }
    if matches!(
        node.kind,
        N::NamespaceBody | N::ClassBody | N::CompoundStatement
    ) && !node.reclassified
        && node.tokens.len() >= 2
        && tree.tokens[node.tokens.start].kind == K::LBrace
        && tree.tokens[node.tokens.end - 1].kind == K::RBrace
    {
        return Some(Region {
            start: node.tokens.start + 1,
            boundary: node.tokens.end - 1,
            case_section: false,
        });
    }
    None
}

pub(super) fn eligible(
    old: &SyntaxTree,
    parser: &Parser,
    id: usize,
    prefix: usize,
    suffix: usize,
) -> bool {
    let node = &old.nodes[id];
    let Some(region) = region(old, id) else {
        return false;
    };
    let opener = &old.tokens[region.start - 1];
    let closer = &old.tokens[region.boundary];
    if opener.range.end > prefix
        || closer.range.start < old.source.len() - suffix
        || old.nodes[id..subtree_end(old, id)]
            .iter()
            .any(|node| node.incomplete)
        || old.tokens[node.tokens.start..region.boundary]
            .iter()
            .any(|t| t.preprocessor)
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
        .is_some_and(|t| t.kind == closer.kind && t.range.start == new_close)
        && parser.tree.tokens.get(region.start - 1) == Some(opener)
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
    let region = region(old, id).expect("repair requires a supported region");
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
        .saturating_sub(1)
        .max(usize::from(region.case_section));
    let old_end = subtree_end(old, id);
    let prefix_nodes = children.get(keep).copied().unwrap_or(old_end);
    parser.tree.nodes = old.nodes[..prefix_nodes].to_vec();
    parser.tree.nodes.reserve(old.nodes.len() - prefix_nodes);
    parser.tree.nodes[id].children.truncate(keep);
    parser.stack = ancestors;
    parser.enum_body = enum_body;
    // A closed island cannot consult or change conditional frames: neither its
    // original nor edited token range contains a directive. Outer branch facts
    // stay in the reused tree and are never replayed by this parser instance.
    parser.pp.clear();
    parser.phantoms.clear();
    parser.unwind = None;
    parser.pos = if keep > 0 {
        old.nodes[children[keep - 1]].tokens.end
    } else {
        region.start
    };
    let parse_start = parser.pos;
    let old_close = region.boundary;
    let closing_kind = old.format_kind(old_close);
    let close_offset =
        parser.tree.source.len() - (old.source.len() - old.tokens[old_close].range.start);
    let (suffix_index, suffix_node, suffix_token) = loop {
        let kind = parser.kind();
        let position = parser.tree.tokens[parser.pos].range.start;
        if kind == K::EndOfFile
            || (id != 0 && kind == K::RBrace)
            || (region.case_section && matches!(kind, K::CaseKw | K::DefaultKw))
        {
            if position != close_offset || kind != closing_kind {
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
    if region.case_section {
        // Case sections have no closing token of their own. Their range ends
        // at the final item, excluding trivia before the next label or closer.
        let last = *parser.tree.nodes[id]
            .children
            .last()
            .expect("case label is retained");
        parser.tree.nodes[id].tokens.end = parser.tree.nodes[last].tokens.end;
    }
    parser.tree.nodes[0].tokens.end = parser.tree.tokens.len();
    parser.tree.index_tokens();
    Ok((reparsed, prefix_nodes + old.nodes.len() - suffix_node))
}
