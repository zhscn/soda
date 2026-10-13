//! Repeated distinct edits with analysis work counters. The source file is read
//! once; edited snapshots remain in memory and no file is written.
use soda::{
    config::{ConfigOptions, resolve_config},
    core::{Change, EditorState, Transaction},
    cpp::CppSession,
    language::{IndentRequest, IndentTrigger},
};
use std::{error::Error, path::PathBuf, sync::Arc, time::Instant};

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args_os().skip(1);
    let path = PathBuf::from(
        args.next()
            .ok_or("usage: cpp_analysis_trace FILE TARGET [SAMPLES]")?,
    );
    let target = args
        .next()
        .ok_or("missing edit target")?
        .into_string()
        .map_err(|_| "target must be UTF-8")?;
    if target.is_empty() {
        return Err("target must be nonempty".into());
    }
    let samples: usize = args
        .next()
        .map(|value| value.to_string_lossy().parse())
        .transpose()?
        .unwrap_or(20);
    if samples == 0 {
        return Err("samples must be positive".into());
    }
    let source = std::fs::read_to_string(&path)?;
    let source = source.strip_prefix('\u{feff}').unwrap_or(&source);
    let position = source.find(&target).ok_or("edit target not found")?;
    let baseline = EditorState::new(source);
    let config = resolve_config(&path, &ConfigOptions::default())?;
    let mut session = CppSession::new(Arc::new(config.config.rules));
    let request = IndentRequest {
        line: 0,
        position: 0,
        trigger: IndentTrigger::Reindent,
    };
    let started = Instant::now();
    session.indent(baseline.snapshot(), request)?;
    println!(
        "cold_us={} work={:?}",
        started.elapsed().as_micros(),
        session.analysis_work().unwrap()
    );
    let mut times = Vec::with_capacity(samples);
    for sample in 0..samples {
        let replacement = format!("{target}_probe_{sample}");
        let (edited, _) = baseline.apply(Transaction::new(
            baseline.snapshot().version(),
            vec![Change::new(position..position + target.len(), replacement)],
        ))?;
        let started = Instant::now();
        session.indent(edited.snapshot(), request)?;
        times.push(started.elapsed().as_micros());
    }
    times.sort_unstable();
    println!(
        "edit: bytes={} samples={samples} median_us={} p95_us={} max_us={} last_work={:?}",
        source.len(),
        times[times.len() / 2],
        times[(times.len() * 95).div_ceil(100).saturating_sub(1)],
        times[times.len() - 1],
        session.analysis_work().unwrap()
    );
    Ok(())
}
