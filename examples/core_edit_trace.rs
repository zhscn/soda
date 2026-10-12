//! A parser-free edit trace for timing the core and observing process memory.
use soda::core::{Change, Editor, Transaction};
use std::{error::Error, time::Instant};

fn main() -> Result<(), Box<dyn Error>> {
    let edits: usize = std::env::args()
        .nth(1)
        .map(|arg| arg.parse())
        .transpose()?
        .unwrap_or(256);
    let source = "int value;\n".repeat(100_000);
    let mut editor = Editor::new(source.clone());
    let mut length = source.len();
    let started = Instant::now();
    for step in 0..edits {
        let position = match step % 3 {
            0 => 0,
            1 => source.len() / 2,
            _ => length,
        };
        let tx = Transaction::new(
            editor.state().snapshot().version(),
            vec![Change::new(position..position, "x")],
        );
        editor.dispatch(tx)?;
        length += 1;
    }
    let elapsed = started.elapsed();
    assert_eq!(editor.state().snapshot().text().len(), length);
    for _ in 0..edits {
        assert!(editor.undo()?);
    }
    assert_eq!(editor.state().snapshot().text(), source);
    println!(
        "bytes={} edits={} edit_us={}",
        source.len(),
        edits,
        elapsed.as_micros()
    );
    Ok(())
}
