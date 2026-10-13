//! YAML type validation from LLVM mapping traits. Presets provide defaults;
//! this schema covers optional fields and sequence elements independently.
use super::{
    ConfigError,
    value::{boolean, integer, unsigned},
};
use serde_json::Value;
use std::sync::OnceLock;

fn schema() -> &'static Value {
    static SCHEMA: OnceLock<Value> = OnceLock::new();
    SCHEMA.get_or_init(|| {
        serde_json::from_str(include_str!("schema.json")).expect("bundled LLVM schema")
    })
}
pub(super) fn known(key: &str) -> bool {
    schema()["options"].get(key).is_some()
}
pub(super) fn validate(key: &str, value: &mut Value, doc: usize) -> Result<(), ConfigError> {
    if let Some(typ) = schema()["options"][key].as_str() {
        validate_type(key, value, typ, doc)?;
    }
    Ok(())
}
fn validate_type(path: &str, value: &mut Value, typ: &str, doc: usize) -> Result<(), ConfigError> {
    let entry = &schema()["types"][typ];
    let error = |message: &str| ConfigError::key(doc, path, message);
    match entry["kind"].as_str().expect("schema kind") {
        "boolean" => {
            *value = Value::Bool(boolean(value, doc, path)?);
        }
        "integer" => {
            i32::try_from(integer(value, doc, path)?)
                .map_err(|_| error("integer is outside the LLVM int range"))?;
        }
        "unsigned" => {
            u32::try_from(unsigned(value, doc, path)?)
                .map_err(|_| error("integer is outside the LLVM unsigned range"))?;
        }
        "string" => {
            if !value.is_string() {
                if value.is_boolean() || value.is_number() {
                    *value = Value::String(value.to_string());
                } else {
                    return Err(error("expected a scalar string"));
                }
            }
        }
        "enum" => validate_enum(path, value, &entry["values"], doc)?,
        "mapping" => {
            if let Some(fields) = value.as_object_mut() {
                for (key, value) in fields {
                    let child_path = format!("{path}.{key}");
                    let typ = entry["fields"][key].as_str().ok_or_else(|| {
                        ConfigError::key(doc, &child_path, "unknown nested option")
                    })?;
                    validate_type(&child_path, value, typ, doc)?;
                }
            } else if !entry["values"].as_array().unwrap().is_empty() {
                validate_enum(path, value, &entry["values"], doc)?;
            } else {
                return Err(error("expected a mapping"));
            }
        }
        "sequence" => {
            let values = value
                .as_array_mut()
                .ok_or_else(|| error("expected a sequence"))?;
            for (index, value) in values.iter_mut().enumerate() {
                validate_type(
                    &format!("{path}[{index}]"),
                    value,
                    entry["item"].as_str().unwrap(),
                    doc,
                )?;
            }
        }
        _ => unreachable!("schema type"),
    }
    Ok(())
}
fn validate_enum(
    path: &str,
    value: &mut Value,
    choices: &Value,
    doc: usize,
) -> Result<(), ConfigError> {
    let spelling = match value {
        Value::String(text) => text.clone(),
        Value::Bool(value) => value.to_string(),
        _ => return Err(ConfigError::key(doc, path, "expected an enum spelling")),
    };
    if !choices
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v.as_str() == Some(&spelling))
    {
        let allowed: Vec<_> = choices
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        return Err(ConfigError::key(
            doc,
            path,
            format!("expected one of {}", allowed.join(", ")),
        ));
    }
    *value = Value::String(spelling);
    Ok(())
}
