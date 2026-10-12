use soda::core::{
    Association, ByteOffset, EditError, EditorState, LogicalColumn, TextPoint,
    clip_grapheme_offset, column_width, deletion_range, logical_column_at,
    offset_at_logical_column, step_grapheme,
};
use std::num::NonZeroUsize;
use unicode_segmentation::UnicodeSegmentation;

#[test]
fn text_points_round_trip_utf8_bytes_and_line_endings_strictly() {
    let state = EditorState::new("界\r\n🦀\nlast\r");
    let snapshot = state.snapshot();
    for offset in 0..=snapshot.len_bytes() {
        let actual = snapshot.text_point(ByteOffset(offset));
        if snapshot.is_char_boundary(offset) {
            let point = actual.unwrap();
            assert_eq!(snapshot.byte_offset(point).unwrap(), ByteOffset(offset));
        } else {
            assert_eq!(actual, Err(EditError::InvalidRange));
        }
    }
    assert_eq!(
        snapshot.text_point(ByteOffset(4)).unwrap(),
        TextPoint {
            row: 0,
            byte_column: 4
        }
    );
    assert_eq!(
        snapshot.byte_offset(TextPoint {
            row: 0,
            byte_column: 5
        }),
        Err(EditError::InvalidRange)
    );
    assert_eq!(
        snapshot.byte_offset(TextPoint {
            row: usize::MAX,
            byte_column: usize::MAX
        }),
        Err(EditError::InvalidRange)
    );
    assert_eq!(
        snapshot.clip_text_point(
            TextPoint {
                row: 0,
                byte_column: usize::MAX
            },
            Association::After
        ),
        TextPoint {
            row: 0,
            byte_column: 3
        }
    );
    assert_eq!(
        snapshot.clip_byte_offset(ByteOffset(1), Association::Before),
        ByteOffset(0)
    );
    assert_eq!(
        snapshot.clip_byte_offset(ByteOffset(1), Association::After),
        ByteOffset(3)
    );
}

#[test]
fn logical_column_measurement_is_consistent_across_scripts_and_chunks() {
    let width = NonZeroUsize::new(4).unwrap();
    let source = format!("{}لا\t👨‍👩‍👧‍👦e\u{301}界", "a".repeat(2048));
    let state = EditorState::new(source.clone());
    let snapshot = state.snapshot();
    let mut column = 0;
    for (start, grapheme) in source.grapheme_indices(true) {
        assert_eq!(
            logical_column_at(snapshot, ByteOffset(start), width).unwrap(),
            LogicalColumn(column)
        );
        column = column_width(grapheme, column, width);
    }
    assert_eq!(column_width(&source, 0, width), column);
    assert_eq!(
        logical_column_at(snapshot, ByteOffset(source.len()), width).unwrap(),
        LogicalColumn(column)
    );
    assert_eq!(
        offset_at_logical_column(snapshot, 0, LogicalColumn(column), width).unwrap(),
        ByteOffset(source.len())
    );
    let arabic = EditorState::new("لا");
    assert_eq!(
        logical_column_at(arabic.snapshot(), ByteOffset(4), width).unwrap(),
        LogicalColumn(2)
    );
    assert_eq!(
        offset_at_logical_column(arabic.snapshot(), 0, LogicalColumn(2), width).unwrap(),
        ByteOffset(4)
    );
}

#[test]
fn clipping_and_columns_use_explicit_bias_and_cluster_boundaries() {
    let state = EditorState::new("e\u{301}\t界\r\n");
    let snapshot = state.snapshot();
    let width = NonZeroUsize::new(4).unwrap();
    assert_eq!(
        clip_grapheme_offset(snapshot, ByteOffset(1), Association::Before).unwrap(),
        ByteOffset(0)
    );
    assert_eq!(
        clip_grapheme_offset(snapshot, ByteOffset(1), Association::After).unwrap(),
        ByteOffset(3)
    );
    assert_eq!(
        logical_column_at(snapshot, ByteOffset(1), width).unwrap(),
        LogicalColumn(0)
    );
    assert_eq!(
        offset_at_logical_column(snapshot, 0, LogicalColumn(3), width).unwrap(),
        ByteOffset(3)
    );
    assert_eq!(
        offset_at_logical_column(snapshot, 0, LogicalColumn(5), width).unwrap(),
        ByteOffset(4)
    );
    assert_eq!(
        clip_grapheme_offset(snapshot, ByteOffset(8), Association::Before).unwrap(),
        ByteOffset(7)
    );
    assert_eq!(
        clip_grapheme_offset(snapshot, ByteOffset(8), Association::After).unwrap(),
        ByteOffset(9)
    );
}

