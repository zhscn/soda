//! Typed options with a global value and per-document overrides. The table
//! of options is fixed; values are checked against their type when set, so
//! readers never see an invalid one.
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
        name: "completion",
        kind: Kind::Bool,
        default: Value::Bool(true),
        doc: "Show candidates while typing in Insert; <a-/> asks for them regardless",
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
pub fn info(name: &str) -> Option<&'static OptionInfo> {
    OPTIONS.iter().find(|option| option.name == name)
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
