//! Window chrome decisions shared by the cell and pixel renderers.
use crate::application::{Application, Area, ViewId};

#[derive(Clone, Copy)]
pub(crate) enum Header {
    Tabs,
    Rule,
}

pub(crate) struct Chrome {
    tabs: bool,
}

impl Chrome {
    pub fn new(app: &Application) -> Self {
        Self {
            tabs: app.options().bool(None, "tab-bar"),
        }
    }

    pub fn splash_tabs(&self, app: &Application, fits: bool) -> bool {
        self.tabs && fits && app.windows().is_empty()
    }

    pub fn windows(&self, app: &Application, area: Area) -> Vec<(ViewId, Area, Gutter)> {
        app.windows()
            .layout(area)
            .into_iter()
            .map(|(view, area)| (view, area, Gutter::new(app, view)))
            .collect()
    }

    /// Each frontend supplies the room needed by its tabs or separator.
    pub fn header(&self, tabs_fit: bool, rule_fits: bool) -> Option<Header> {
        if self.tabs {
            tabs_fit.then_some(Header::Tabs)
        } else {
            rule_fits.then_some(Header::Rule)
        }
    }
}

pub(crate) struct Gutter {
    digits: u16,
    numbers: bool,
    #[cfg(feature = "tui")]
    pub flagged: bool,
}

impl Gutter {
    fn new(app: &Application, view: ViewId) -> Self {
        let document = app.view(view).map(|view| view.document_id);
        let lines = document
            .and_then(|id| app.workspace().editor(id))
            .map_or(1, |editor| {
                editor.model().document().snapshot().text_lines()
            });
        Self {
            digits: (lines.max(1).ilog10() as u16 + 1).max(3),
            numbers: app.options().choice(document, "line-numbers") != "off",
            #[cfg(feature = "tui")]
            flagged: document.is_some_and(|id| !app.flags(id).is_empty()),
        }
    }

    /// A numbered gutter must leave at least sixteen text columns.
    pub fn numbered(&self, columns: u16, padding: u16) -> Option<u16> {
        let needed = self.digits + padding + 16;
        (self.numbers && columns >= needed).then_some(self.digits)
    }
}
