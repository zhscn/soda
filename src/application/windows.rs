//! The window tree: how visible views split the editing area. Each window
//! shows one view; views outside the tree stay open but hidden. Splits
//! divide their area equally among children, and a split never holds a
//! single child.
use super::ViewId;

/// How a split arranges its children.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Axis {
    /// Stacked top to bottom, as Vim's `:split`.
    Rows,
    /// Side by side, as Vim's `:vsplit`.
    Columns,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}
/// A cell rectangle, in whatever units the caller lays out in.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Area {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}
impl Area {
    fn right(self) -> u16 {
        self.x + self.width
    }
    fn bottom(self) -> u16 {
        self.y + self.height
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Node {
    Window(ViewId),
    Split { axis: Axis, children: Vec<Node> },
}
#[derive(Clone, Debug, Default)]
pub struct Windows {
    root: Option<Node>,
}
impl Windows {
    pub fn root(&self) -> Option<&Node> {
        self.root.as_ref()
    }
    /// Visible views, top to bottom and left to right.
    pub fn views(&self) -> Vec<ViewId> {
        fn walk(node: &Node, out: &mut Vec<ViewId>) {
            match node {
                Node::Window(view) => out.push(*view),
                Node::Split { children, .. } => children.iter().for_each(|c| walk(c, out)),
            }
        }
        let mut out = vec![];
        if let Some(root) = &self.root {
            walk(root, &mut out);
        }
        out
    }
    pub fn contains(&self, view: ViewId) -> bool {
        self.views().contains(&view)
    }
    pub fn len(&self) -> usize {
        self.views().len()
    }
    pub fn is_empty(&self) -> bool {
        self.root.is_none()
    }
    fn find(&mut self, view: ViewId) -> Option<&mut Node> {
        fn walk(node: &mut Node, view: ViewId) -> Option<&mut Node> {
            match node {
                Node::Window(id) if *id == view => Some(node),
                Node::Window(_) => None,
                Node::Split { children, .. } => children.iter_mut().find_map(|c| walk(c, view)),
            }
        }
        walk(self.root.as_mut()?, view)
    }
    /// Shows `new` in the window of `old`, or as the only window when the
    /// tree is empty.
    pub fn replace(&mut self, old: Option<ViewId>, new: ViewId) {
        if self.root.is_none() {
            self.root = Some(Node::Window(new));
        } else if let Some(node) = old.and_then(|old| self.find(old)) {
            *node = Node::Window(new);
        }
    }
    /// Splits the window of `at`, putting `new` after it.
    pub fn split(&mut self, at: ViewId, new: ViewId, axis: Axis) {
        fn walk(node: &mut Node, at: ViewId, new: ViewId, axis: Axis) -> bool {
            match node {
                Node::Window(id) if *id == at => {
                    *node = Node::Split {
                        axis,
                        children: vec![Node::Window(at), Node::Window(new)],
                    };
                    true
                }
                Node::Window(_) => false,
                Node::Split {
                    axis: own,
                    children,
                } => {
                    // A split along the same axis gains a sibling instead
                    // of nesting, so repeated splits stay equal.
                    if *own == axis
                        && let Some(index) = children.iter().position(|c| *c == Node::Window(at))
                    {
                        children.insert(index + 1, Node::Window(new));
                        return true;
                    }
                    children.iter_mut().any(|c| walk(c, at, new, axis))
                }
            }
        }
        if let Some(root) = &mut self.root {
            walk(root, at, new, axis);
        }
    }
    /// Closes the window of `view`; its siblings take the space.
    pub fn remove(&mut self, view: ViewId) {
        fn walk(node: &mut Node, view: ViewId) -> bool {
            let Node::Split { children, .. } = node else {
                return false;
            };
            if let Some(index) = children.iter().position(|c| *c == Node::Window(view)) {
                children.remove(index);
            } else if !children.iter_mut().any(|c| walk(c, view)) {
                return false;
            }
            if children.len() == 1 {
                *node = children.pop().unwrap();
            }
            true
        }
        match &mut self.root {
            Some(Node::Window(id)) if *id == view => self.root = None,
            Some(root) => {
                walk(root, view);
            }
            None => {}
        }
    }
    /// Keeps only the window of `view`.
    pub fn only(&mut self, view: ViewId) {
        self.root = Some(Node::Window(view));
    }
    /// Each window's area within `area`. Side-by-side windows leave one
    /// column between them for a separator.
    pub fn layout(&self, area: Area) -> Vec<(ViewId, Area)> {
        fn walk(node: &Node, area: Area, out: &mut Vec<(ViewId, Area)>) {
            match node {
                Node::Window(view) => out.push((*view, area)),
                Node::Split { axis, children } => {
                    let n = children.len() as u16;
                    let (total, gap) = match axis {
                        Axis::Columns => (area.width.saturating_sub(n - 1), 1),
                        Axis::Rows => (area.height, 0),
                    };
                    let mut offset = 0;
                    for (index, child) in children.iter().enumerate() {
                        let index = index as u16;
                        let size = total / n + u16::from(index < total % n);
                        let child_area = match axis {
                            Axis::Columns => Area {
                                x: area.x + offset,
                                width: size,
                                ..area
                            },
                            Axis::Rows => Area {
                                y: area.y + offset,
                                height: size,
                                ..area
                            },
                        };
                        walk(child, child_area, out);
                        offset += size + gap;
                    }
                }
            }
        }
        let mut out = vec![];
        if let Some(root) = &self.root {
            walk(root, area, &mut out);
        }
        out
    }
    /// The window next to `view` in a direction: among those beyond its
    /// edge that overlap it, the nearest, then the one closest to its
    /// top or left.
    pub fn neighbor(&self, view: ViewId, direction: Direction) -> Option<ViewId> {
        let area = Area {
            x: 0,
            y: 0,
            width: 10_000,
            height: 10_000,
        };
        let layout = self.layout(area);
        let (_, from) = *layout.iter().find(|(id, _)| *id == view)?;
        let overlap = |a: (u16, u16), b: (u16, u16)| a.0 < b.1 && b.0 < a.1;
        layout
            .iter()
            .filter(|(id, to)| {
                *id != view
                    && match direction {
                        Direction::Left => {
                            to.right() <= from.x
                                && overlap((to.y, to.bottom()), (from.y, from.bottom()))
                        }
                        Direction::Right => {
                            to.x >= from.right()
                                && overlap((to.y, to.bottom()), (from.y, from.bottom()))
                        }
                        Direction::Up => {
                            to.bottom() <= from.y
                                && overlap((to.x, to.right()), (from.x, from.right()))
                        }
                        Direction::Down => {
                            to.y >= from.bottom()
                                && overlap((to.x, to.right()), (from.x, from.right()))
                        }
                    }
            })
            .min_by_key(|(_, to)| {
                let distance = match direction {
                    Direction::Left => from.x - to.right(),
                    Direction::Right => to.x - from.right(),
                    Direction::Up => from.y - to.bottom(),
                    Direction::Down => to.y - from.bottom(),
                };
                let along = match direction {
                    Direction::Left | Direction::Right => to.y.abs_diff(from.y),
                    Direction::Up | Direction::Down => to.x.abs_diff(from.x),
                };
                (distance, along)
            })
            .map(|(id, _)| *id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn v(n: u64) -> ViewId {
        ViewId(n)
    }
    #[test]
    fn splits_share_space_and_close_back_to_one_window() {
        let mut windows = Windows::default();
        windows.replace(None, v(1));
        windows.split(v(1), v(2), Axis::Columns);
        windows.split(v(2), v(3), Axis::Columns);
        windows.split(v(3), v(4), Axis::Rows);
        assert_eq!(windows.views(), [v(1), v(2), v(3), v(4)]);
        let area = Area {
            x: 0,
            y: 0,
            width: 32,
            height: 10,
        };
        let layout = windows.layout(area);
        // 30 columns after two separators, ten each.
        assert_eq!(layout[0].1.width, 10);
        assert_eq!(layout[1].1.x, 11);
        assert_eq!(
            layout[2].1,
            Area {
                x: 22,
                y: 0,
                width: 10,
                height: 5
            }
        );
        assert_eq!(
            layout[3].1,
            Area {
                x: 22,
                y: 5,
                width: 10,
                height: 5
            }
        );
        assert_eq!(windows.neighbor(v(1), Direction::Right), Some(v(2)));
        assert_eq!(windows.neighbor(v(2), Direction::Right), Some(v(3)));
        assert_eq!(windows.neighbor(v(4), Direction::Up), Some(v(3)));
        assert_eq!(windows.neighbor(v(4), Direction::Left), Some(v(2)));
        assert_eq!(windows.neighbor(v(1), Direction::Left), None);
        windows.remove(v(3));
        assert_eq!(
            windows.root(),
            Some(&Node::Split {
                axis: Axis::Columns,
                children: vec![Node::Window(v(1)), Node::Window(v(2)), Node::Window(v(4))],
            })
        );
        windows.replace(Some(v(4)), v(5));
        windows.only(v(5));
        assert_eq!(windows.views(), [v(5)]);
        windows.remove(v(5));
        assert!(windows.is_empty());
    }
}
