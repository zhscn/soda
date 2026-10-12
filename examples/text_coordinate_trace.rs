//! Rope navigation and logical-column latency on a long line, without parsing.
use soda::core::{ByteOffset, EditorState, deletion_range, logical_column_at, step_grapheme};
use std::{error::Error, hint::black_box, num::NonZeroUsize, time::Instant};
fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args().skip(1);
    let length: usize = args
        .next()
        .map(|value| value.parse())
        .transpose()?
        .unwrap_or(1_000_000);
    let samples: usize = args
        .next()
        .map(|value| value.parse())
        .transpose()?
        .unwrap_or(100);
    if length < 2 || samples == 0 {
        return Err("length must be >= 2 and samples positive".into());
    }
    let state = EditorState::new("a".repeat(length));
    let snapshot = state.snapshot();
    for forward in [false, true] {
        let started = Instant::now();
        for _ in 0..samples {
            black_box(step_grapheme(
                black_box(snapshot),
                ByteOffset(black_box(length - 1)),
                forward,
            )?);
        }
        println!(
            "step forward={forward} line_bytes={length} samples={samples} total_us={}",
            started.elapsed().as_micros()
        );
    }
    let started = Instant::now();
    for _ in 0..samples {
        black_box(deletion_range(
            black_box(snapshot),
            ByteOffset(black_box(length - 1)),
            false,
        )?);
    }
    println!(
        "delete line_bytes={length} samples={samples} total_us={}",
        started.elapsed().as_micros()
    );
    let started = Instant::now();
    for _ in 0..samples {
        black_box(logical_column_at(
            snapshot,
            ByteOffset(length - 1),
            NonZeroUsize::new(4).unwrap(),
        )?);
    }
    println!(
        "column line_bytes={length} samples={samples} total_us={}",
        started.elapsed().as_micros()
    );
    Ok(())
}
