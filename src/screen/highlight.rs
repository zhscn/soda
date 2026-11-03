//! Highlighting of the documents on screen: each frame asks for the lines
//! it shows, within a time budget.
use super::results;
use crate::{
    application::Application,
    editor::DocumentId,
    language::Analyzer,
    syntax::{Runs, cpp},
};
use std::{collections::HashMap, ops::Range, time::Duration};

enum Backend {
    Plain,
    Cpp(cpp::Lexed),
    /// The document's own tokens, which its language session holds.
    TextMate,
    /// Whether rows under file names count; see `results_kind`.
    Results(bool),
}
struct Entry {
    language: String,
    results: Option<bool>,
    backend: Backend,
}

/// Highlighting state of every open document, owned by a frontend and
/// updated from the current snapshot before drawing.
#[derive(Default)]
pub struct Highlighter {
    documents: HashMap<DocumentId, Entry>,
    /// Scanning time per request; the rest continues on the next one.
    budget: Option<Duration>,
    pending: bool,
}
impl Highlighter {
    /// A highlighter that scans for at most `budget` per request, so a jump
    /// deep into a large file stays responsive while results catch up.
    pub fn with_budget(budget: Duration) -> Self {
        Self {
            budget: Some(budget),
            ..Self::default()
        }
    }
    /// Whether the last requests left lines unscanned; draw again soon.
    pub fn take_pending(&mut self) -> bool {
        std::mem::take(&mut self.pending)
    }
    /// Category runs of `lines` in a document; empty for plain text.
    pub fn lines(
        &mut self,
        app: &Application,
        document: DocumentId,
        lines: Range<usize>,
    ) -> Vec<Runs> {
        let Some(editor) = app.workspace().editor(document) else {
            return vec![];
        };
        let model = editor.model().document();
        let snapshot = model.snapshot();
        let language = model.language();
        let profile = language.profile();
        let results = app
            .workspace()
            .file(document)
            .and_then(|file| file.scratch())
            .and_then(crate::interaction::grep::results_kind);
        let stale = self
            .documents
            .get(&document)
            .is_none_or(|entry| entry.language != profile.id || entry.results != results);
        if stale {
            let backend = match (results, &profile.analyzer) {
                (Some(grouped), _) => Backend::Results(grouped),
                (None, Analyzer::Cpp) => Backend::Cpp(cpp::Lexed::new(snapshot.shared_text())),
                (None, Analyzer::TextMate { .. }) => Backend::TextMate,
                (None, Analyzer::Plain) => Backend::Plain,
            };
            self.documents.insert(
                document,
                Entry {
                    language: profile.id.clone(),
                    results,
                    backend,
                },
            );
        }
        let entry = self.documents.get_mut(&document).unwrap();
        let end = lines.end.min(snapshot.line_count());
        match &mut entry.backend {
            Backend::Plain => vec![],
            Backend::Results(grouped) => (lines.start.min(end)..end)
                .map(|line| {
                    let text = snapshot.line(line).unwrap_or_default();
                    results::runs(&text, *grouped, app.grep_pattern(document))
                })
                .collect(),
            Backend::Cpp(lexed) => {
                lexed.update(&snapshot.shared_text());
                (lines.start.min(end)..end)
                    .map(|line| lexed.line(snapshot.line_content_range(line).unwrap()))
                    .collect()
            }
            Backend::TextMate => {
                let Some(tokens) = model.tokens() else {
                    return vec![];
                };
                let (runs, complete) = tokens.lines(snapshot, lines, self.budget);
                self.pending |= !complete;
                runs
            }
        }
    }
    /// Forgets documents that are no longer open.
    pub fn retain(&mut self, app: &Application) {
        self.documents
            .retain(|id, _| app.workspace().editor(*id).is_some());
    }
}
