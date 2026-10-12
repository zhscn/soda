use super::ConfigError;
use serde_json::Value;

pub(super) fn string<'a>(value: &'a Value, doc: usize, key: &str) -> Result<&'a str, ConfigError> {
    value
        .as_str()
        .ok_or_else(|| ConfigError::key(doc, key, "expected a string"))
}
pub(super) fn boolean(value: &Value, doc: usize, key: &str) -> Result<bool, ConfigError> {
    value
        .as_bool()
        .or_else(|| match value.as_str() {
            Some("true") => Some(true),
            Some("false") => Some(false),
            _ => None,
        })
        .ok_or_else(|| ConfigError::key(doc, key, "expected true or false"))
}
pub(super) fn integer(value: &Value, doc: usize, key: &str) -> Result<i64, ConfigError> {
    value
        .as_i64()
        .or_else(|| value.as_str()?.parse().ok())
        .ok_or_else(|| ConfigError::key(doc, key, "expected an integer"))
}
pub(super) fn size(value: &Value, doc: usize, key: &str) -> Result<usize, ConfigError> {
    let n = integer(value, doc, key)?;
    let width = usize::try_from(n)
        .map_err(|_| ConfigError::key(doc, key, "expected a width between 0 and 4096"))?;
    crate::cpp::validate_width(width).map_err(|message| ConfigError::key(doc, key, message))?;
    Ok(width)
}
pub(super) fn choice<'a>(
    value: &'a Value,
    doc: usize,
    key: &str,
    allowed: &[&str],
) -> Result<&'a str, ConfigError> {
    let s = string(value, doc, key)?;
    if !allowed.contains(&s) {
        return Err(ConfigError::key(
            doc,
            key,
            format!("expected one of {}", allowed.join(", ")),
        ));
    }
    Ok(s)
}
pub(super) fn width_or_default(
    value: &Value,
    doc: usize,
    key: &str,
) -> Result<Option<usize>, ConfigError> {
    if integer(value, doc, key)? == -1 {
        Ok(None)
    } else {
        size(value, doc, key).map(Some)
    }
}
