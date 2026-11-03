//! Trees that Lua shows in a document, such as a call hierarchy: nodes with
//! a label and a detail, expanded and collapsed in place. Children can come
//! with a node or later, when it is first expanded: the tree asks Lua and
//! shows the node as loading until they arrive.
//!
//! The document is a scratch document whose text is the visible rows; it is
//! rewritten whenever a node opens or closes, and the caret stays on the
//! node it was on.
use std::collections::HashMap;

/// A node as Lua gives it; `id` is Lua's, to name it in callbacks.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NodeSpec {
    pub id: u64,
    pub label: String,
    pub detail: String,
    /// Known children; none for a node whose children come when asked.
    pub children: Option<Vec<NodeSpec>>,
    /// Whether a node without known children may have some.
    pub more: bool,
    pub expanded: bool,
}
struct Node {
    label: String,
    detail: String,
    parent: Option<u64>,
    depth: usize,
    children: Option<Vec<u64>>,
    more: bool,
    expanded: bool,
    loading: bool,
}
/// One visible row: its node, and where the label and the detail are.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub node: u64,
    pub label: usize,
    pub detail: Option<std::ops::Range<usize>>,
}
/// What a key on a row asks of Lua.
#[derive(Debug, PartialEq)]
pub enum Ask {
    Expand(u64),
    Open(u64),
}
pub struct Tree {
    /// The callback Lua takes events through.
    pub function: u64,
    nodes: HashMap<u64, Node>,
    roots: Vec<u64>,
    rows: Vec<Row>,
}
impl Tree {
    pub fn new(function: u64, roots: Vec<NodeSpec>) -> Self {
        let mut tree = Self {
            function,
            nodes: HashMap::new(),
            roots: vec![],
            rows: vec![],
        };
        tree.roots = tree.insert(roots, None, 0);
        tree
    }
    fn insert(&mut self, specs: Vec<NodeSpec>, parent: Option<u64>, depth: usize) -> Vec<u64> {
        let mut ids = vec![];
        for spec in specs {
            let children = spec
                .children
                .map(|children| self.insert(children, Some(spec.id), depth + 1));
            self.nodes.insert(
                spec.id,
                Node {
                    label: spec.label,
                    detail: spec.detail,
                    parent,
                    depth,
                    expanded: spec.expanded && children.as_ref().is_some_and(|c| !c.is_empty()),
                    children,
                    more: spec.more,
                    loading: false,
                },
            );
            ids.push(spec.id);
        }
        ids
    }
    /// Children that came for a node that asked for them; it opens.
    pub fn set_children(&mut self, id: u64, children: Vec<NodeSpec>) -> bool {
        let Some(depth) = self.nodes.get(&id).map(|node| node.depth) else {
            return false;
        };
        let ids = self.insert(children, Some(id), depth + 1);
        let node = self.nodes.get_mut(&id).unwrap();
        node.expanded = !ids.is_empty();
        node.more = false;
        node.loading = false;
        node.children = Some(ids);
        true
    }
    fn expandable(node: &Node) -> bool {
        match &node.children {
            Some(children) => !children.is_empty(),
            None => node.more,
        }
    }
    /// The text of the visible rows, which `rows` then describes.
    pub fn render(&mut self) -> String {
        let mut text = String::new();
        self.rows.clear();
        let mut stack: Vec<u64> = self.roots.iter().rev().copied().collect();
        while let Some(id) = stack.pop() {
            let node = &self.nodes[&id];
            text.push_str(&"  ".repeat(node.depth));
            text.push_str(
                match (Self::expandable(node), node.expanded || node.loading) {
                    (false, _) => "  ",
                    (true, false) => "▸ ",
                    (true, true) => "▾ ",
                },
            );
            let label = text.len();
            text.push_str(&node.label.replace('\n', " "));
            if node.loading {
                text.push_str(" …");
            }
            let detail = (!node.detail.is_empty()).then(|| {
                text.push_str("  ");
                let start = text.len();
                text.push_str(&node.detail.replace('\n', " "));
                start..text.len()
            });
            text.push('\n');
            let line = text[..label].rfind('\n').map_or(0, |at| at + 1);
            self.rows.push(Row {
                node: id,
                label: label - line,
                detail: detail.map(|d| d.start - line..d.end - line),
            });
            if node.expanded {
                for child in node.children.iter().flatten().rev() {
                    stack.push(*child);
                }
            }
        }
        text
    }
    pub fn rows(&self) -> &[Row] {
        &self.rows
    }
    /// The row a node shows on, if it is visible.
    pub fn row_of(&self, id: u64) -> Option<usize> {
        self.rows.iter().position(|row| row.node == id)
    }
    /// Opens or closes the node on a row; a node whose children are not
    /// known yet asks for them.
    pub fn toggle(&mut self, row: usize) -> Option<Ask> {
        let id = self.rows.get(row)?.node;
        let node = self.nodes.get_mut(&id)?;
        if !Self::expandable(node) || node.loading {
            return None;
        }
        if node.children.is_none() {
            node.loading = true;
            return Some(Ask::Expand(id));
        }
        node.expanded = !node.expanded;
        None
    }
    /// Closes the node on a row, or else goes to its parent: the row to go
    /// to.
    pub fn collapse(&mut self, row: usize) -> Option<u64> {
        let id = self.rows.get(row)?.node;
        let node = self.nodes.get_mut(&id)?;
        if node.expanded {
            node.expanded = false;
            return Some(id);
        }
        node.parent
    }
    pub fn open(&self, row: usize) -> Option<Ask> {
        Some(Ask::Open(self.rows.get(row)?.node))
    }
}

