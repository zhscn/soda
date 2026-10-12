use super::{
    cpp::to_rules,
    value::{boolean, choice, integer, string},
};
use crate::cpp::CppRules;
use serde_json::{Map, Value};
use std::{collections::HashSet, fmt, sync::OnceLock};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UnknownOptions {
    Error,
    Warn,
}
#[derive(Clone, Debug)]
pub struct ConfigOptions {
    pub fallback: String,
    pub unknown_options: UnknownOptions,
}
impl Default for ConfigOptions {
    fn default() -> Self {
        Self {
            fallback: "LLVM".into(),
            unknown_options: UnknownOptions::Error,
        }
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConfigDiagnostic {
    pub document: usize,
    pub option: String,
    pub message: String,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConfigError {
    pub document: Option<usize>,
    pub option: Option<String>,
    pub message: String,
}
impl ConfigError {
    pub(super) fn key(document: usize, option: &str, message: impl Into<String>) -> Self {
        Self {
            document: Some(document),
            option: Some(option.into()),
            message: message.into(),
        }
    }
    pub(crate) fn message(message: impl Into<String>) -> Self {
        Self {
            document: None,
            option: None,
            message: message.into(),
        }
    }
}
impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(document) = self.document {
            write!(f, "document {document}: ")?;
        }
        if let Some(option) = &self.option {
            write!(f, "{option}: ")?;
        }
        f.write_str(&self.message)
    }
}
impl std::error::Error for ConfigError {}
#[derive(Clone, Debug)]
pub struct ClangConfig {
    /// Full resolved option tree. Options unrelated to interactive indentation
    /// remain available here rather than being discarded by a scalar parser.
    pub values: Map<String, Value>,
    pub rules: CppRules,
    pub inherit: Option<String>,
    pub diagnostics: Vec<ConfigDiagnostic>,
}
fn presets() -> &'static Map<String, Value> {
    static PRESETS: OnceLock<Map<String, Value>> = OnceLock::new();
    PRESETS.get_or_init(|| {
        serde_json::from_str(include_str!("presets.json")).expect("bundled preset data")
    })
}
/// Complete C++ preset option trees captured from LLVM clang-format 23.1.3.
/// Other presets store deltas from LLVM to keep the data compact.
pub fn preset(name: &str) -> Result<ClangConfig, ConfigError> {
    let name = name.to_ascii_lowercase();
    let data = presets();
    let Some(overrides) = data.get(&name) else {
        return Err(ConfigError::message(format!("unknown preset {name}")));
    };
    let mut values = data["llvm"].as_object().unwrap().clone();
    if name != "llvm" {
        merge(&mut values, overrides.as_object().unwrap());
    }
    let rules = to_rules(&values, 0)?;
    Ok(ClangConfig {
        values,
        rules,
        inherit: None,
        diagnostics: vec![],
    })
}
fn merge(base: &mut Map<String, Value>, patch: &Map<String, Value>) {
    for (key, value) in patch {
        if let (Some(Value::Object(base)), Value::Object(patch)) = (base.get_mut(key), value) {
            merge(base, patch);
        } else {
            base.insert(key.clone(), value.clone());
        }
    }
}

