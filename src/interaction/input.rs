use crate::core::Selection;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, Debug)]
pub enum InputMotion {
    Left,
    Right,
    WordLeft,
    WordRight,
    Start,
    End,
}
#[derive(Clone, Copy, Debug)]
pub enum InputKey {
    Char(char),
    Move { motion: InputMotion, extend: bool },
    Delete { backward: bool, word: bool },
    SelectAll,
    Kill(InputMotion),
    Yank,
}
/// Text changes require a new query; selection changes require only a repaint.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct InputUpdate {
    pub text_changed: bool,
    pub selection_changed: bool,
}

/// Single-line text and a directed byte selection. All endpoints remain at
/// extended grapheme boundaries. The owning session handles submission/cancel.
pub struct TextInput {
    text: String,
    selection: Selection,
    killed: String,
}
impl Default for TextInput {
    fn default() -> Self {
        Self {
            text: String::new(),
            selection: Selection::caret(0),
            killed: String::new(),
        }
    }
}
impl TextInput {
    pub fn new(text: &str) -> Self {
        let mut input = Self::default();
        input.insert(text);
        input
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub(super) fn has_killed_text(&self) -> bool {
        !self.killed.is_empty()
    }
    pub fn cursor(&self) -> usize {
        self.selection.head
    }
    pub fn selection(&self) -> Selection {
        self.selection
    }
    pub fn insert(&mut self, text: &str) -> InputUpdate {
        let text: String = text.chars().filter(|ch| !ch.is_control()).collect();
        // A paste containing only filtered characters must not erase a selection.
        if text.is_empty() {
            return InputUpdate::default();
        }
        self.replace(self.selection.range(), &text)
    }
    /// Replaces a byte range and places the caret after the new text.
    pub fn replace_range(&mut self, range: std::ops::Range<usize>, text: &str) -> InputUpdate {
        let text: String = text.chars().filter(|ch| !ch.is_control()).collect();
        self.replace(range, &text)
    }
    fn replace(&mut self, range: std::ops::Range<usize>, text: &str) -> InputUpdate {
        let before = self.selection;
        let text_changed = self.text[range.clone()] != *text;
        let cursor = range.start + text.len();
        if text_changed {
            self.text.replace_range(range, text);
        }
        self.selection = Selection::caret(self.clip_forward(cursor));
        InputUpdate {
            text_changed,
            selection_changed: before != self.selection,
        }
    }
    fn clip_forward(&self, offset: usize) -> usize {
        self.text
            .grapheme_indices(true)
            .map(|(i, _)| i)
            .chain(std::iter::once(self.text.len()))
            .find(|i| *i >= offset)
            .unwrap()
    }
    fn previous(&self, offset: usize) -> usize {
        self.text[..offset]
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(i, _)| i)
    }
    fn next(&self, offset: usize) -> usize {
        self.text[offset..]
            .graphemes(true)
            .next()
            .map_or(offset, |g| offset + g.len())
    }
    /// Unicode words are movement stops; punctuation and whitespace separate
    /// them.
    fn word_edge(&self, offset: usize, backward: bool) -> usize {
        crate::core::word_edge(&self.text, offset, backward)
            .map(|edge| self.clip_forward(edge))
            .unwrap_or(if backward { 0 } else { self.text.len() })
    }

