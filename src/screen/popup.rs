//! Fits a panel beside a caret in the frontend's units.
#[derive(Clone, Copy)]
pub(crate) struct Bounds {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

pub(crate) struct Panel {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub rows: usize,
}

pub(crate) struct Request {
    pub area: Bounds,
    pub caret: Bounds,
    pub left: f32,
    pub width: f32,
    pub rows: usize,
    pub row_height: f32,
    pub padding: f32,
    pub gap: f32,
    pub prefer_below: bool,
}

pub(crate) fn place(request: Request) -> Option<Panel> {
    let Request {
        area,
        caret,
        left,
        width,
        rows,
        row_height,
        padding,
        gap,
        prefer_below,
    } = request;
    let above = caret.top - area.top - gap;
    let below = area.bottom - caret.bottom - gap;
    let wanted = rows as f32 * row_height + padding;
    let below_caret = below >= above || (prefer_below && below >= wanted);
    let room = if below_caret { below } else { above };
    let rows = (((room - padding) / row_height).max(0.0).floor() as usize).min(rows);
    let width = width.min(area.right - area.left);
    if rows == 0 || width <= 0.0 {
        return None;
    }
    let height = rows as f32 * row_height + padding;
    let y = if below_caret {
        caret.bottom + gap
    } else {
        caret.top - gap - height
    };
    Some(Panel {
        x: left.clamp(area.left, area.right - width),
        y,
        width,
        height,
        rows,
    })
}

/// The side with room for a companion panel, aligned to its anchor.
pub(crate) struct Beside {
    edge: f32,
    left: bool,
    pub width: f32,
}

impl Beside {
    pub(crate) fn new(area: Bounds, anchor: Bounds, gap: f32) -> Self {
        let left = anchor.left - area.left - gap;
        let right = area.right - anchor.right - gap;
        if right >= left {
            Self {
                edge: anchor.right + gap,
                left: false,
                width: right,
            }
        } else {
            Self {
                edge: anchor.left - gap,
                left: true,
                width: left,
            }
        }
    }

    pub(crate) fn x(&self, width: f32) -> f32 {
        if self.left {
            self.edge - width
        } else {
            self.edge
        }
    }
}

pub(crate) fn hint_grid(entries: usize, available_rows: usize) -> (usize, usize) {
    let columns = entries.div_ceil(available_rows.clamp(1, 12));
    if columns == 0 {
        return (0, 0);
    }
    (columns, entries.div_ceil(columns))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panel_stays_inside_the_area_with_room_for_its_gap() {
        let area = Bounds {
            left: 3.0,
            top: 2.0,
            right: 45.0,
            bottom: 32.0,
        };
        let caret = Bounds {
            left: 44.0,
            top: 25.0,
            right: 45.0,
            bottom: 27.0,
        };
        let panel = place(Request {
            area,
            caret,
            left: caret.left,
            width: 20.0,
            rows: 10,
            row_height: 3.0,
            padding: 4.0,
            gap: 1.0,
            prefer_below: true,
        })
        .unwrap();
        assert_eq!((panel.x, panel.y, panel.rows), (25.0, 2.0, 6));
        assert_eq!(panel.y + panel.height + 1.0, caret.top);
    }

    #[test]
    fn a_companion_panel_uses_the_side_with_more_room() {
        let area = Bounds {
            left: 0.0,
            top: 0.0,
            right: 80.0,
            bottom: 50.0,
        };
        let list = Bounds {
            left: 50.0,
            top: 4.0,
            right: 70.0,
            bottom: 40.0,
        };
        let side = Beside::new(area, list, 6.0);
        assert_eq!(side.width, 44.0);
        assert_eq!(side.x(24.0), 20.0);
    }
}
