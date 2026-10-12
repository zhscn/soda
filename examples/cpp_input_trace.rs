//! Real-file, headless input latency trace. No file is written.
use soda::{
    config::{ConfigOptions, resolve_config},
    core::Selection,
    cpp::{TokenKind, lex},
    editor::{Command, Editor},
};
use std::{error::Error, path::PathBuf, time::Instant};
fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args_os().skip(1);
    let path = PathBuf::from(args.next().ok_or("usage: cpp_input_trace FILE [SAMPLES]")?);
    let samples: usize = args
        .next()
        .map(|value| value.to_string_lossy().parse())
        .transpose()?
        .unwrap_or(20);
    if samples == 0 {
        return Err("samples must be positive".into());
    }
    let source = std::fs::read_to_string(&path)?;
    let source = source
        .strip_prefix('\u{feff}')
        .unwrap_or(&source)
        .to_owned();
    let config = resolve_config(&path, &ConfigOptions::default())?;
    let tokens = lex(&source);
    let brace = tokens
        .iter()
        .find(|token| token.kind == TokenKind::LBrace)
        .ok_or("file has no opening brace")?
        .range
        .end;
    let close = tokens
        .iter()
        .find(|token| {
            token.kind == TokenKind::RBrace
                && source[..token.range.start]
                    .rsplit('\n')
                    .next()
                    .unwrap()
                    .bytes()
                    .all(|byte| matches!(byte, b' ' | b'\t' | b'\r'))
        })
        .ok_or("file has no closing brace on its own line")?
        .range
        .start;
    let mut editor = Editor::new(source.clone(), config.config.rules);
    for (label, position, command) in [
        ("enter", brace, Command::Enter),
        ("closing", close, Command::TypeChar('}')),
        ("ordinary", brace, Command::TypeChar('x')),
    ] {
        let mut times = Vec::new();
        for _ in 0..samples {
            editor.execute(Command::SetSelection(Selection::caret(position)))?;
            let started = Instant::now();
            editor.execute(command.clone())?;
            times.push(started.elapsed().as_micros());
            editor.execute(Command::Undo)?;
            assert_eq!(editor.state().snapshot().text(), source);
        }
        times.sort_unstable();
        println!(
            "{label}: bytes={} samples={samples} median_us={} p95_us={} max_us={}",
            source.len(),
            times[times.len() / 2],
            times[(times.len() * 95).div_ceil(100).saturating_sub(1)],
            times[times.len() - 1]
        );
    }
    Ok(())
}
