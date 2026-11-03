//! What a language is, apart from any document: its name, the files it
//! covers and the facts commands ask about it. A profile is fixed data; the
//! state of one document in a language lives in the editor's language
//! session. Every question of which language a file is in ends here.
use crate::syntax::bundled::PACKAGES;
use serde_json::Value;
use std::{
    path::Path,
    sync::{Arc, OnceLock},
};

/// What analyzes documents in a language.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Analyzer {
    Plain,
    Cpp,
    TextMate { scope: String },
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Profile {
    pub id: String,
    /// The name shown to the user.
    pub name: String,
    pub line_comment: Option<String>,
    /// Bracket pairs, each of them one or more characters on either side.
    pub brackets: Vec<(String, String)>,
    /// Quotes typed in pairs.
    pub quotes: Vec<char>,
    pub analyzer: Analyzer,
}
impl Profile {
    /// The brackets structure follows. `<` is left out: only a parser can
    /// tell it from a comparison.
    pub fn round_brackets(&self) -> Vec<(char, char)> {
        self.brackets
            .iter()
            .filter(|(open, close)| {
                matches!(
                    (open.as_str(), close.as_str()),
                    ("(", ")") | ("[", "]") | ("{", "}")
                )
            })
            .filter_map(|(open, close)| Some((open.chars().next()?, close.chars().next()?)))
            .collect()
    }
}
struct Entry {
    profile: Arc<Profile>,
    extensions: Vec<String>,
    filenames: Vec<String>,
}
/// Every language soda knows.
pub struct Catalog {
    plain: Profile,
    cpp: Profile,
    entries: Vec<Entry>,
}
/// The catalog, read from the bundled manifests on first use.
pub fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<Catalog> = OnceLock::new();
    CATALOG.get_or_init(Catalog::bundled)
}

fn round_brackets() -> Vec<(String, String)> {
    [("(", ")"), ("[", "]"), ("{", "}")]
        .map(|(open, close)| (open.to_owned(), close.to_owned()))
        .into()
}
const CPP_EXTENSIONS: &[&str] = &[
    ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".C", ".H", ".ipp", ".ixx", ".cppm",
];

fn strings(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}
fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}
/// JSON from the JSONC of language configurations: comments and trailing
/// commas go, strings stay as they are.
pub(crate) fn plain_json(source: &str) -> String {
    let mut out = String::with_capacity(source.len());
    let mut chars = source.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                out.push(c);
                while let Some(c) = chars.next() {
                    out.push(c);
                    match c {
                        '\\' => out.extend(chars.next()),
                        '"' => break,
                        _ => {}
                    }
                }
            }
            '/' if chars.peek() == Some(&'/') => {
                chars.by_ref().find(|c| *c == '\n');
            }
            '/' if chars.peek() == Some(&'*') => {
                chars.next();
                let mut last = ' ';
                for c in chars.by_ref() {
                    if last == '*' && c == '/' {
                        break;
                    }
                    last = c;
                }
            }
            '}' | ']' => {
                if out.trim_end().ends_with(',') {
                    out.truncate(out.trim_end().len() - 1);
                }
                out.push(c);
            }
            _ => out.push(c),
        }
    }
    out
}
/// The facts a language configuration holds.
struct Configuration {
    line_comment: Option<String>,
    brackets: Vec<(String, String)>,
    quotes: Vec<char>,
}
fn configuration(source: Option<&str>) -> Configuration {
    let value: Option<Value> = source.and_then(|s| serde_json::from_str(&plain_json(s)).ok());
    let value = value.unwrap_or(Value::Null);
    // Either the marker, or an object holding it with settings.
    let line_comment = value
        .get("comments")
        .and_then(|comments| comments.get("lineComment"))
        .and_then(|comment| comment.as_str().or_else(|| text(comment, "comment")))
        .map(str::to_owned);
    let pair = |item: &Value| match (item.get(0), item.get(1)) {
        (Some(open), Some(close)) => Some((open.as_str()?.to_owned(), close.as_str()?.to_owned())),
        _ => Some((
            text(item, "open")?.to_owned(),
            text(item, "close")?.to_owned(),
        )),
    };
    let pairs = |key: &str| -> Vec<(String, String)> {
        let items = value.get(key).and_then(Value::as_array);
        items.into_iter().flatten().filter_map(pair).collect()
    };
    let quotes = pairs("autoClosingPairs")
        .into_iter()
        .filter(|(open, close)| open == close && matches!(open.as_str(), "\"" | "'" | "`"))
        .filter_map(|(open, _)| open.chars().next())
        .collect();
    Configuration {
        line_comment,
        brackets: pairs("brackets"),
        quotes,
    }
}