#[test]
fn rope_grapheme_queries_match_contiguous_oracle_at_every_scalar_boundary() {
    let sources = [
        "a界\r\n".repeat(1200),
        format!("{}e{}x", "a".repeat(1000), "\u{301}".repeat(1100)),
        format!("{}{}end", "a".repeat(1017), "👨‍👩‍👧‍👦🇺🇸क्‍ष".repeat(200)),
        "🇦".repeat(600),
        "".to_owned(),
    ];
    for source in sources {
        let state = EditorState::new(source.clone());
        let boundaries: Vec<_> = source
            .grapheme_indices(true)
            .map(|(start, _)| start)
            .chain(std::iter::once(source.len()))
            .collect();
        for offset in (0..=source.len()).filter(|&offset| source.is_char_boundary(offset)) {
            let next = boundaries
                .iter()
                .copied()
                .find(|&boundary| boundary > offset)
                .unwrap_or(offset);
            let previous = boundaries
                .iter()
                .copied()
                .take_while(|&boundary| boundary < offset)
                .last()
                .unwrap_or(offset);
            assert_eq!(
                step_grapheme(state.snapshot(), ByteOffset(offset), true).unwrap(),
                ByteOffset(next),
                "next {offset}"
            );
            assert_eq!(
                step_grapheme(state.snapshot(), ByteOffset(offset), false).unwrap(),
                ByteOffset(previous),
                "previous {offset}"
            );
            let inside = !boundaries.contains(&offset);
            for forward in [false, true] {
                let expected = if inside {
                    previous..next
                } else {
                    let other = if forward { next } else { previous };
                    offset.min(other)..offset.max(other)
                };
                assert_eq!(
                    deletion_range(state.snapshot(), ByteOffset(offset), forward).unwrap(),
                    expected
                );
            }
        }
    }
}

#[test]
fn retained_positions_require_matching_document_and_revision() {
    use soda::core::{Change, Transaction};
    use soda::editor::{Command, Editor, Language};
    let mut editor = Editor::new("abcdef", Language::PlainText);
    let position = editor
        .model()
        .document()
        .position(ByteOffset(4), Association::After)
        .unwrap();
    let deleted = editor
        .model()
        .document()
        .position(ByteOffset(2), Association::After)
        .unwrap();
    let update = editor
        .execute(Command::Apply(Transaction::new(
            0,
            vec![Change::new(1..3, "x")],
        )))
        .unwrap()
        .document
        .unwrap();
    assert_eq!(
        position.resolve(editor.model().document()),
        Err(EditError::StaleVersion)
    );
    let mapped = position.map(&update, true).unwrap().unwrap();
    assert_eq!(
        mapped.resolve(editor.model().document()).unwrap(),
        ByteOffset(3)
    );
    assert!(deleted.map(&update, true).unwrap().is_none());
    assert_eq!(mapped.map(&update, false), Err(EditError::StaleVersion));
    let other = Editor::new("abcdef", Language::PlainText);
    assert_eq!(
        position.resolve(other.model().document()),
        Err(EditError::WrongDocument)
    );
}

#[test]
fn column_queries_match_grapheme_policy_near_chunk_boundaries_and_zero_width_text() {
    let width = NonZeroUsize::new(8).unwrap();
    for text in [
        format!("{}a\u{301}\t界", "x".repeat(1023)),
        "\u{600}a\u{301}\tلا".to_owned(),
        "\u{301}\u{200b}a\t👩‍💻".to_owned(),
        "control\r\u{301}".to_owned(),
    ] {
        let state = EditorState::new(text.clone());
        let boundaries: Vec<_> = text
            .grapheme_indices(true)
            .map(|(offset, _)| offset)
            .chain(std::iter::once(text.len()))
            .collect();
        for offset in boundaries.iter().copied() {
            assert_eq!(
                logical_column_at(state.snapshot(), ByteOffset(offset), width)
                    .unwrap()
                    .0,
                column_width(&text[..offset], 0, width)
            );
        }
        let max_column = column_width(&text, 0, width);
        for column in std::iter::once(0).chain(max_column.saturating_sub(8)..=max_column + 2) {
            let expected = boundaries
                .iter()
                .copied()
                .take_while(|&offset| column_width(&text[..offset], 0, width) <= column)
                .last()
                .unwrap();
            assert_eq!(
                offset_at_logical_column(state.snapshot(), 0, LogicalColumn(column), width)
                    .unwrap(),
                ByteOffset(expected)
            );
        }
    }
}
