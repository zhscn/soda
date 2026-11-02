//! Reindent every non-blank line of formatted C++ sources and compare the
//! advice with the indentation already in the file. Sources formatted by
//! clang-format with their `.clang-format` measure agreement with it.
//!
//! cargo run --release --example indent_accuracy -- [--show N] <file-or-dir>...
use soda::{
    files::{FileService, Workspace},
    language::IndentAdvice,
};
use std::{error::Error, path::PathBuf};

fn sources(path: PathBuf, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    if !path.is_dir() {
        out.push(path);
        return Ok(());
    }
    let mut entries: Vec<_> = std::fs::read_dir(path)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<_, _>>()?;
    entries.sort();
    for entry in entries {
        if entry.is_dir()
            || entry
                .extension()
                .is_some_and(|ext| ["h", "hpp", "cc", "cpp"].contains(&&*ext.to_string_lossy()))
        {
            sources(entry, out)?;
        }
    }
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args().skip(1).peekable();
    let mut show = 0;
    if args.peek().is_some_and(|arg| arg == "--show") {
        args.next();
        show = args.next().ok_or("--show needs a count")?.parse()?;
    }
    let mut paths = Vec::new();
    for arg in args {
        sources(arg.into(), &mut paths)?;
    }
    if paths.is_empty() {
        return Err("usage: indent_accuracy [--show N] <file-or-dir>...".into());
    }
    let (mut matched, mut mismatched, mut preserved, mut unavailable) = (0, 0, 0, 0);
    // Why lines were left as they are, by the role the analysis gave them.
    let mut kept = std::collections::BTreeMap::<String, usize>::new();
    for path in paths {
        let mut workspace = Workspace::new(FileService::default());
        let Ok(id) = workspace.open(&path) else {
            continue;
        };
        let snapshot = workspace
            .editor(id)
            .unwrap()
            .model()
            .document()
            .snapshot()
            .clone();
        let rules = soda::config::resolve_config(&path, &soda::config::ConfigOptions::default())
            .ok()
            .map(|config| config.config.rules);
        let tree = rules
            .as_ref()
            .map(|rules| soda::cpp::parse_snapshot_with_options(&snapshot, rules.parser_options()));
        let mut editor = workspace.editor_mut(id).unwrap();
        for line in 0..snapshot.line_count() {
            let text = snapshot.line(line).unwrap();
            if text.trim().is_empty() {
                continue;
            }
            let actual = &text[..text.len() - text.trim_start_matches([' ', '\t']).len()];
            match editor.indentation(line)? {
                IndentAdvice::Set { prefix, .. } if prefix == actual => matched += 1,
                IndentAdvice::Set { prefix, .. } => {
                    mismatched += 1;
                    if show > 0 {
                        show -= 1;
                        println!(
                            "{}:{}: want {} got {} | {}",
                            path.display(),
                            line + 1,
                            actual.len(),
                            prefix.len(),
                            text.trim()
                        );
                    }
                }
                IndentAdvice::Preserve { .. } => {
                    preserved += 1;
                    if let (Some(rules), Some(tree)) = (&rules, &tree)
                        && let Ok(decision) =
                            soda::cpp::compute_indent(&snapshot, tree, line, rules)
                    {
                        *kept.entry(format!("{:?}", decision.role)).or_default() += 1;
                    }
                }
                IndentAdvice::Unavailable => unavailable += 1,
            }
        }
    }
    let total = matched + mismatched + preserved + unavailable;
    let percent = |count: usize| count as f64 * 100.0 / total.max(1) as f64;
    println!("lines       {total}");
    println!("match       {matched} ({:.2}%)", percent(matched));
    println!("mismatch    {mismatched} ({:.2}%)", percent(mismatched));
    println!("preserve    {preserved} ({:.2}%)", percent(preserved));
    println!("unavailable {unavailable} ({:.2}%)", percent(unavailable));
    for (role, count) in &kept {
        println!("  preserved as {role}: {count}");
    }
    Ok(())
}