impl Catalog {
    fn bundled() -> Self {
        let cpp = Profile {
            id: "cpp".into(),
            name: "C++".into(),
            line_comment: Some("//".into()),
            brackets: round_brackets(),
            quotes: vec!['"', '\''],
            analyzer: Analyzer::Cpp,
        };
        let mut entries = vec![Entry {
            profile: Arc::new(cpp.clone()),
            extensions: CPP_EXTENSIONS.iter().map(|e| (*e).to_owned()).collect(),
            filenames: vec![],
        }];
        for package in PACKAGES {
            let Ok(manifest) = serde_json::from_str::<Value>(package.manifest) else {
                continue;
            };
            let file = |path: &str| {
                let path = path.trim_start_matches("./");
                package
                    .files
                    .iter()
                    .find(|(p, _)| *p == path)
                    .map(|(_, text)| *text)
            };
            let grammars = manifest.get("grammars").and_then(Value::as_array);
            let languages = manifest.get("languages").and_then(Value::as_array);
            for language in languages.into_iter().flatten() {
                let Some(id) = text(language, "id") else {
                    continue;
                };
                let Some(scope) = grammars
                    .into_iter()
                    .flatten()
                    .find(|g| text(g, "language") == Some(id))
                    .and_then(|g| text(g, "scopeName"))
                else {
                    continue;
                };
                let configuration = configuration(text(language, "configuration").and_then(file));
                entries.push(Entry {
                    profile: Arc::new(Profile {
                        id: id.to_owned(),
                        name: strings(language, "aliases")
                            .into_iter()
                            .next()
                            .unwrap_or_else(|| id.to_owned()),
                        line_comment: configuration.line_comment,
                        brackets: configuration.brackets,
                        quotes: configuration.quotes,
                        analyzer: Analyzer::TextMate {
                            scope: scope.to_owned(),
                        },
                    }),
                    extensions: strings(language, "extensions"),
                    filenames: strings(language, "filenames"),
                });
            }
        }
        Self {
            plain: Profile {
                id: "text".into(),
                name: "text".into(),
                line_comment: None,
                brackets: round_brackets(),
                quotes: vec![],
                analyzer: Analyzer::Plain,
            },
            cpp,
            entries,
        }
    }
    pub fn plain(&self) -> &Profile {
        &self.plain
    }
    pub fn cpp(&self) -> &Profile {
        &self.cpp
    }
    /// A language by its id; `text` is plain text.
    pub fn by_id(&self, id: &str) -> Option<Arc<Profile>> {
        if id == self.plain.id {
            return Some(Arc::new(self.plain.clone()));
        }
        self.entries
            .iter()
            .find(|entry| entry.profile.id == id)
            .map(|entry| entry.profile.clone())
    }
    /// Every language id, plain text first.
    pub fn ids(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.plain.id.as_str())
            .chain(self.entries.iter().map(|entry| entry.profile.id.as_str()))
    }
    /// The language of a file: exact file names first, then the longest
    /// matching extension (extensions may contain dots, as in `.js.map`).
    pub fn detect(&self, path: &Path) -> Option<&Arc<Profile>> {
        let name = path.file_name()?.to_str()?;
        if let Some(entry) = self
            .entries
            .iter()
            .find(|entry| entry.filenames.iter().any(|f| f == name))
        {
            return Some(&entry.profile);
        }
        self.entries
            .iter()
            .flat_map(|entry| entry.extensions.iter().map(move |e| (entry, e)))
            .filter(|(_, extension)| {
                name.len() > extension.len() && name.ends_with(extension.as_str())
            })
            .max_by_key(|(_, extension)| extension.len())
            .map(|(entry, _)| &entry.profile)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detect(path: &str) -> Option<&'static Profile> {
        catalog().detect(Path::new(path)).map(|p| p.as_ref())
    }
    #[test]
    fn languages_are_detected_by_name_and_extension() {
        let id = |path: &str| detect(path).map(|p| p.id.as_str());
        assert_eq!(id("src/main.rs"), Some("rust"));
        assert_eq!(id("Makefile"), Some("makefile"));
        assert_eq!(id("a/b.tsx"), Some("typescriptreact"));
        assert_eq!(id("x.unknown"), None);
        for name in ["a.cpp", "a.h", "a.C", "a.ipp", "a.ixx", "a.cppm"] {
            assert_eq!(detect(name).unwrap().analyzer, Analyzer::Cpp, "{name}");
        }
    }
    #[test]
    fn profiles_hold_what_language_configurations_say() {
        let rust = detect("a.rs").unwrap();
        assert_eq!(rust.line_comment.as_deref(), Some("//"));
        assert!(rust.brackets.contains(&("(".to_owned(), ")".to_owned())));
        // A single quote also starts a lifetime, so Rust does not pair it.
        assert_eq!(rust.quotes, ['"']);
        assert_eq!(detect("a.py").unwrap().line_comment.as_deref(), Some("#"));
        assert_eq!(detect("a.lua").unwrap().line_comment.as_deref(), Some("--"));
        // Written as an object with settings.
        let make = detect("Makefile").unwrap();
        assert_eq!(make.line_comment.as_deref(), Some("#"));
        // Block comments only.
        assert_eq!(detect("a.md").unwrap().line_comment, None);
        assert_eq!(catalog().plain().line_comment, None);
    }
    #[test]
    fn every_language_configuration_parses() {
        for package in PACKAGES {
            for (path, source) in package.files {
                if path.ends_with("language-configuration.json") {
                    let parsed: Result<Value, _> = serde_json::from_str(&plain_json(source));
                    assert!(parsed.is_ok(), "{}: {parsed:?}", package.name);
                }
            }
        }
    }
    #[test]
    fn jsonc_loses_comments_and_trailing_commas_but_not_strings() {
        assert_eq!(
            plain_json("{\"a\": \"//x\", // y\n \"b\": [1,],}").replace(char::is_whitespace, ""),
            "{\"a\":\"//x\",\"b\":[1]}"
        );
    }
}
