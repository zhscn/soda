//! EditorConfig supplies file defaults below explicit document settings. The
//! core resolves section globs, inheritance and unset; this adapter only maps
//! properties the editor can represent.
use crate::options::Value;
use ec4rs::property::*;
use std::{collections::BTreeMap, path::Path};

#[derive(Clone, Debug, Default)]
pub(crate) struct Settings {
    pub values: BTreeMap<&'static str, Value>,
    pub indent_uses_tab: bool,
    pub newline: Option<&'static str>,
    pub bom: Option<bool>,
    pub problem: Option<String>,
}
impl Settings {
    pub fn load(path: &Path) -> Self {
        match ec4rs::properties_of(path) {
            Ok(mut properties) => {
                let tab = properties.get::<TabWidth>();
                let indent = properties.get::<IndentSize>();
                let use_editor_tab = matches!(indent, Ok(IndentSize::UseTabWidth))
                    || (!matches!(tab, Ok(TabWidth::Value(1..=16)))
                        && properties.get::<IndentStyle>() == Ok(IndentStyle::Tabs)
                        && !matches!(indent, Ok(IndentSize::Value(0..=16))));
                properties.use_fallbacks();
                let mut settings = Self::from_properties(&properties);
                if use_editor_tab {
                    settings.values.remove("indent-width");
                    settings.indent_uses_tab = true;
                }
                settings
            }
            Err(error) => Self {
                problem: Some(format!("EditorConfig: {error}")),
                ..Self::default()
            },
        }
    }
    fn from_properties(properties: &ec4rs::Properties) -> Self {
        let mut settings = Self::default();
        if let Ok(style) = properties.get::<IndentStyle>() {
            settings
                .values
                .insert("expand-tab", Value::Bool(style == IndentStyle::Spaces));
        }
        if let Ok(size) = properties.get::<IndentSize>() {
            match size {
                IndentSize::Value(size) if size <= 16 => {
                    settings
                        .values
                        .insert("indent-width", Value::Int(size as u32));
                }
                IndentSize::UseTabWidth => settings.indent_uses_tab = true,
                _ => {}
            }
        }
        if let Ok(TabWidth::Value(size @ 1..=16)) = properties.get::<TabWidth>() {
            settings.values.insert("tab-width", Value::Int(size as u32));
        }
        if let Ok(TrimTrailingWs::Value(value)) = properties.get::<TrimTrailingWs>() {
            settings
                .values
                .insert("trim-trailing-whitespace", Value::Bool(value));
        }
        if let Ok(FinalNewline::Value(value)) = properties.get::<FinalNewline>() {
            settings.values.insert("final-newline", Value::Bool(value));
        }
        settings.newline = match properties.get::<EndOfLine>().ok() {
            Some(EndOfLine::Lf) => Some("\n"),
            Some(EndOfLine::CrLf) => Some("\r\n"),
            _ => None,
        };
        settings.bom = match properties.get::<Charset>().ok() {
            Some(Charset::Utf8) => Some(false),
            Some(Charset::Utf8Bom) => Some(true),
            _ => None,
        };
        settings
    }
}
