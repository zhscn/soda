use soda::core::{Association, Change, EditorState, Transaction, compose_changes};

#[test]
fn sequential_edits_preserve_untouched_ranges_and_modify_inserted_text() {
    let state = EditorState::new("ab界cd");
    let first = vec![Change::new(1..1, "XY"), Change::new(7..7, "!")];
    let second = vec![Change::new(2..3, "文"), Change::new(0..0, " ")];
    let changes = compose_changes(state.snapshot(), &first, &second).unwrap();
    let (result, map) = state.apply(Transaction::new(0, changes)).unwrap();
    assert_eq!(result.snapshot().text(), " aX文b界cd!");
    assert_eq!(map.map_tracked(2, Association::After), Some(7));
}

#[test]
fn composition_matches_sequential_utf8_edits_on_random_ranges() {
    let mut seed = 42_u64;
    let mut next = |max: usize| {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        (seed as usize) % max
    };
    let replacements = ["", "x", "界", "\t\r\n", "αβ"];
    for _ in 0..600 {
        let state = EditorState::new("ab界\r\nα\tcd");
        let boundaries: Vec<_> = (0..=state.snapshot().len_bytes())
            .filter(|&p| state.snapshot().is_char_boundary(p))
            .collect();
        let a = next(boundaries.len());
        let b = next(boundaries.len());
        let first = vec![Change::new(
            boundaries[a.min(b)]..boundaries[a.max(b)],
            replacements[next(replacements.len())],
        )];
        let (middle, _) = state.apply(Transaction::new(0, first.clone())).unwrap();
        let boundaries: Vec<_> = (0..=middle.snapshot().len_bytes())
            .filter(|&p| middle.snapshot().is_char_boundary(p))
            .collect();
        let a = next(boundaries.len());
        let b = next(boundaries.len());
        let second = vec![Change::new(
            boundaries[a.min(b)]..boundaries[a.max(b)],
            replacements[next(replacements.len())],
        )];
        let (expected, _) = middle.apply(Transaction::new(1, second.clone())).unwrap();
        let composed = compose_changes(state.snapshot(), &first, &second).unwrap();
        let (result, _) = state.apply(Transaction::new(0, composed)).unwrap();
        assert_eq!(result.snapshot().text(), expected.snapshot().text());
    }
}

#[test]
fn composition_rejects_invalid_second_coordinates_and_tracks_deleted_positions() {
    let state = EditorState::new("abcdef");
    assert!(
        compose_changes(
            state.snapshot(),
            &[Change::new(0..6, "界")],
            &[Change::new(1..2, "")]
        )
        .is_err()
    );
    let (_, map) = state
        .apply(Transaction::new(0, vec![Change::new(1..4, "X")]))
        .unwrap();
    assert_eq!(map.map_tracked(2, Association::After), None);
    assert_eq!(map.map_tracked(4, Association::After), Some(2));
}
