use soda::{
    config::{ConfigOptions, resolve_config},
    core::EditorState,
    cpp::{compute_indent, parse_snapshot_with_options},
};
use std::{error::Error, path::Path};

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        return Err("usage: cargo run --example inspect_indent -- <file> <1-based-line>".into());
    }
    let line: usize = args[1].parse()?;
    let line = line.checked_sub(1).ok_or("line numbers start at one")?;
    let config = resolve_config(Path::new(&args[0]), &ConfigOptions::default())?;
    let state = EditorState::new(std::fs::read_to_string(&args[0])?);
    let tree = parse_snapshot_with_options(state.snapshot(), config.config.rules.parser_options());
    let decision = compute_indent(state.snapshot(), &tree, line, &config.config.rules)?;
    for source in &config.sources {
        eprintln!("config: {}", source.path.display());
    }
    for diagnostic in &config.config.diagnostics {
        eprintln!("{}: {}", diagnostic.option, diagnostic.message);
    }
    println!("{decision:#?}");
    Ok(())
}
