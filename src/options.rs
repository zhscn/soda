//! Typed options with a global value and per-document overrides. The
//! editor's options are a fixed table, and extensions declare theirs at
//! run time; values are checked against their type when set, so readers
//! never see an invalid one.
use crate::editor::DocumentId;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
    Bool,
    Int { min: u32, max: u32 },
    Choice(&'static [&'static str]),
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Value {
    Bool(bool),
    Int(u32),
    Choice(&'static str),
}
impl std::fmt::Display for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Bool(value) => write!(f, "{value}"),
            Self::Int(value) => write!(f, "{value}"),
            Self::Choice(value) => f.write_str(value),
        }
    }
}
pub struct OptionInfo {
    pub name: &'static str,
    pub kind: Kind,
    pub default: Value,
    pub doc: &'static str,
}
impl OptionInfo {
    pub fn parse(&self, text: &str) -> Result<Value, String> {
        let text = text.trim();
        let name = self.name;
        match self.kind {
            Kind::Bool => match text {
                "true" | "yes" | "on" => Ok(Value::Bool(true)),
                "false" | "no" | "off" => Ok(Value::Bool(false)),
                _ => Err(format!("{name} takes true or false")),
            },
            Kind::Int { min, max } => text
                .parse::<u32>()
                .ok()
                .filter(|value| (min..=max).contains(value))
                .map(Value::Int)
                .ok_or_else(|| format!("{name} takes a number from {min} to {max}")),
            Kind::Choice(words) => words
                .iter()
                .find(|word| **word == text)
                .map(|word| Value::Choice(word))
                .ok_or_else(|| format!("{name} takes one of {}", words.join(", "))),
        }
    }
    /// What the option accepts, for help and completion.
    pub fn values(&self) -> String {
        match self.kind {
            Kind::Bool => "true or false".into(),
            Kind::Int { min, max } => format!("{min} to {max}"),
            Kind::Choice(words) => words.join(", "),
        }
    }
}