    pub fn key(&mut self, key: InputKey) -> InputUpdate {
        let before = self.selection;
        match key {
            InputKey::Yank => return self.insert(&self.killed.clone()),
            InputKey::Kill(motion) => {
                let range = self.selection.range();
                let range = if range.is_empty() {
                    let cursor = self.cursor();
                    let other = match motion {
                        InputMotion::Start => 0,
                        InputMotion::End => self.text.len(),
                        InputMotion::WordLeft => self.word_edge(cursor, true),
                        InputMotion::WordRight => self.word_edge(cursor, false),
                        InputMotion::Left => self.previous(cursor),
                        InputMotion::Right => self.next(cursor),
                    };
                    cursor.min(other)..cursor.max(other)
                } else {
                    range
                };
                if !range.is_empty() {
                    self.killed = self.text[range.clone()].to_owned();
                }
                return self.replace(range, "");
            }
            InputKey::Char(ch) => return self.insert(&ch.to_string()),
            InputKey::SelectAll => {
                self.selection = Selection {
                    anchor: 0,
                    head: self.text.len(),
                }
            }
            InputKey::Move { motion, extend } => {
                let selected = self.selection.range();
                let offset = match motion {
                    InputMotion::Left if !extend && !selected.is_empty() => selected.start,
                    InputMotion::Right if !extend && !selected.is_empty() => selected.end,
                    InputMotion::Left => self.previous(self.cursor()),
                    InputMotion::Right => self.next(self.cursor()),
                    InputMotion::WordLeft => self.word_edge(self.cursor(), true),
                    InputMotion::WordRight => self.word_edge(self.cursor(), false),
                    InputMotion::Start => 0,
                    InputMotion::End => self.text.len(),
                };
                if extend {
                    self.selection.head = offset;
                } else {
                    self.selection = Selection::caret(offset);
                }
            }
            InputKey::Delete { backward, word } => {
                let range = self.selection.range();
                if !range.is_empty() {
                    return self.replace(range, "");
                }
                let cursor = self.cursor();
                let other = if word {
                    self.word_edge(cursor, backward)
                } else if backward {
                    self.previous(cursor)
                } else {
                    self.next(cursor)
                };
                return self.replace(cursor.min(other)..cursor.max(other), "");
            }
        }
        InputUpdate {
            text_changed: false,
            selection_changed: before != self.selection,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn movement(input: &mut TextInput, motion: InputMotion, extend: bool) -> InputUpdate {
        input.key(InputKey::Move { motion, extend })
    }
    #[test]
    fn input_navigates_and_deletes_whole_graphemes() {
        let mut field = TextInput::new("中e\u{301}🦀");
        let update = movement(&mut field, InputMotion::Left, false);
        assert_eq!(
            update,
            InputUpdate {
                text_changed: false,
                selection_changed: true
            }
        );
        field.key(InputKey::Delete {
            backward: true,
            word: false,
        });
        assert_eq!(field.text(), "中🦀");
        assert_eq!(field.cursor(), "中".len());
        field.key(InputKey::Delete {
            backward: false,
            word: false,
        });
        assert_eq!(field.text(), "中");
        movement(&mut field, InputMotion::Start, false);
        field.insert("x\n\x1b\t");
        assert_eq!(field.text(), "x中");
    }
    #[test]
    fn inserted_joiners_and_deleted_separators_normalize_caret() {
        let mut field = TextInput::new("👩👩");
        movement(&mut field, InputMotion::Left, false);
        field.insert("\u{200d}");
        assert_eq!(field.cursor(), field.text().len());
        field.key(InputKey::Delete {
            backward: true,
            word: false,
        });
        assert!(field.text().is_empty());
        let mut field = TextInput::new("🇨x🇳");
        movement(&mut field, InputMotion::Left, false);
        field.key(InputKey::Delete {
            backward: true,
            word: false,
        });
        assert_eq!(field.text(), "🇨🇳");
        assert_eq!(field.cursor(), field.text().len());
    }
    #[test]
    fn directed_selection_collapses_and_replaces_as_a_unit() {
        let mut input = TextInput::new("a中e\u{301}🦀");
        movement(&mut input, InputMotion::Left, true);
        movement(&mut input, InputMotion::Left, true);
        assert_eq!(
            input.selection(),
            Selection {
                anchor: input.text().len(),
                head: "a中".len()
            }
        );
        movement(&mut input, InputMotion::Right, false);
        assert_eq!(input.selection(), Selection::caret(input.text().len()));
        movement(&mut input, InputMotion::Left, true);
        movement(&mut input, InputMotion::Left, true);
        input.insert("X");
        assert_eq!(input.text(), "a中X");
        assert_eq!(input.selection(), Selection::caret("a中X".len()));
        input.key(InputKey::SelectAll);
        input.key(InputKey::Delete {
            backward: false,
            word: true,
        });
        assert_eq!(input.text(), "");
        assert_eq!(input.selection(), Selection::caret(0));
    }
    #[test]
    fn same_size_replacement_reports_text_change_and_equal_replacement_does_not() {
        let mut input = TextInput::new("ab");
        input.key(InputKey::SelectAll);
        assert_eq!(
            input.insert("cd"),
            InputUpdate {
                text_changed: true,
                selection_changed: true
            }
        );
        input.key(InputKey::SelectAll);
        assert_eq!(
            input.insert("cd"),
            InputUpdate {
                text_changed: false,
                selection_changed: true
            }
        );
        input.key(InputKey::SelectAll);
        assert_eq!(input.insert("\r\n\x1b"), InputUpdate::default());
        assert_eq!(input.text(), "cd");
        assert_eq!(input.selection(), Selection { anchor: 0, head: 2 });
    }
    #[test]
    fn unicode_word_movement_deletion_and_extension_share_boundaries() {
        let mut input = TextInput::new("foo/naïve_bar 🦀 baz");
        movement(&mut input, InputMotion::WordLeft, false);
        assert_eq!(&input.text()[input.cursor()..], "baz");
        movement(&mut input, InputMotion::WordLeft, true);
        assert_eq!(&input.text()[input.selection().range()], "naïve_bar 🦀 ");
        input.key(InputKey::Delete {
            backward: true,
            word: false,
        });
        assert_eq!(input.text(), "foo/baz");
        movement(&mut input, InputMotion::Start, false);
        movement(&mut input, InputMotion::WordRight, false);
        assert_eq!(input.cursor(), 3);
        input.key(InputKey::Delete {
            backward: false,
            word: true,
        });
        assert_eq!(input.text(), "foo");
    }
    #[test]
    fn boundary_noops_do_not_request_repaint_or_query() {
        let mut input = TextInput::default();
        for key in [
            InputKey::Move {
                motion: InputMotion::Left,
                extend: false,
            },
            InputKey::Move {
                motion: InputMotion::Right,
                extend: true,
            },
            InputKey::Delete {
                backward: true,
                word: false,
            },
            InputKey::Delete {
                backward: false,
                word: true,
            },
            InputKey::SelectAll,
        ] {
            assert_eq!(input.key(key), InputUpdate::default());
        }
    }
    #[test]
    fn mixed_input_traces_preserve_boundaries_and_report_actual_changes() {
        for initial in [
            "",
            "中e\u{301}🦀",
            "🇨🇳🇯🇵",
            "👩\u{200d}💻",
            "one/path_two",
            "\u{301}abc",
        ] {
            let mut input = TextInput::new(initial);
            let mut seed = 17_u32;
            for _ in 0..120 {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                let text = input.text().to_owned();
                let selection = input.selection();
                let update = match seed % 10 {
                    0 => input.insert("e\u{301}"),
                    1 => input.insert("\u{200d}👩"),
                    2 => input.insert("\r\n"),
                    3 => input.key(InputKey::SelectAll),
                    4 => input.key(InputKey::Delete {
                        backward: true,
                        word: seed & 16 != 0,
                    }),
                    5 => input.key(InputKey::Delete {
                        backward: false,
                        word: seed & 16 != 0,
                    }),
                    n => movement(
                        &mut input,
                        match n {
                            6 => InputMotion::Left,
                            7 => InputMotion::Right,
                            8 => InputMotion::WordLeft,
                            _ => InputMotion::WordRight,
                        },
                        seed & 16 != 0,
                    ),
                };
                assert_eq!(update.text_changed, text != input.text());
                assert_eq!(update.selection_changed, selection != input.selection());
                for endpoint in [input.selection().anchor, input.selection().head] {
                    assert!(
                        input
                            .text()
                            .grapheme_indices(true)
                            .map(|(i, _)| i)
                            .chain(std::iter::once(input.text().len()))
                            .any(|i| i == endpoint)
                    );
                }
                assert!(!input.text().chars().any(char::is_control));
            }
        }
    }
}
