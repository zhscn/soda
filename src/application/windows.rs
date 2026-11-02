//! The window tree: how visible views split the editing area. Each window
//! shows one view; views outside the tree stay open but hidden. Splits
//! divide their area equally among children, and a split never holds a
//! single child. Beside the tree, a bottom and a right side window, as in
//! Emacs, show result lists at a fixed size and are never split.
use super::ViewId;

/// How a split arranges its children.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Axis {
    /// Stacked top to bottom.
    Rows,
    /// Side by side.
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
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Side {
    Bottom,
    Right,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Windows {
    root: Option<Node>,
    /// Side windows with their height or width.
    bottom: Option<(ViewId, u16)>,
    right: Option<(ViewId, u16)>,
}
impl Windows {
    /// The split windows, without the side windows.
    pub fn root(&self) -> Option<&Node> {
        self.root.as_ref()
    }
    pub fn side(&self, view: ViewId) -> Option<Side> {
        if self.bottom.is_some_and(|(id, _)| id == view) {
            Some(Side::Bottom)
        } else if self.right.is_some_and(|(id, _)| id == view) {
            Some(Side::Right)
        } else {
            None
        }
    }
    pub fn side_view(&self, side: Side) -> Option<ViewId> {
        match side {
            Side::Bottom => self.bottom,
            Side::Right => self.right,
        }
        .map(|(id, _)| id)
    }
    /// Shows `view` in a side window of `size` rows or columns.
    pub fn set_side(&mut self, side: Side, view: ViewId, size: u16) {
        let slot = match side {
            Side::Bottom => &mut self.bottom,
            Side::Right => &mut self.right,
        };
        *slot = Some((view, size.max(1)));
    }
    /// Shows `view` in the open side window, the bottom one if both are.
    pub fn reuse_side(&mut self, view: ViewId) -> bool {
        match self.bottom.as_mut().or(self.right.as_mut()) {
            Some(slot) => {
                slot.0 = view;
                true
            }
            None => false,
        }
    }
    /// Shows `view` as the only split window when there is none.
    pub fn place(&mut self, view: ViewId) {
        if self.root.is_none() {
            self.root = Some(Node::Window(view));
        }
    }
    /// Visible views: split windows top to bottom and left to right, then
    /// the right and bottom side windows.
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
        out.extend(self.right.map(|(id, _)| id));
        out.extend(self.bottom.map(|(id, _)| id));
        out
    }
    pub fn contains(&self, view: ViewId) -> bool {
        self.views().contains(&view)
    }
    pub fn len(&self) -> usize {
        self.views().len()
    }
    pub fn is_empty(&self) -> bool {
        self.root.is_none() && self.bottom.is_none() && self.right.is_none()
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
    /// Shows `new` in the window of `old`, or as the only window when there
    /// is none.
    pub fn replace(&mut self, old: Option<ViewId>, new: ViewId) {
        for (id, _) in [&mut self.bottom, &mut self.right].into_iter().flatten() {
            if Some(*id) == old {
                *id = new;
                return;
            }
        }
        if self.is_empty() {
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
        for slot in [&mut self.bottom, &mut self.right] {
            if slot.is_some_and(|(id, _)| id == view) {
                *slot = None;
                return;
            }
        }
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
        self.bottom = None;
        self.right = None;
    }
    /// Each window's area within `area`. Side-by-side windows leave one
    /// column between them for a separator. The bottom side window spans
    /// the width; the right one, the height above it. Each keeps at least
    /// half the room for the split windows.
    pub fn layout(&self, area: Area) -> Vec<(ViewId, Area)> {
        let mut main = area;
        let mut sides = vec![];
        if let Some((view, size)) = self.bottom {
            let height = if self.root.is_none() && self.right.is_none() {
                area.height
            } else {
                size.min(area.height / 2)
            };
            main.height -= height;
            sides.push((
                view,
                Area {
                    y: main.bottom(),
                    height,
                    ..area
                },
            ));
        }
        if let Some((view, size)) = self.right {
            let width = if self.root.is_none() {
                main.width
            } else {
                size.min(main.width / 2)
            };
            let gap = u16::from(self.root.is_some() && width > 0);
            main.width -= width;
            sides.insert(
                0,
                (
                    view,
                    Area {
                        x: main.right(),
                        width,
                        ..main
                    },
                ),
            );
            main.width = main.width.saturating_sub(gap);
        }
        let mut out = self.layout_tree(main);
        out.extend(sides);
        out
    }
    fn layout_tree(&self, area: Area) -> Vec<(ViewId, Area)> {
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
    #[test]
    fn side_windows_frame_the_splits_and_keep_half_the_room() {
        let mut windows = Windows::default();
        windows.replace(None, v(1));
        windows.set_side(Side::Bottom, v(2), 4);
        windows.set_side(Side::Right, v(3), 50);
        let area = Area {
            x: 0,
            y: 0,
            width: 40,
            height: 20,
        };
        let layout = windows.layout(area);
        assert_eq!(windows.views(), [v(1), v(3), v(2)]);
        // The right side takes at most half of the 40 columns, then one
        // column separates it from the split windows.
        assert_eq!(
            layout[0].1,
            Area {
                x: 0,
                y: 0,
                width: 19,
                height: 16
            }
        );
        assert_eq!(
            layout[1].1,
            Area {
                x: 20,
                y: 0,
                width: 20,
                height: 16
            }
        );
        assert_eq!(
            layout[2].1,
            Area {
                x: 0,
                y: 16,
                width: 40,
                height: 4
            }
        );
        assert_eq!(windows.neighbor(v(1), Direction::Down), Some(v(2)));
        assert_eq!(windows.neighbor(v(2), Direction::Up), Some(v(1)));
        windows.replace(Some(v(2)), v(4));
        assert_eq!(windows.side(v(4)), Some(Side::Bottom));
        windows.remove(v(1));
        windows.remove(v(3));
        assert_eq!(windows.layout(area), [(v(4), area)]);
    }
}
