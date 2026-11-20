//! Encodes a debounced snapshot change against the last snapshot queued
//! for the server. Diffing and JSON serialization run on the writer thread.
use crate::core::Snapshot;
use serde_json::{Value, json};

#[derive(Clone, Copy)]
pub(super) enum Sync {
    None,
    Full,
    Incremental(Encoding),
}

#[derive(Clone, Copy)]
pub(super) enum Encoding {
    Utf8,
    Utf16,
    Utf32,
}

impl Sync {
    pub(super) fn negotiate(capabilities: &Value, encoding: &str) -> Self {
        let sync = &capabilities["textDocumentSync"];
        match sync.as_u64().or_else(|| sync["change"].as_u64()) {
            Some(0) => Self::None,
            Some(2) => Self::Incremental(match encoding {
                "utf-8" => Encoding::Utf8,
                "utf-32" => Encoding::Utf32,
                _ => Encoding::Utf16,
            }),
            // Older servers and adapters may omit the entire capability.
            None if sync.is_object() => Self::None,
            _ => Self::Full,
        }
    }
}

/// Removes the common prefix and suffix, leaving one replacement range.
/// The endpoints must be Unicode scalar boundaries and outside CRLF.
pub(super) fn change(old: &Snapshot, new: &Snapshot, encoding: Encoding) -> Value {
    let old_text = old.byte_slice(0..old.len_bytes()).unwrap();
    let new_text = new.byte_slice(0..new.len_bytes()).unwrap();
    let mut start = old_text
        .bytes()
        .zip(new_text.bytes())
        .take_while(|(a, b)| a == b)
        .count();
    while !endpoint(old, start) || !endpoint(new, start) {
        start -= 1;
    }
    let shared = old.len_bytes().min(new.len_bytes()) - start;
    let mut tail = old_text
        .bytes_at(old.len_bytes())
        .reversed()
        .zip(new_text.bytes_at(new.len_bytes()).reversed())
        .take(shared)
        .take_while(|(a, b)| a == b)
        .count();
    while !endpoint(old, old.len_bytes() - tail) || !endpoint(new, new.len_bytes() - tail) {
        tail -= 1;
    }
    let end = old.len_bytes() - tail;
    let text = new
        .byte_slice(start..new.len_bytes() - tail)
        .unwrap()
        .to_string();
    let mut position = Position::default();
    position.advance(old, 0..start, encoding);
    let start_position = position.value();
    position.advance(old, start..end, encoding);
    json!({ "range": { "start": start_position, "end": position.value() }, "text": text })
}

fn endpoint(text: &Snapshot, at: usize) -> bool {
    text.is_char_boundary(at)
        && !(at > 0
            && at < text.len_bytes()
            && text
                .byte_slice(at - 1..at + 1)
                .is_some_and(|pair| pair == "\r\n"))
}

#[derive(Default)]
struct Position {
    line: usize,
    character: usize,
}

impl Position {
    fn advance(&mut self, text: &Snapshot, range: std::ops::Range<usize>, encoding: Encoding) {
        // Both endpoints come from change(), so neither splits CRLF.
        let mut cr = false;
        for ch in text.byte_slice(range).unwrap().chars() {
            match ch {
                '\r' => {
                    self.line += 1;
                    self.character = 0;
                }
                '\n' => {
                    self.line += usize::from(!cr);
                    self.character = 0;
                }
                _ => {
                    self.character += match encoding {
                        Encoding::Utf8 => ch.len_utf8(),
                        Encoding::Utf16 => ch.len_utf16(),
                        Encoding::Utf32 => 1,
                    };
                }
            }
            cr = ch == '\r';
        }
    }

    fn value(&self) -> Value {
        json!({ "line": self.line, "character": self.character })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_use_the_previous_snapshot_and_negotiated_encoding() {
        let old = Snapshot::new("a\r\n😀猫\rZ".into(), 1);
        let new = Snapshot::new("a\r\n😀犬\rZ".into(), 2);
        for (encoding, start, end) in [
            (Encoding::Utf8, 4, 7),
            (Encoding::Utf16, 2, 3),
            (Encoding::Utf32, 1, 2),
        ] {
            assert_eq!(
                change(&old, &new, encoding),
                json!({"range": {
                    "start": {"line":1,"character":start},
                    "end": {"line":1,"character":end}},
                    "text":"犬"})
            );
        }
    }

    #[test]
    fn line_endings_are_replaced_as_a_unit() {
        let old = Snapshot::new("a\r\nb\rc".into(), 1);
        let new = Snapshot::new("a\nb\rc".into(), 2);
        assert_eq!(
            change(&old, &new, Encoding::Utf16),
            json!({"range": {
                "start": {"line":0,"character":1},
                "end": {"line":1,"character":0}},
                "text":"\n"})
        );
    }

    #[test]
    fn a_small_edit_in_a_large_cpp_snapshot_has_a_small_payload() {
        let text = "// padding to emulate a large C++ source file\n".repeat(64_000);
        let old = Snapshot::new(text, 1);
        let start = old.line_start(32_000).unwrap();
        let new = old.edited(
            &[crate::core::Change::new(start..start, "// inserted\n")],
            2,
        );
        let delta = change(&old, &new, Encoding::Utf16).to_string();
        let full = json!({"text": new.text()}).to_string();
        assert!(full.len() > 2_500_000);
        assert!(delta.len() < 150, "{delta}");
    }
}
