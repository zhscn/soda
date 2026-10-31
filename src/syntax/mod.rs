//! Syntax highlighting. C++ uses the editor's own lexer; other languages use
//! bundled TextMate grammars. Results are byte ranges with a fixed set of
//! categories, which themes color without knowing any grammar.
mod bundled;
mod cpp;
mod results;
mod scope;
mod textmate;

use crate::{
    application::Application,
    editor::{DocumentId, Language},
};
use std::{collections::HashMap, ops::Range, path::PathBuf};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Category {
    Comment,
    String,
    Escape,
    Number,
    Constant,
    Keyword,
    Operator,
    Type,
    Function,
    Parameter,
    Namespace,
    Macro,
    Tag,
    Attribute,
    Heading,
    Emphasis,
    Strong,
    Link,
    Inserted,
    Deleted,
    Changed,
    Invalid,
    /// What a search found, in its results.
    Match,
}

/// Category runs of one line, as byte ranges relative to the line start.
pub type Runs = Vec<(Range<usize>, Category)>;

/// The marker that starts a line comment in a file of this path. Reads the
/// bundled manifests, so it is for commands, not for drawing.
pub fn line_comment(path: &std::path::Path) -> Option<String> {
    textmate::Registry::bundled().detect(path)?.line_comment()
}

enum Backend {
    Plain,
    Cpp(cpp::Lexed),
    TextMate(textmate::Lines),
    /// Whether rows under file names count; see `results_kind`.
    Results(bool),
}
struct Entry {
    path: Option<PathBuf>,
    cpp: bool,
    results: Option<bool>,
    name: String,
    backend: Backend,
}

/// Highlighting state of every open document, owned by a frontend and
/// updated from the current snapshot before drawing.
#[derive(Default)]
pub struct Highlighter {
    registry: Option<textmate::Registry>,
    documents: HashMap<DocumentId, Entry>,
    /// Scanning time per request; the rest continues on the next one.
    budget: Option<std::time::Duration>,
    pending: bool,
}
impl Highlighter {
    /// A highlighter that scans for at most `budget` per request, so a jump
    /// deep into a large file stays responsive while results catch up.
    pub fn with_budget(budget: std::time::Duration) -> Self {
        Self {
            budget: Some(budget),
            ..Self::default()
        }
    }
    /// Whether the last requests left lines unscanned; draw again soon.
    pub fn take_pending(&mut self) -> bool {
        std::mem::take(&mut self.pending)
    }
    fn registry(&mut self) -> &mut textmate::Registry {
        self.registry
            .get_or_insert_with(textmate::Registry::bundled)
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
        let snapshot = editor.model().document().snapshot().clone();
        let path = app
            .workspace()
            .file(document)
            .and_then(|file| file.path())
            .map(ToOwned::to_owned);
        let cpp = matches!(editor.model().language(), Language::Cpp(_));
        let results = app
            .workspace()
            .file(document)
            .and_then(|file| file.scratch())
            .and_then(crate::interaction::grep::results_kind);
        let stale = self
            .documents
            .get(&document)
            .is_none_or(|entry| entry.path != path || entry.cpp != cpp || entry.results != results);
        if stale {
            let (name, backend) = if let Some(grouped) = results {
                ("text".to_owned(), Backend::Results(grouped))
            } else if cpp {
                (
                    "C++".to_owned(),
                    Backend::Cpp(cpp::Lexed::new(snapshot.shared_text())),
                )
            } else {
                self.detect(path.as_deref())
            };
            self.documents.insert(
                document,
                Entry {
                    path,
                    cpp,
                    results,
                    name,
                    backend,
                },
            );
        }
        let registry = self.registry.as_mut();
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
            Backend::TextMate(cache) => {
                cache.update(&snapshot);
                let runs = cache.highlights_within(
                    registry.unwrap(),
                    &snapshot,
                    lines.clone(),
                    self.budget,
                );
                self.pending |= !cache.complete(&lines, &snapshot);
                runs
            }
        }
    }
    fn detect(&mut self, path: Option<&std::path::Path>) -> (String, Backend) {
        let plain = ("text".to_owned(), Backend::Plain);
        let Some(path) = path else {
            return plain;
        };
        let registry = self.registry();
        let Some((name, scope)) = registry
            .detect(path)
            .map(|language| (language.name.clone(), language.scope.clone()))
        else {
            return plain;
        };
        let Some(grammar) = registry.grammar(&scope) else {
            return plain;
        };
        (
            name,
            Backend::TextMate(textmate::Lines::new(registry, grammar)),
        )
    }
    /// The language shown for a document once it has been highlighted.
    pub fn language(&self, document: DocumentId) -> Option<&str> {
        self.documents
            .get(&document)
            .map(|entry| entry.name.as_str())
    }
    /// Forgets documents that are no longer open.
    pub fn retain(&mut self, app: &Application) {
        self.documents
            .retain(|id, _| app.workspace().editor(*id).is_some());
    }
}

#[cfg(test)]
mod tests;
