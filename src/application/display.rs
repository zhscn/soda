//! Where a document is shown when it is not on screen yet, after Emacs's
//! `display-buffer-alist` but declarative: one placement per document kind.
//! A file is of kind `file`; a scratch document, such as `*grep*`, of its
//! name without the stars.
use super::{
    Application, Axis, ViewId,
    windows::{Area, Side},
};
use crate::editor::DocumentId;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Placement {
    /// The active window, unless that is a side window of another kind.
    Same,
    /// The most recent other split window, or a new split of the active one.
    Other,
    /// A side window of so many rows or columns.
    Side(Side, u16),
    /// The side window already open, or one chosen by the shape of the
    /// largest split window; see `Application::auto_side`.
    Auto,
}
impl Placement {
    /// Parses `same`, `other`, `auto`, `bottom [ROWS]` or `right [COLUMNS]`.
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut words = text.split_whitespace();
        let placement = words.next().unwrap_or("");
        let size = words
            .next()
            .map(|size| {
                size.parse::<u16>()
                    .ok()
                    .filter(|size| *size > 0)
                    .ok_or_else(|| format!("invalid size {size}"))
            })
            .transpose()?;
        let side = |side, default| Ok(Self::Side(side, size.unwrap_or(default)));
        match placement {
            "same" => Ok(Self::Same),
            "other" => Ok(Self::Other),
            "auto" => Ok(Self::Auto),
            "bottom" => side(Side::Bottom, 12),
            "right" => side(Side::Right, 60),
            _ => Err(format!(
                "unknown placement {placement:?}: use same, other, auto, bottom or right"
            )),
        }
    }
}
const RESULTS: Placement = Placement::Auto;
/// As `split-width-threshold` in Emacs: narrower windows are not halved.
const SPLIT_WIDTH: u16 = 150;
pub(super) struct Rules(BTreeMap<String, Placement>);
impl Default for Rules {
    fn default() -> Self {
        Self(BTreeMap::from([
            ("grep".to_owned(), RESULTS),
            ("run".to_owned(), RESULTS),
            ("messages".to_owned(), RESULTS),
        ]))
    }
}
impl Rules {
    pub fn set(&mut self, kind: String, placement: Placement) {
        self.0.insert(kind, placement);
    }
    /// A list of results keeps the rule it was given, or goes to the bottom.
    pub fn results(&mut self, kind: String) {
        self.0.entry(kind).or_insert(RESULTS);
    }
    fn get(&self, kind: &str) -> Placement {
        self.0.get(kind).copied().unwrap_or(Placement::Same)
    }
}

impl Application {
    /// The size of the editing area, which `auto` placement reads.
    pub fn set_editing_area(&mut self, width: u16, height: u16) {
        self.area = Area {
            x: 0,
            y: 0,
            width,
            height,
        };
    }
    /// Beside the largest split window when halving it leaves two usable
    /// windows and it is wider than it is tall, a cell being about twice as
    /// tall as wide (Emacs's `split-window-sensibly`); else below everything.
    fn auto_side(&self) -> Placement {
        let largest = self
            .windows
            .layout(self.area)
            .into_iter()
            .filter(|(view, _)| self.windows.side(*view).is_none())
            .map(|(_, area)| area)
            .max_by_key(|area| u32::from(area.width) * u32::from(area.height));
        match largest {
            Some(area) if area.width >= SPLIT_WIDTH && area.width / 2 > area.height => {
                // The layout holds a side window to half of the width.
                Placement::Side(Side::Right, u16::MAX)
            }
            _ => Placement::Side(Side::Bottom, 12),
        }
    }
    /// `file`, or a scratch document's name without its stars.
    pub fn document_kind(&self, document: DocumentId) -> &str {
        self.workspace
            .file(document)
            .and_then(|file| file.scratch())
            .map_or("file", |name| name.trim_matches('*'))
    }
    fn view_kind(&self, view: ViewId) -> &str {
        self.views
            .get(&view)
            .map_or("file", |view| self.document_kind(view.document_id))
    }
    /// Whether views of this kind go to a side window.
    pub(super) fn sided(&self, view: ViewId) -> bool {
        matches!(
            self.rules.get(self.view_kind(view)),
            Placement::Side(..) | Placement::Auto
        )
    }
    /// Puts a view that is not on screen into a window.
    pub(super) fn display(&mut self, view: ViewId) {
        let mut placement = self.rules.get(self.view_kind(view));
        if placement == Placement::Auto {
            if self.windows.reuse_side(view) {
                return;
            }
            placement = self.auto_side();
        }
        let active = self.active.filter(|id| self.windows.contains(*id));
        if let Placement::Side(side, size) = placement {
            self.windows.set_side(side, view, size);
            return;
        }
        let in_side = active.is_some_and(|id| self.windows.side(id).is_some());
        if placement == Placement::Same
            && let Some(active) = active.filter(|_| !in_side)
        {
            self.windows.replace(Some(active), view);
            return;
        }
        let other = self.recent.iter().rev().copied().find(|id| {
            Some(*id) != active && self.windows.contains(*id) && self.windows.side(*id).is_none()
        });
        match (other, active.filter(|_| !in_side)) {
            (Some(other), _) => self.windows.replace(Some(other), view),
            (None, Some(active)) => self.windows.split(active, view, Axis::Rows),
            (None, None) => self.windows.place(view),
        }
    }
}
