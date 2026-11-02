use super::{
    cpp::to_rules,
    value::{boolean, choice, string},
};
use crate::cpp::CppRules;
use serde_json::{Map, Value};
use std::{
    collections::{BTreeMap, HashSet},
    fmt,
    sync::OnceLock,
};

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
    /// One-based YAML document number; zero denotes a bundled preset.
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
    explicit_options: BTreeMap<String, usize>,
    preset_document: usize,
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
    let mut config = ClangConfig {
        values,
        rules,
        inherit: None,
        diagnostics: vec![],
        explicit_options: BTreeMap::new(),
        preset_document: 0,
    };
    refresh_diagnostics(&mut config);
    Ok(config)
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

/// Options parsed and kept whose behavior interactive indentation lacks.
/// Macros counts only for definitions it cannot use.
const UNSUPPORTED: &[&str] = &["Macros"];

fn record_explicit(
    origins: &mut BTreeMap<String, usize>,
    key: &str,
    value: &Value,
    document: usize,
) {
    origins.insert(key.into(), document);
    if let Value::Object(fields) = value {
        for (name, value) in fields {
            record_explicit(origins, &format!("{key}.{name}"), value, document);
        }
    }
}

/// Recompute capability diagnostics after inheritance and overrides. Explicit
/// unsupported choices and deviations from the implementation's baseline are
/// reported; sources remain attached to the effective options.
fn refresh_diagnostics(config: &mut ClangConfig) {
    config
        .diagnostics
        .retain(|diagnostic| !UNSUPPORTED.contains(&diagnostic.option.as_str()));
    let source = |key: &str| {
        config
            .explicit_options
            .get(key)
            .copied()
            .unwrap_or(config.preset_document)
    };
    // Only definitions that expand to the head of a loop or an `if` take
    // part in indentation.
    let unused = config
        .values
        .get("Macros")
        .and_then(Value::as_array)
        .is_some_and(|definitions| {
            definitions.iter().any(|definition| {
                definition
                    .as_str()
                    .is_none_or(|text| super::cpp::control_macro(text).is_none())
            })
        });
    if unused {
        config.diagnostics.push(ConfigDiagnostic {
            document: source("Macros"),
            option: "Macros".into(),
            message: "parsed and retained; interactive indentation uses only definitions that expand to the head of a for, while or if statement".into(),
        });
    }
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
            base.preset_document = index;
        }
    }
    let mut values = doc.clone();
    values.remove("BasedOnStyle");
    for (key, value) in &mut values {
        if !super::schema::known(key) {
            if unknown == UnknownOptions::Error {
                return Err(ConfigError::key(index, key, "unknown clang-format option"));
            }
            base.diagnostics.push(ConfigDiagnostic {
                document: index,
                option: key.clone(),
                message: "unknown clang-format option; retained but not applied".into(),
            });
        } else {
            super::schema::validate(key, value, index)?;
        }
    }
    // These legacy names affect interactive indentation and share the modern
    // option's meaning. Explicit modern values take precedence, as in LLVM.
    for (old, new) in [
        (
            "IndentFunctionDeclarationAfterType",
            "IndentWrappedFunctionNames",
        ),
        ("IndentRequires", "IndentRequiresClause"),
    ] {
        if !values.contains_key(new)
            && let Some(value) = values.get(old).cloned()
        {
            values.insert(new.into(), value);
        }
    }
    if let Some(value) = values.get("BreakConstructorInitializersBeforeComma")
        && boolean(value, index, "BreakConstructorInitializersBeforeComma")?
        && values
            .get("BreakConstructorInitializers")
            .or_else(|| base.values.get("BreakConstructorInitializers"))
            .and_then(Value::as_str)
            == Some("BeforeColon")
    {
        values.insert(
            "BreakConstructorInitializers".into(),
            Value::String("BeforeComma".into()),
        );
    }
    merge(&mut base.values, &values);
    base.rules = to_rules(&base.values, index)?;
    for (key, value) in &values {
        record_explicit(&mut base.explicit_options, key, value, index);
    }
    refresh_diagnostics(&mut base);

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
