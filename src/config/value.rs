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
        .or_else(|| match value.as_str()?.to_ascii_lowercase().as_str() {
            "true" | "y" | "yes" | "on" => Some(true),
            "false" | "n" | "no" | "off" => Some(false),
            _ => None,
        })
        .ok_or_else(|| ConfigError::key(doc, key, "expected true or false"))
}
pub(super) fn integer(value: &Value, doc: usize, key: &str) -> Result<i64, ConfigError> {
    value
        .as_i64()
        .or_else(|| {
            let (negative, magnitude) = integer_spelling(value.as_str()?)?;
            if negative && magnitude == (1_u64 << 63) {
                Some(i64::MIN)
            } else {
                i64::try_from(magnitude)
                    .ok()
                    .map(|n| if negative { -n } else { n })
            }
        })
        .ok_or_else(|| ConfigError::key(doc, key, "expected an integer"))
}
pub(super) fn unsigned(value: &Value, doc: usize, key: &str) -> Result<u64, ConfigError> {
    value
        .as_u64()
        .or_else(|| {
            let (negative, magnitude) = integer_spelling(value.as_str()?)?;
            (!negative).then_some(magnitude)
        })
        .ok_or_else(|| ConfigError::key(doc, key, "expected an unsigned integer"))
}
// LLVM's scalar integer reader detects radix from the scalar spelling.
fn integer_spelling(text: &str) -> Option<(bool, u64)> {
    let negative = text.starts_with('-');
    let digits = text
        .strip_prefix('-')
        .or_else(|| text.strip_prefix('+'))
        .unwrap_or(text);
    let (radix, digits) = if let Some(value) = digits
        .strip_prefix("0x")
        .or_else(|| digits.strip_prefix("0X"))
    {
        (16, value)
    } else if let Some(value) = digits
        .strip_prefix("0b")
        .or_else(|| digits.strip_prefix("0B"))
    {
        (2, value)
    } else if let Some(value) = digits
        .strip_prefix("0o")
        .or_else(|| digits.strip_prefix("0O"))
    {
        (8, value)
    } else if digits.len() > 1 && digits.starts_with('0') {
        (8, &digits[1..])
    } else {
        (10, digits)
    };
    u64::from_str_radix(digits, radix)
        .ok()
        .map(|n| (negative, n))
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
    if integer(value, doc, key)? < 0 {
        Ok(None)
    } else {
        size(value, doc, key).map(Some)
    }
}