fn validate_shape(
    key: &str,
    value: &Value,
    expected: &Value,
    doc: usize,
) -> Result<(), ConfigError> {
    if let Value::Object(schema) = expected {
        if let Value::Object(fields) = value {
            for (name, value) in fields {
                let path = format!("{key}.{name}");
                let expected = schema
                    .get(name)
                    .ok_or_else(|| ConfigError::key(doc, &path, "unknown nested option"))?;
                validate_shape(&path, value, expected, doc)?;
            }
        } else if !((key.starts_with("AlignConsecutive")
            || matches!(key, "AlignTrailingComments" | "SortIncludes"))
            && (value.is_string() || value.is_boolean()))
        {
            return Err(ConfigError::key(doc, key, "expected a mapping"));
        }
    } else if expected.is_array() && !value.is_array() {
        return Err(ConfigError::key(doc, key, "expected a sequence"));
    } else if expected.is_number() && integer(value, doc, key).is_err() {
        return Err(ConfigError::key(doc, key, "expected an integer"));
    } else if (expected.is_boolean() || expected.is_string())
        && !(value.is_string() || value.is_boolean())
    {
        return Err(ConfigError::key(doc, key, "expected a scalar"));
    }
    Ok(())
}
fn patch(
    mut base: ClangConfig,
    doc: &Map<String, Value>,
    index: usize,
    unknown: UnknownOptions,
) -> Result<ClangConfig, ConfigError> {
    if let Some(based) = doc.get("BasedOnStyle") {
        let based = string(based, index, "BasedOnStyle")?;
        if based.eq_ignore_ascii_case("InheritParentConfig") {
            base.inherit = Some("..".into());
        } else if based
            .to_ascii_lowercase()
            .starts_with("inheritparentconfig=")
        {
            let dir = &based["InheritParentConfig=".len()..];
            if dir.is_empty() {
                return Err(ConfigError::key(
                    index,
                    "BasedOnStyle",
                    "inheritance directory is empty",
                ));
            }
            base.inherit = Some(dir.into());
        } else {
            base = preset(based).map_err(|e| ConfigError::key(index, "BasedOnStyle", e.message))?;
        }
    }
    let mut values = doc.clone();
    values.remove("BasedOnStyle");
    if let Some(v) = values.get("BreakConstructorInitializersBeforeComma")
        && !values.contains_key("BreakConstructorInitializers")
        && boolean(v, index, "BreakConstructorInitializersBeforeComma")?
    {
        values.insert(
            "BreakConstructorInitializers".into(),
            Value::String("BeforeComma".into()),
        );
    }
    for key in doc.keys() {
        if !include_str!("keys.txt").lines().any(|known| known == key) {
            if unknown == UnknownOptions::Error {
                return Err(ConfigError::key(index, key, "unknown clang-format option"));
            }
            base.diagnostics.push(ConfigDiagnostic {
                document: index,
                option: key.clone(),
                message: "unknown clang-format option; retained but not applied".into(),
            });
        }
        if let Some(expected) = presets()["llvm"].get(key) {
            validate_shape(key, &doc[key], expected, index)?;
        }
    }
    merge(&mut base.values, &values);
    base.rules = to_rules(&base.values, index)?;
    // Formatting-only fields stay in the option tree. Flag indentation fields
    // that need further parser work instead of claiming that they take effect.
    for key in [
        "IndentCaseBlocks",
        "IndentGotoLabels",
        "IndentRequiresClause",
        "LambdaBodyIndentation",
        "MacroBlockBegin",
        "MacroBlockEnd",
    ] {
        if doc.contains_key(key) {
            base.diagnostics.push(ConfigDiagnostic {document:index,option:key.into(),message:"parsed and retained; interactive indentation does not yet implement this option".into()});
        }
    }
    if doc.get("AlignOperands").and_then(Value::as_str) == Some("AlignAfterOperator") {
        base.diagnostics.push(ConfigDiagnostic {
            document: index,
            option: "AlignOperands".into(),
            message: "AlignAfterOperator currently uses Align continuation rules".into(),
        });
    }
    if doc
        .get("BraceWrapping")
        .and_then(|v| v.get("IndentBraces"))
        .and_then(Value::as_bool)
        == Some(true)
        || doc.get("BreakBeforeBraces").and_then(Value::as_str) == Some("GNU")
    {
        base.diagnostics.push(ConfigDiagnostic {
            document: index,
            option: "BraceWrapping".into(),
            message:
                "brace indentation is retained; not yet implemented in interactive indentation"
                    .into(),
        });
    }

    Ok(base)
}
/// Parse a YAML stream on top of a resolved base. Only the first document may
/// omit Language; a language document starts from that common document, and
/// BasedOnStyle within it resets to the named preset before its own overrides.
pub fn parse_config(
    yaml: &str,
    base: &ClangConfig,
    language: &str,
    is_header: bool,
    unknown: UnknownOptions,
) -> Result<Option<ClangConfig>, ConfigError> {
    if !matches!(language, "Cpp" | "C") {
        return Err(ConfigError::message(
            "indentation configuration supports Cpp and C",
        ));
    }
    let documents: Vec<Value> =
        serde_saphyr::from_multiple(yaml).map_err(|e| ConfigError::message(e.to_string()))?;
    if documents.is_empty() {
        return Ok(Some(base.clone()));
    }
    let mut common = None;
    let mut selected = None;
    let mut alternate = None;
    let mut languages = HashSet::new();
    for (index, value) in documents.into_iter().enumerate() {
        let Some(doc) = value.as_object() else {
            return Err(ConfigError::message(format!(
                "document {} must be a mapping",
                index + 1
            )));
        };
        let lang = doc
            .get("Language")
            .map(|v| {
                choice(
                    v,
                    index + 1,
                    "Language",
                    &[
                        "Cpp",
                        "C",
                        "CSharp",
                        "Java",
                        "JavaScript",
                        "Json",
                        "ObjC",
                        "Proto",
                        "TableGen",
                        "TextProto",
                        "Verilog",
                    ],
                )
            })
            .transpose()?;
        if index > 0 && lang.is_none() {
            return Err(ConfigError::key(
                index + 1,
                "Language",
                "only the first document can omit Language",
            ));
        }
        if let Some(lang) = lang
            && !languages.insert(lang.to_owned())
        {
            return Err(ConfigError::key(
                index + 1,
                "Language",
                "duplicate language document",
            ));
        }
        let inherited = common.as_ref().unwrap_or(base);
        let parsed = patch(inherited.clone(), doc, index + 1, unknown)?;
        match lang {
            None => common = Some(parsed),
            Some(lang) if lang == language => selected = Some(parsed),
            Some("C") if language == "Cpp" && is_header => alternate = Some(parsed),
            Some("Cpp") if language == "C" => alternate = Some(parsed),
            _ => {}
        }
    }
    let mut chosen = selected.or(common).or(alternate);
    if let Some(config) = &mut chosen {
        config
            .values
            .insert("Language".into(), Value::String(language.into()));
    }
    Ok(chosen)
}