pub const OPTIONS: &[OptionInfo] = &[
    OptionInfo {
        name: "indent-width",
        kind: Kind::Int { min: 0, max: 16 },
        default: Value::Int(4),
        doc: "Columns per indentation level; C++ follows clang-format instead",
    },
    OptionInfo {
        name: "tab-width",
        kind: Kind::Int { min: 1, max: 16 },
        default: Value::Int(4),
        doc: "Columns between tab stops; C++ follows clang-format instead",
    },
    OptionInfo {
        name: "expand-tab",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Indent with spaces rather than tabs; C++ follows clang-format instead",
    },
    OptionInfo {
        name: "auto-pairs",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Type brackets, and the quotes a language lists, in pairs; Backspace removes an empty pair",
    },
    OptionInfo {
        name: "mark-keys",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Keys of the mark table act while the caret is on a marked symbol, as Emacs's symbol-overlay-map",
    },
    OptionInfo {
        name: "completion",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Show candidates while typing in Insert; <a-/> asks for them regardless",
    },
    OptionInfo {
        name: "completion-preview",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Show the rest of the selected candidate in gray at the caret",
    },
    OptionInfo {
        name: "completion-min-prefix",
        kind: Kind::Int { min: 1, max: 16 },
        default: Value::Int(2),
        doc: "Characters of a word to type before candidates show",
    },
    OptionInfo {
        name: "line-numbers",
        kind: Kind::Choice(&["absolute", "relative", "off"]),
        default: Value::Choice("absolute"),
        doc: "Line numbers in the gutter: absolute, relative to the caret line, or off",
    },
    OptionInfo {
        name: "tab-bar",
        kind: Kind::Choice(&["auto", "on", "off"]),
        default: Value::Choice("auto"),
        doc: "The row of document tabs: auto shows it with a single window",
    },
    OptionInfo {
        name: "window-title",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Show a title row on each window when there are several",
    },
    OptionInfo {
        name: "cpp-fallback-style",
        kind: Kind::Choice(&[
            "LLVM",
            "Google",
            "Chromium",
            "Mozilla",
            "WebKit",
            "GNU",
            "Microsoft",
        ]),
        default: Value::Choice("LLVM"),
        doc: "C++ style of files with no usable .clang-format, once opened after this",
    },
    OptionInfo {
        name: "inlay-hints",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Show a language server's hints between the characters of a line",
    },
    OptionInfo {
        name: "inline-notes",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Show the worst note of a line, such as a diagnostic, after its text",
    },
    OptionInfo {
        name: "wrap",
        kind: Kind::Bool,
        default: Value::Bool(false),
        doc: "Wrap long lines onto further rows, after a space where one fits",
    },
    OptionInfo {
        name: "show-whitespace",
        kind: Kind::Bool,
        default: Value::Bool(false),
        doc: "Mark tabs with » and trailing spaces with ·",
    },
    OptionInfo {
        name: "ruler",
        kind: Kind::Int { min: 0, max: 1000 },
        default: Value::Int(0),
        doc: "Shade the column past this many; 0 for none, %val{column-limit} for clang-format's",
    },
    OptionInfo {
        name: "scroll-lines",
        kind: Kind::Int { min: 1, max: 100 },
        default: Value::Int(3),
        doc: "Lines one mouse wheel step scrolls",
    },
    OptionInfo {
        name: "idle-time",
        kind: Kind::Int {
            min: 10,
            max: 60_000,
        },
        default: Value::Int(500),
        doc: "Milliseconds without a key before the idle hook runs",
    },
    OptionInfo {
        name: "theme",
        kind: Kind::Choice(&["auto", "dark", "light"]),
        default: Value::Choice("auto"),
        doc: "Colors: dark, light, or auto to follow the terminal's background",
    },
    OptionInfo {
        name: "font-size",
        kind: Kind::Int { min: 6, max: 72 },
        default: Value::Int(14),
        doc: "Size of the text in the graphical frontend, in points",
    },
    OptionInfo {
        name: "smooth-caret",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Glide the caret to where it moves in the graphical frontend",
    },
    OptionInfo {
        name: "mouse",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Take mouse input; turn off to use the terminal's own selection",
    },
    OptionInfo {
        name: "trim-trailing-whitespace",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "On save, trim trailing spaces and tabs from lines edited since the last save",
    },
    OptionInfo {
        name: "final-newline",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "On save, end a file that has text with a line break",
    },
    OptionInfo {
        name: "auto-reload",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Reload files changed on disk that have no unsaved edits",
    },
    OptionInfo {
        name: "clipboard",
        kind: Kind::Choice(&["system", "internal"]),
        default: Value::Choice("system"),
        doc: "Keep copies in step with the system clipboard, or inside the editor",
    },
];
/// Options extensions declared. They last as long as the process, as the
/// editor's own do, so their names and words are leaked once.
static DECLARED: std::sync::RwLock<Vec<&'static OptionInfo>> = std::sync::RwLock::new(vec![]);
pub fn info(name: &str) -> Option<&'static OptionInfo> {
    OPTIONS
        .iter()
        .find(|option| option.name == name)
        .or_else(|| {
            DECLARED
                .read()
                .unwrap()
                .iter()
                .find(|option| option.name == name)
                .copied()
        })
}
/// Every option, the editor's first.
pub fn all() -> Vec<&'static OptionInfo> {
    OPTIONS
        .iter()
        .chain(DECLARED.read().unwrap().iter().copied())
        .collect()
}
/// What an extension asks for when it declares an option.
pub enum Declared {
    Bool(bool),
    Int { default: u32, min: u32, max: u32 },
    Choice { default: String, words: Vec<String> },
}
/// Declares an option. Declaring one again the same way is no change, so
/// a module may be loaded twice; the editor's options cannot be declared.
pub fn declare(name: &str, declared: Declared, doc: &str) -> Result<&'static OptionInfo, String> {
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    {
        return Err(format!(
            "{name:?} is not an option name: use a-z, 0-9 and -"
        ));
    }
    if OPTIONS.iter().any(|option| option.name == name) {
        return Err(format!("{name} is an option of the editor"));
    }
    let leak = |text: &str| -> &'static str { Box::leak(text.to_owned().into_boxed_str()) };
    let (kind, default) = match &declared {
        Declared::Bool(default) => (Kind::Bool, Value::Bool(*default)),
        Declared::Int { default, min, max } => {
            if !(min..=max).contains(&default) {
                return Err(format!("{name}: {default} is not from {min} to {max}"));
            }
            (
                Kind::Int {
                    min: *min,
                    max: *max,
                },
                Value::Int(*default),
            )
        }
        Declared::Choice { default, words } => {
            if !words.contains(default) {
                return Err(format!("{name}: {default} is not one of its words"));
            }
            (Kind::Choice(&[]), Value::Choice(""))
        }
    };
    let mut declared_options = DECLARED.write().unwrap();
    if let Some(known) = declared_options.iter().find(|option| option.name == name) {
        let same = match (&declared, known.kind) {
            (Declared::Choice { default, words }, Kind::Choice(known_words)) => {
                known_words.iter().eq(words.iter())
                    && matches!(known.default, Value::Choice(d) if d == default)
            }
            _ => known.kind == kind && known.default == default,
        };
        return if same {
            Ok(known)
        } else {
            Err(format!("{name} is declared already, another way"))
        };
    }
    let (kind, default) = match declared {
        Declared::Choice { default, words } => {
            let words: &'static [&'static str] = Box::leak(
                words
                    .iter()
                    .map(|w| leak(w))
                    .collect::<Vec<_>>()
                    .into_boxed_slice(),
            );
            let default = words.iter().find(|w| **w == default).unwrap();
            (Kind::Choice(words), Value::Choice(default))
        }
        _ => (kind, default),
    };
    let info: &'static OptionInfo = Box::leak(Box::new(OptionInfo {
        name: leak(name),
        kind,
        default,
        doc: leak(doc),
    }));
    declared_options.push(info);
    Ok(info)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Scope {
    Global,
    Document(DocumentId),
}
#[derive(Clone, Debug, Default)]
pub struct Options {
    global: BTreeMap<&'static str, Value>,
    documents: BTreeMap<DocumentId, BTreeMap<&'static str, Value>>,
}
impl Options {
    /// The value for a document: its own, else the global one, else the
    /// default.
    pub fn get(&self, document: Option<DocumentId>, name: &str) -> Value {
        let info = info(name).unwrap_or_else(|| panic!("unknown option {name}"));
        document
            .and_then(|document| self.documents.get(&document)?.get(info.name))
            .or_else(|| self.global.get(info.name))
            .copied()
            .unwrap_or(info.default)
    }
    pub fn bool(&self, document: Option<DocumentId>, name: &str) -> bool {
        matches!(self.get(document, name), Value::Bool(true))
    }
    pub fn int(&self, document: Option<DocumentId>, name: &str) -> u32 {
        match self.get(document, name) {
            Value::Int(value) => value,
            value => panic!("{name} is not a number: {value}"),
        }
    }
    pub fn choice(&self, document: Option<DocumentId>, name: &str) -> &'static str {
        match self.get(document, name) {
            Value::Choice(value) => value,
            value => panic!("{name} is not a choice: {value}"),
        }
    }
    /// Sets a value checked with `OptionInfo::parse`.
    pub fn set(&mut self, scope: Scope, name: &'static str, value: Value) {
        match scope {
            Scope::Global => self.global.insert(name, value),
            Scope::Document(document) => self
                .documents
                .entry(document)
                .or_default()
                .insert(name, value),
        };
    }
    /// Removes a document's own value, so the global one applies again.
    pub fn unset(&mut self, document: DocumentId, name: &str) {
        if let Some(values) = self.documents.get_mut(&document) {
            values.remove(name);
        }
    }
    pub fn forget(&mut self, document: DocumentId) {
        self.documents.remove(&document);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn set(options: &mut Options, scope: Scope, name: &str, text: &str) -> Result<(), String> {
        let info = info(name).ok_or("unknown option")?;
        options.set(scope, info.name, info.parse(text)?);
        Ok(())
    }
    #[test]
    fn documents_override_global_values_and_bad_values_are_rejected() {
        let mut options = Options::default();
        let document =
            crate::files::Workspace::default().new_document(crate::editor::Language::PlainText);
        assert_eq!(options.int(Some(document), "tab-width"), 4);
        set(&mut options, Scope::Global, "tab-width", "8").unwrap();
        set(&mut options, Scope::Document(document), "tab-width", "2").unwrap();
        assert_eq!(options.int(None, "tab-width"), 8);
        assert_eq!(options.int(Some(document), "tab-width"), 2);
        assert!(set(&mut options, Scope::Global, "tab-width", "0").is_err());
        assert!(set(&mut options, Scope::Global, "line-numbers", "sideways").is_err());
        assert!(set(&mut options, Scope::Global, "nonsense", "1").is_err());
        assert_eq!(options.int(None, "tab-width"), 8);
        set(&mut options, Scope::Global, "mouse", "off").unwrap();
        assert!(!options.bool(Some(document), "mouse"));
        options.unset(document, "tab-width");
        assert_eq!(options.int(Some(document), "tab-width"), 8);
        set(&mut options, Scope::Global, "line-numbers", "relative").unwrap();
        assert_eq!(options.choice(None, "line-numbers"), "relative");
    }
}