impl super::Runtime {
    /// Shows a tree in the document `*name*`, replacing one there, with the
    /// caret on its first row.
    pub(super) fn show_tree(&mut self, name: String, mut tree: Tree) {
        use crate::application::Event;
        let buffer = format!("*{name}*");
        let text = tree.render();
        let caret = tree.rows().first().map_or(0, |row| row.label);
        self.dispatch(Event::ResultsDisplay { kind: name });
        self.dispatch(Event::Scratch {
            name: buffer.clone(),
            text,
            directory: self.app.root(),
        });
        let Some(document) = self.app.workspace().scratch(&buffer) else {
            return;
        };
        self.dispatch(Event::MarkTree(document));
        if let Some(view) = self.app.active_view() {
            self.dispatch(Event::Edit {
                view,
                command: crate::editor::Command::SetSelection(crate::core::Selection::caret(caret)),
                time: std::time::Duration::ZERO,
            });
        }
        self.paint_tree(document, &tree);
        if let Some(old) = self.trees.insert(buffer, tree) {
            self.released.push(old.function);
        }
    }
    /// Forgets the trees whose documents closed, and their functions.
    pub(super) fn forget_closed_trees(&mut self) {
        let workspace = self.app.workspace();
        let released = &mut self.released;
        self.trees.retain(|buffer, tree| {
            let open = workspace.scratch(buffer).is_some();
            if !open {
                released.push(tree.function);
            }
            open
        });
    }
    /// Colours the details of a tree's rows.
    fn paint_tree(&mut self, document: crate::editor::DocumentId, tree: &Tree) {
        let face = crate::application::faces::index("detail").map(crate::application::Face::Named);
        let Some(face) = face else { return };
        let paints = tree
            .rows()
            .iter()
            .enumerate()
            .filter_map(|(line, row)| {
                let detail = row.detail.clone()?;
                Some(crate::application::PaintSpan {
                    start: (line, detail.start),
                    end: (line, detail.end),
                    face,
                })
            })
            .collect();
        self.dispatch(crate::application::Event::Paint {
            document,
            group: "tree".into(),
            paints,
        });
    }
    /// The tree a document shows, and the row of its caret.
    fn tree_here(&self) -> Option<(String, crate::editor::DocumentId, usize)> {
        let view = self.app.view(self.app.active_view()?)?;
        let document = view.document_id;
        let buffer = self.app.workspace().file(document)?.scratch()?.to_owned();
        self.trees.contains_key(&buffer).then_some(())?;
        let editor = self.app.workspace().editor(document)?;
        let head = editor.model().session(view.session_id)?.selection().head;
        let row = editor.model().document().snapshot().line_of(head)?;
        Some((buffer, document, row))
    }
    /// Writes a tree out again, with the caret on `keep`, or else on the
    /// node it was on.
    fn redraw_tree(&mut self, buffer: &str, keep: Option<u64>) {
        let Some(document) = self.app.workspace().scratch(buffer) else {
            return;
        };
        let caret_row = self
            .app
            .views()
            .find(|view| view.document_id == document)
            .and_then(|view| {
                let editor = self.app.workspace().editor(document)?;
                let head = editor.model().session(view.session_id)?.selection().head;
                editor.model().document().snapshot().line_of(head)
            });
        let Some(tree) = self.trees.get_mut(buffer) else {
            return;
        };
        let keep = keep.or_else(|| Some(tree.rows().get(caret_row?)?.node));
        let text = tree.render();
        let row = keep.and_then(|id| tree.row_of(id)).unwrap_or(0);
        let start: usize = text.split_inclusive('\n').take(row).map(str::len).sum();
        let caret = start + tree.rows().get(row).map_or(0, |row| row.label);
        self.dispatch(crate::application::Event::ReplaceText {
            document,
            text,
            caret,
        });
        let tree = self.trees.remove(buffer).unwrap();
        self.paint_tree(document, &tree);
        self.trees.insert(buffer.to_owned(), tree);
    }
    /// A key on a tree's row.
    pub(super) fn tree_action(&mut self, action: crate::interaction::modal::TreeAction) {
        use crate::interaction::modal::TreeAction;
        let Some((buffer, _, row)) = self.tree_here() else {
            return;
        };
        let tree = self.trees.get_mut(&buffer).unwrap();
        let (ask, keep) = match action {
            TreeAction::Toggle => (tree.toggle(row), None),
            TreeAction::Collapse => (None, tree.collapse(row)),
            TreeAction::Open => (tree.open(row), None),
        };
        let function = tree.function;
        if action != TreeAction::Open {
            self.redraw_tree(&buffer, keep);
        }
        let argument = match ask {
            Some(Ask::Expand(id)) => format!("expand {id}"),
            Some(Ask::Open(id)) => format!("open {id}"),
            None => return,
        };
        let view = self.app.active_view();
        self.lua_queue.push_back((
            super::lua::Request::Call {
                id: function,
                argument,
            },
            view,
        ));
        self.run_lua();
    }
    /// Children Lua found for a node of the tree in `*name*`.
    pub(super) fn tree_children(&mut self, name: &str, id: u64, children: Vec<NodeSpec>) {
        let buffer = format!("*{name}*");
        if let Some(tree) = self.trees.get_mut(&buffer)
            && tree.set_children(id, children)
        {
            self.redraw_tree(&buffer, None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(id: u64, label: &str, children: Option<Vec<NodeSpec>>) -> NodeSpec {
        NodeSpec {
            id,
            label: label.into(),
            detail: String::new(),
            children,
            more: true,
            expanded: false,
        }
    }
    #[test]
    fn nodes_open_close_and_load_their_children_once() {
        let mut tree = Tree::new(
            9,
            vec![
                NodeSpec {
                    detail: "a.cpp:1".into(),
                    ..node(1, "main", Some(vec![node(2, "helper", None)]))
                },
                NodeSpec {
                    more: false,
                    ..node(3, "leaf", None)
                },
            ],
        );
        assert_eq!(tree.render(), "▸ main  a.cpp:1\n  leaf\n");
        // In bytes: the marker takes four.
        assert_eq!(tree.rows()[0].label, 4);
        assert_eq!(tree.rows()[0].detail, Some(10..17));
        assert_eq!(tree.toggle(0), None);
        assert_eq!(tree.render(), "▾ main  a.cpp:1\n  ▸ helper\n  leaf\n");
        // Unknown children are asked for, and the node waits.
        assert_eq!(tree.toggle(1), Some(Ask::Expand(2)));
        assert_eq!(tree.render(), "▾ main  a.cpp:1\n  ▾ helper …\n  leaf\n");
        assert_eq!(tree.toggle(1), None, "asked once");
        tree.set_children(
            2,
            vec![NodeSpec {
                more: false,
                ..node(4, "deep", None)
            }],
        );
        assert_eq!(
            tree.render(),
            "▾ main  a.cpp:1\n  ▾ helper\n      deep\n  leaf\n"
        );
        // From a leaf, collapsing goes to the parent; then it closes.
        assert_eq!(tree.collapse(2), Some(2));
        assert_eq!(tree.row_of(2), Some(1));
        assert_eq!(tree.collapse(1), Some(2));
        assert_eq!(tree.render(), "▾ main  a.cpp:1\n  ▸ helper\n  leaf\n");
        assert_eq!(tree.open(2), Some(Ask::Open(3)));
        // No children at all is a leaf.
        tree.set_children(2, vec![]);
        assert_eq!(tree.render(), "▾ main  a.cpp:1\n    helper\n  leaf\n");
    }
}
