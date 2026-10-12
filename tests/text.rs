use soda::core::{Change, EditorState, Snapshot, Transaction};

fn check(snapshot: &Snapshot, expected: &str) {
    assert_eq!(snapshot.len_bytes(), expected.len());
    assert_eq!(snapshot.is_empty(), expected.is_empty());
    assert_eq!(snapshot.chunks().collect::<String>(), expected);
    let mut starts = vec![0];
    starts.extend(expected.match_indices('\n').map(|(offset, _)| offset + 1));
    assert_eq!(snapshot.line_count(), starts.len());
    for (line, &start) in starts.iter().enumerate() {
        let end = starts.get(line + 1).copied().unwrap_or(expected.len());
        let text = &expected[start..end];
        let content = match text.strip_suffix('\n') {
            Some(text) => text.strip_suffix('\r').unwrap_or(text),
            None => text,
        };
        assert_eq!(snapshot.line_start(line), Some(start));
        assert_eq!(snapshot.line_range(line), Some(start..end));
        assert_eq!(
            snapshot.line_content_range(line),
            Some(start..start + content.len())
        );
        assert_eq!(snapshot.line(line).as_deref(), Some(content));
        assert_eq!(snapshot.byte_slice(start..end).unwrap(), text);
    }
    assert!(snapshot.line(starts.len()).is_none());
    assert!(snapshot.line_start(usize::MAX).is_none());
    let mut line = 0;
    for offset in 0..=expected.len() {
        if offset > 0 && expected.as_bytes()[offset - 1] == b'\n' {
            line += 1;
        }
        assert_eq!(
            snapshot.is_char_boundary(offset),
            expected.is_char_boundary(offset)
        );
        assert_eq!(
            snapshot.line_of(offset),
            expected.is_char_boundary(offset).then_some(line)
        );
    }
    assert!(snapshot.line_of(expected.len() + 1).is_none());
}

#[test]
fn line_and_byte_contracts_cover_empty_text_crlf_and_chunk_boundaries() {
    for input in [
        "",
        "\n",
        "\r\n",
        "a\r",
        "a\rb",
        "a\u{2028}b\u{85}c",
        "界\r\n\t\n",
        "a\0b",
    ] {
        check(EditorState::new(input).snapshot(), input);
    }
    let input = format!("{}\r\n{}\n", "界e\u{301}".repeat(2048), "\t🦀".repeat(2048));
    let state = EditorState::new(input.clone());
    assert!(state.snapshot().chunks().count() > 1);
    check(state.snapshot(), &input);
}

#[test]
fn batched_rope_edits_match_string_reference_and_leave_old_snapshots_unchanged() {
    let mut expected = "a界\t🦀\r\n".repeat(256);
    let mut state = EditorState::new(expected.clone());
    let mut retained = Vec::new();
    let mut seed = 81723645u64;
    let mut next = || {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        (seed >> 32) as usize
    };
    let inserts = [
        "", "x", "界", "🦀", "\r", "\n", "\r\n", "e\u{301}", "\u{2028}",
    ];
    for step in 0..300 {
        if step % 60 == 0 {
            retained.push((state.snapshot().clone(), expected.clone()));
        }
        let positions: Vec<_> = expected
            .char_indices()
            .map(|(offset, _)| offset)
            .chain(std::iter::once(expected.len()))
            .collect();
        let mut cuts = [
            next() % positions.len(),
            next() % positions.len(),
            next() % positions.len(),
            next() % positions.len(),
        ];
        cuts.sort_unstable();
        let first = if step % 31 == 0 {
            "界x\r\n".repeat(400)
        } else {
            inserts[next() % inserts.len()].to_owned()
        };
        let mut changes = vec![Change::new(positions[cuts[0]]..positions[cuts[1]], first)];
        if cuts[0] != cuts[2] {
            changes.push(Change::new(
                positions[cuts[2]]..positions[cuts[3]],
                inserts[next() % inserts.len()],
            ));
        }
        for change in changes.iter().rev() {
            expected.replace_range(change.range.clone(), &change.insert);
        }
        // The transaction accepts unsorted changes in the same base coordinates.
        changes.reverse();
        let tx = Transaction::new(state.snapshot().version(), changes);
        state = state.apply(tx).unwrap().0;
        check(state.snapshot(), &expected);
    }
    for (snapshot, text) in retained {
        check(&snapshot, &text);
    }
}
