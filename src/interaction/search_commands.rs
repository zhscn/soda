//! Starts a search, replacement or label session, or visits a match.
use super::commands::selection_of;
use super::{Command, Layer, Layers, Message, Response, SearchSession, commands::active};
use crate::{
    application::{Application, Event},
    core::EditError,
    editor::Command as EditCommand,
};
use std::time::Duration;

#[derive(Clone, Debug)]
pub enum SearchCommand {
    /// Moves to one of the places two typed characters occur on screen.
    JumpTo,
    /// Searches the screen as the query is typed and moves to a match by
    /// its label, as flash.nvim's jump.
    Flash,
    /// Labels the groups around the caret and selects one, as flash.nvim's
    /// Treesitter mode.
    FlashStructure,
    /// The groups around the selection, innermost first, as the runtime
    /// found them for `FlashStructure`.
    LabelGroups {
        groups: Vec<crate::language::Group>,
        selection: crate::core::Selection,
    },
    Search,
    SearchBackward,
    /// Searches for the symbol at the caret, from its start, as Emacs's
    /// `isearch-forward-symbol-at-point`.
    SearchSymbol,
    /// Searches for a symbol, or for text, and selects its next place.
    Visit(String),
    Replace,
    /// Asks a query and a replacement, then reviews their matches in each
    /// file of the project, as Emacs's `project-query-replace-regexp`.
    ProjectReplace,
}

impl Layers {
    pub(super) fn execute_search(
        &mut self,
        command: SearchCommand,
        mut response: Response,
        app: &Application,
        time: Duration,
    ) -> Result<Response, EditError> {
        match command {
            SearchCommand::SearchSymbol => {
                let Some(view) = active(app) else {
                    return Ok(response);
                };
                let editor = app.workspace().editor(view.document_id).unwrap();
                let session = editor.model().session(view.session_id).unwrap();
                let snapshot = editor.model().document().snapshot();
                let head = session.selection().head;
                let Some(range) = super::modal::text::thing_at(snapshot, head, true) else {
                    response.message = Message::Set("No symbol at point".into());
                    return Ok(response);
                };
                let word = snapshot.byte_slice(range.clone()).unwrap().to_string();
                let query = crate::editor::search::SearchQuery::symbol(word);
                // As in Emacs the search starts at the symbol's start, so its
                // first match is this one, and cancelling comes back there.
                let session = SearchSession::starting_at(app, view.id, range.start)?;
                let (session, seeded) = session.seeded(query, app, time)?;
                response = self.enter(Layer::Search(Box::new(session)), app, time)?;
                response.events.splice(0..0, seeded.events);
            }
            SearchCommand::Search
            | SearchCommand::SearchBackward
            | SearchCommand::Replace
            | SearchCommand::ProjectReplace => {
                if let Some(view) = app.active_view() {
                    let session = SearchSession::new(app, view)?;
                    let session = match command {
                        SearchCommand::SearchBackward => session.backward(),
                        SearchCommand::Replace => session.replacing(),
                        SearchCommand::ProjectReplace => session.across_project(),
                        _ => session,
                    };
                    response = self.enter(Layer::Search(Box::new(session)), app, time)?;
                }
            }
            SearchCommand::Visit(text) => {
                if let Some(view) = app.active_view()
                    && let Some(state) = app.view(view)
                {
                    let editor = app.workspace().editor(state.document_id).unwrap();
                    let snapshot = editor.model().document().snapshot();
                    let symbol = text.chars().all(super::completion::is_word)
                        && super::command_line::symbols(snapshot.text(), 0).contains(&text);
                    let query = if symbol {
                        crate::editor::search::SearchQuery::symbol(text.clone())
                    } else {
                        crate::editor::search::SearchQuery::new(regex::escape(&text))
                    };
                    self.modal.set_search(query.clone());
                    self.prompt_history
                        .history
                        .record(super::history::SEARCH, &text);
                    let head = editor
                        .model()
                        .session(state.session_id)
                        .unwrap()
                        .selection()
                        .head;
                    // From the caret, so the selection is not what is sought.
                    response.events.push(Event::Edit {
                        view,
                        command: EditCommand::SetSearchQuery(query),
                        time,
                    });
                    response.events.push(Event::Edit {
                        view,
                        command: EditCommand::SetSelection(crate::core::Selection::caret(head)),
                        time,
                    });
                    response.commands.push(Command::Named("search-next".into()));
                }
            }
            SearchCommand::JumpTo => {
                if let Some(view) = app.active_view() {
                    let rows = |id: crate::application::ViewId| {
                        let shown = self
                            .geometry
                            .window_rows
                            .iter()
                            .find(|(view, _)| *view == id);
                        shown.map_or(self.geometry.page_rows, |(_, rows)| *rows)
                    };
                    let others = app.windows().views();
                    let others = others.into_iter().filter(|id| *id != view);
                    let windows = std::iter::once(view)
                        .chain(others)
                        .map(|id| (id, rows(id)))
                        .collect();
                    let session = super::labels::LabelSession::jump(view, windows);
                    response = self.enter(Layer::Labels(session), app, time)?;
                }
            }
            SearchCommand::Flash => {
                if let Some(view) = app.active_view() {
                    let rows = |id: crate::application::ViewId| {
                        let shown = self
                            .geometry
                            .window_rows
                            .iter()
                            .find(|(view, _)| *view == id);
                        shown.map_or(self.geometry.page_rows, |(_, rows)| *rows)
                    };
                    let others = app.windows().views();
                    let others = others.into_iter().filter(|id| *id != view);
                    let windows = std::iter::once(view)
                        .chain(others)
                        .map(|id| (id, rows(id)))
                        .collect();
                    let caret = selection_of(app, view).map_or(0, |selection| selection.head);
                    let session = super::labels::LabelSession::flash(view, caret, windows);
                    response = self.enter(Layer::Labels(session), app, time)?;
                }
            }
            SearchCommand::FlashStructure => {
                if let Some(selection) = app.active_view().and_then(|view| selection_of(app, view))
                {
                    response.commands.push(Command::Effect(Box::new(
                        super::modal::Effect::Groups(selection),
                    )));
                }
            }
            SearchCommand::LabelGroups { groups, selection } => {
                if let Some(view) = app.active_view() {
                    let (session, select) =
                        super::labels::LabelSession::structure(view, groups, selection, time);
                    response = self.enter(Layer::Labels(session), app, time)?;
                    response.events.extend(select.events);
                }
            }
        }
        Ok(response)
    }
}
