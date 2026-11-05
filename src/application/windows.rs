//! The window tree: how visible views split the editing area. Each window
//! shows one view; views outside the tree stay open but hidden. Splits
//! divide their area among children by weight, equal until a window is
//! resized, and a split never holds a single child. Beside the tree, a
//! bottom and a right side window, as in Emacs, show result lists at a
//! size of their own and are never split.
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
    /// `weights` has one entry per child. Resizing sets them to the cells
    /// each child had, so a later change of the area scales every child.
    Split {
        axis: Axis,
        children: Vec<Node>,
        weights: Vec<u32>,
    },
}
impl Node {
    /// The areas of a split's children within `area`. Side-by-side
    /// children leave a column between them.
    fn areas(&self, area: Area) -> Vec<Area> {
        let Node::Split {
            axis,
            children,
            weights,
        } = self
        else {
            return vec![];
        };
        let n = children.len() as u16;
        let (total, gap) = match axis {
            Axis::Columns => (area.width.saturating_sub(n - 1), 1),
            Axis::Rows => (area.height, 0),
        };
        let mut offset = 0;
        shares(total, weights)
            .into_iter()
            .map(|size| {
                let child = match axis {
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
                offset += size + gap;
                child
            })
            .collect()
    }
    fn split(axis: Axis, children: Vec<Node>) -> Self {
        let weights = vec![1; children.len()];
        Self::Split {
            axis,
            children,
            weights,
        }
    }
}
/// The fewest cells a resize leaves a window: a title and a line of text,
/// or a few columns.
const MIN_ROWS: u16 = 2;
const MIN_COLUMNS: u16 = 8;
fn minimum(axis: Axis) -> u16 {
    match axis {
        Axis::Rows => MIN_ROWS,
        Axis::Columns => MIN_COLUMNS,
    }
}
/// Splits `total` cells by weight. Remainders go to the largest fractions,
/// earlier children first, so equal weights give earlier children the
/// extra cell.
fn shares(total: u16, weights: &[u32]) -> Vec<u16> {
    let sum: u64 = weights.iter().map(|w| u64::from(*w)).sum::<u64>().max(1);
    let total = u64::from(total);
    let mut sizes: Vec<u64> = weights
        .iter()
        .map(|w| total * u64::from(*w) / sum)
        .collect();
    let mut order: Vec<usize> = (0..weights.len()).collect();
    order.sort_by_key(|&i| std::cmp::Reverse(total * u64::from(weights[i]) % sum));
    let left = total - sizes.iter().sum::<u64>();
    for &i in order.iter().take(left as usize) {
        sizes[i] += 1;
    }
    sizes.into_iter().map(|size| size as u16).collect()
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
    /// The sizes the side windows were opened at, which a reset restores.
    opened: [u16; 2],
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
        let (slot, opened) = match side {
            Side::Bottom => (&mut self.bottom, &mut self.opened[0]),
            Side::Right => (&mut self.right, &mut self.opened[1]),
        };
        *slot = Some((view, size.max(1)));
        *opened = size.max(1);
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
                    *node = Node::split(axis, vec![Node::Window(at), Node::Window(new)]);
                    true
                }
                Node::Window(_) => false,
                Node::Split {
                    axis: own,
                    children,
                    weights,
                } => {
                    // A split along the same axis gains a sibling instead
                    // of nesting, so repeated splits stay equal. Once
                    // resized, the new window takes half of the old one.
                    if *own == axis
                        && let Some(index) = children.iter().position(|c| *c == Node::Window(at))
                    {
                        let weight = if weights.iter().all(|w| *w == weights[0]) {
                            weights[index]
                        } else {
                            let half = weights[index] / 2;
                            weights[index] -= half;
                            half.max(1)
                        };
                        children.insert(index + 1, Node::Window(new));
                        weights.insert(index + 1, weight);
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
            let Node::Split {
                children, weights, ..
            } = node
            else {
                return false;
            };
            if let Some(index) = children.iter().position(|c| *c == Node::Window(view)) {
                children.remove(index);
                weights.remove(index);
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
        let (main, sides) = self.frame(area);
        let mut out = self.layout_tree(main);
        out.extend(sides);
        out
    }
    /// The area left to the split windows, and the side windows' areas.
    fn frame(&self, area: Area) -> (Area, Vec<(ViewId, Area)>) {
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
        (main, sides)
    }
    fn layout_tree(&self, area: Area) -> Vec<(ViewId, Area)> {
        fn walk(node: &Node, area: Area, out: &mut Vec<(ViewId, Area)>) {
            match node {
                Node::Window(view) => out.push((*view, area)),
                Node::Split { children, .. } => {
                    for (child, child_area) in children.iter().zip(node.areas(area)) {
                        walk(child, child_area, out);
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
    /// Grows the window of `view` by `delta` cells along `axis`, or shrinks
    /// it when negative, within `area`: the nearest split along that axis
    /// that holds it moves the edge, taking cells from the siblings nearest
    /// it, after it first; a side window changes its own size. False when
    /// nothing can move.
    pub fn resize(&mut self, view: ViewId, axis: Axis, delta: i32, area: Area) -> bool {
        match (self.side(view), axis) {
            (Some(Side::Bottom), Axis::Rows) | (Some(Side::Right), Axis::Columns) => {
                self.resize_side(axis, delta, area)
            }
            (Some(_), _) => false,
            (None, _) => self.grow(view, axis, delta, area, false) == Some(true),
        }
    }
    /// Moves the right or bottom edge of the window of `view` by `delta`
    /// cells, as a mouse drags it: only the windows beyond that edge give
    /// or take cells, or the side window there.
    pub fn move_edge(&mut self, view: ViewId, axis: Axis, delta: i32, area: Area) -> bool {
        if self.side(view).is_none()
            && let Some(moved) = self.grow(view, axis, delta, area, true)
        {
            return moved;
        }
        // Past the split windows' edge lies a side window, which the right
        // one's bottom edge also meets.
        match axis {
            Axis::Rows if self.bottom.is_some() && self.side(view) != Some(Side::Bottom) => {
                self.resize_side(axis, -delta, area)
            }
            Axis::Columns if self.right.is_some() && self.side(view).is_none() => {
                self.resize_side(axis, -delta, area)
            }
            _ => false,
        }
    }
    fn resize_side(&mut self, axis: Axis, delta: i32, area: Area) -> bool {
        let (slot, limit) = match axis {
            Axis::Rows => (&mut self.bottom, area.height / 2),
            Axis::Columns => (&mut self.right, area.width / 2),
        };
        let Some((_, size)) = slot.as_mut() else {
            return false;
        };
        // The layout caps the size at half the area, so grow from what
        // shows.
        let limit = i32::from(limit.max(1));
        let shown = i32::from(*size).min(limit);
        let new = (shown + delta).clamp(1, limit);
        *size = new as u16;
        new != shown
    }
    /// Resizes a split window: whether it changed, or none when no split
    /// along `axis` can take the move. With `edge`, only its right or
    /// bottom edge moves, so a split where it comes last leaves the move
    /// to an outer one.
    fn grow(
        &mut self,
        view: ViewId,
        axis: Axis,
        delta: i32,
        area: Area,
        edge: bool,
    ) -> Option<bool> {
        let (main, _) = self.frame(area);
        fn walk(
            node: &mut Node,
            view: ViewId,
            axis: Axis,
            delta: i32,
            area: Area,
            edge: bool,
        ) -> Option<bool> {
            let areas = node.areas(area);
            let Node::Split {
                axis: own,
                children,
                weights,
            } = node
            else {
                return (*node == Node::Window(view)).then_some(false);
            };
            let index = (0..children.len()).find_map(|i| {
                walk(&mut children[i], view, axis, delta, areas[i], edge).map(|moved| (i, moved))
            })?;
            match index {
                (_, true) => Some(true),
                (index, false) if *own == axis && !(edge && index + 1 == children.len()) => {
                    let mut sizes: Vec<i32> = areas
                        .iter()
                        .map(|a| {
                            i32::from(match axis {
                                Axis::Rows => a.height,
                                Axis::Columns => a.width,
                            })
                        })
                        .collect();
                    let min = i32::from(minimum(axis));
                    // Siblings after the window, nearest first, then
                    // those before it unless only the edge moves.
                    let before = if edge { 0..0 } else { 0..index };
                    let others: Vec<usize> = (index + 1..sizes.len()).chain(before.rev()).collect();
                    let moved = if delta > 0 {
                        let mut left = delta;
                        for &i in &others {
                            let take = left.min((sizes[i] - min).max(0));
                            sizes[i] -= take;
                            left -= take;
                        }
                        delta - left
                    } else {
                        let give = (-delta).min((sizes[index] - min).max(0));
                        sizes[others[0]] += give;
                        give
                    };
                    if moved == 0 {
                        // An outer split along the axis may still move
                        // this whole group; a dragged edge stays put.
                        return Some(edge);
                    }
                    sizes[index] += if delta > 0 { moved } else { -moved };
                    *weights = sizes.iter().map(|s| *s as u32).collect();
                    Some(true)
                }
                (_, false) => Some(false),
            }
        }
        let root = self.root.as_mut()?;
        let before = root.clone();
        walk(root, view, axis, delta, main, edge)
            .filter(|handled| *handled)
            .map(|_| *root != before)
    }
    /// Gives every split equal children and the side windows the sizes
    /// they were opened at.
    pub fn reset(&mut self) {
        fn walk(node: &mut Node) {
            if let Node::Split {
                children, weights, ..
            } = node
            {
                weights.iter_mut().for_each(|w| *w = 1);
                children.iter_mut().for_each(walk);
            }
        }
        if let Some(root) = &mut self.root {
            walk(root);
        }
        for (slot, opened) in [
            (&mut self.bottom, self.opened[0]),
            (&mut self.right, self.opened[1]),
        ] {
            if let Some((_, size)) = slot {
                *size = opened;
            }
        }
    }
    /// The tree and the side windows with each view as `index` names it,
    /// for `restart`.
    pub(super) fn save(&self, index: &dyn Fn(ViewId) -> Option<usize>) -> serde_json::Value {
        use serde_json::{Value, json};
        fn node(at: &Node, index: &dyn Fn(ViewId) -> Option<usize>) -> Value {
            match at {
                Node::Window(view) => json!(index(*view)),
                Node::Split {
                    axis,
                    children,
                    weights,
                } => json!({
                    "axis": if *axis == Axis::Rows { "rows" } else { "columns" },
                    "children": children.iter().map(|c| node(c, index)).collect::<Vec<_>>(),
                    "weights": weights,
                }),
            }
        }
        let side = |slot: Option<(ViewId, u16)>| {
            slot.and_then(|(view, size)| Some(json!([index(view)?, size])))
        };
        json!({
            "root": self.root.as_ref().map(|root| node(root, index)),
            "bottom": side(self.bottom),
            "right": side(self.right),
            "opened": self.opened,
        })
    }
    /// Windows as `save` wrote them, with each index as `view` gives it
    /// back. A window whose view is gone goes, and a split left with one
    /// child gives way to it.
    pub(super) fn load(value: &serde_json::Value, view: &dyn Fn(usize) -> Option<ViewId>) -> Self {
        use serde_json::Value;
        fn node(value: &Value, view: &dyn Fn(usize) -> Option<ViewId>) -> Option<Node> {
            if let Some(index) = value.as_u64() {
                return view(index as usize).map(Node::Window);
            }
            let axis = match value.get("axis")?.as_str()? {
                "rows" => Axis::Rows,
                _ => Axis::Columns,
            };
            let weights = value.get("weights")?.as_array()?;
            let (children, weights): (Vec<_>, Vec<_>) = value
                .get("children")?
                .as_array()?
                .iter()
                .zip(weights)
                .filter_map(|(child, weight)| {
                    Some((
                        node(child, view)?,
                        weight.as_u64().unwrap_or(1).max(1) as u32,
                    ))
                })
                .unzip();
            match children.len() {
                0 => None,
                1 => children.into_iter().next(),
                _ => Some(Node::Split {
                    axis,
                    children,
                    weights,
                }),
            }
        }
        let side = |key: &str| -> Option<(ViewId, u16)> {
            let pair = value.get(key)?.as_array()?;
            let id = view(pair.first()?.as_u64()? as usize)?;
            Some((id, pair.get(1)?.as_u64()?.clamp(1, u16::MAX as u64) as u16))
        };
        let opened = |at: usize| {
            value
                .get("opened")
                .and_then(|opened| opened.get(at))
                .and_then(Value::as_u64)
                .map_or(1, |size| size.clamp(1, u16::MAX as u64) as u16)
        };
        Self {
            root: value.get("root").and_then(|root| node(root, view)),
            bottom: side("bottom"),
            right: side("right"),
            opened: [opened(0), opened(1)],
        }
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
                weights: vec![1; 3],
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
    #[test]
    fn resizing_moves_the_nearest_edge_along_the_axis() {
        let mut windows = Windows::default();
        windows.replace(None, v(1));
        windows.split(v(1), v(2), Axis::Columns);
        windows.split(v(2), v(3), Axis::Rows);
        let area = Area {
            x: 0,
            y: 0,
            width: 41,
            height: 20,
        };
        let size = |windows: &Windows, view| {
            let (_, area) = windows
                .layout(area)
                .into_iter()
                .find(|(id, _)| *id == view)
                .unwrap();
            (area.width, area.height)
        };
        // The lower right window is taller at the cost of the one above,
        // and wider at the cost of the column to the left.
        assert!(windows.resize(v(3), Axis::Rows, 4, area));
        assert_eq!(size(&windows, v(2)), (20, 6));
        assert_eq!(size(&windows, v(3)), (20, 14));
        assert!(windows.resize(v(3), Axis::Columns, 5, area));
        assert_eq!(size(&windows, v(1)), (15, 20));
        assert_eq!(size(&windows, v(2)), (25, 6));
        // A window keeps a minimum, and a resize that moves nothing fails.
        assert!(windows.resize(v(2), Axis::Rows, -10, area));
        assert_eq!(size(&windows, v(2)), (25, MIN_ROWS));
        assert!(!windows.resize(v(2), Axis::Rows, -1, area));
        assert!(!windows.resize(v(1), Axis::Rows, 1, area));
        // Splitting a resized window halves it; the new separator comes
        // from everyone.
        windows.split(v(1), v(4), Axis::Columns);
        assert_eq!((size(&windows, v(1)).0, size(&windows, v(4)).0), (8, 7));
        windows.reset();
        assert_eq!(size(&windows, v(1)).0, 13);
        // A side window changes its own size, up to half the area.
        windows.set_side(Side::Bottom, v(5), 4);
        assert!(windows.resize(v(5), Axis::Rows, 3, area));
        assert_eq!(size(&windows, v(5)).1, 7);
        assert!(!windows.resize(v(5), Axis::Columns, 3, area));
        assert!(windows.resize(v(5), Axis::Rows, 30, area));
        assert_eq!(size(&windows, v(5)).1, 10);
        windows.reset();
        assert_eq!(size(&windows, v(5)).1, 4);
    }
    #[test]
    fn a_dragged_edge_moves_only_the_windows_beyond_it() {
        let mut windows = Windows::default();
        windows.replace(None, v(1));
        windows.split(v(1), v(2), Axis::Columns);
        windows.split(v(1), v(3), Axis::Columns);
        windows.split(v(2), v(4), Axis::Rows);
        windows.set_side(Side::Right, v(5), 10);
        let area = Area {
            x: 0,
            y: 0,
            width: 64,
            height: 20,
        };
        let width = |windows: &Windows, view| {
            let (_, area) = windows
                .layout(area)
                .into_iter()
                .find(|(id, _)| *id == view)
                .unwrap();
            area.width
        };
        assert_eq!(
            [1, 3, 2, 5].map(|n| width(&windows, v(n))),
            [17, 17, 17, 10]
        );
        // The middle window's right edge takes from the one after it only.
        assert!(windows.move_edge(v(3), Axis::Columns, 5, area));
        assert_eq!([1, 3, 2].map(|n| width(&windows, v(n))), [17, 22, 12]);
        // It stops where the window after it is smallest; the one before
        // it keeps its size.
        assert!(windows.move_edge(v(3), Axis::Columns, 20, area));
        assert_eq!([1, 2].map(|n| width(&windows, v(n))), [17, MIN_COLUMNS]);
        assert!(!windows.move_edge(v(3), Axis::Columns, 1, area));
        // Past the last split window lies the right side window.
        assert!(windows.move_edge(v(4), Axis::Columns, -4, area));
        assert_eq!(width(&windows, v(5)), 14);
        // The bottom edge of the last window in a column has nothing below.
        assert!(!windows.move_edge(v(4), Axis::Rows, 2, area));
    }
}
