use super::{Candidate, CandidateKey, PickerLimits, Source};
use std::{path::PathBuf, sync::Arc};

pub(super) struct Catalog {
    pub source: Arc<Source>,
    pub entries: Vec<Arc<Candidate<PathBuf>>>,
    pub truncated: bool,
    pub warnings: Vec<String>,
}
pub(super) fn collect(source: Arc<Source>) -> Result<Option<Catalog>, String> {
    let root = &source.root;
    if !root.is_absolute() {
        return Err("Picker root must be absolute".into());
    }
    if !std::fs::metadata(root)
        .map_err(|e| format!("{}: {e}", root.display()))?
        .is_dir()
    {
        return Err(format!("{}: expected a directory", root.display()));
    }
    let mut builder = ignore::WalkBuilder::new(root);
    builder
        .require_git(false)
        .parents(false)
        .git_global(false)
        .follow_links(false)
        .sort_by_file_path(|a, b| a.cmp(b));
    let mut entries = Vec::<Arc<Candidate<PathBuf>>>::new();
    let mut bytes = 0_usize;
    let mut truncated = false;
    let mut warnings = Vec::new();
    let PickerLimits {
        max_candidates,
        max_catalog_bytes,
        ..
    } = source.limits;
    for entry in builder.build() {
        if source.closed() {
            return Ok(None);
        }
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                if warnings.len() < 8 {
                    warnings.push(error.to_string());
                }
                continue;
            }
        };
        if let Some(error) = entry.error()
            && warnings.len() < 8
        {
            warnings.push(error.to_string());
        }
        // Do not follow symlinks, sockets or devices into the candidate set.
        if !entry.file_type().is_some_and(|kind| kind.is_file()) {
            continue;
        }
        let path = entry.into_path();
        let label: String = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .chars()
            .map(|ch| if ch.is_control() { '�' } else { ch })
            .collect();
        // Charge candidate storage, Arc counters and owned buffer capacities.
        // The vector is charged separately at its actual reserved capacity.
        let cost = std::mem::size_of::<Candidate<PathBuf>>()
            + 2 * std::mem::size_of::<usize>()
            + path.capacity()
            + label.capacity();
        let next_bytes = bytes.saturating_add(cost);
        let slot_bytes = std::mem::size_of::<Arc<Candidate<PathBuf>>>();
        let available_slots = max_catalog_bytes.saturating_sub(next_bytes) / slot_bytes;
        if entries.len() >= max_candidates
            || next_bytes.saturating_add(entries.capacity().saturating_mul(slot_bytes))
                > max_catalog_bytes
            || available_slots <= entries.len()
        {
            truncated = true;
            break;
        }
        if entries.len() == entries.capacity() {
            let target = entries
                .capacity()
                .saturating_mul(2)
                .max(4)
                .min(max_candidates)
                .min(available_slots);
            entries.reserve_exact(target - entries.len());
        }
        if next_bytes.saturating_add(entries.capacity().saturating_mul(slot_bytes))
            > max_catalog_bytes
        {
            return Err("Candidate allocator capacity exceeds the catalog budget".into());
        }
        bytes = next_bytes;
        entries.push(Arc::new(Candidate {
            key: CandidateKey(entries.len() as u64),
            label,
            payload: path,
        }));
    }
    if source.closed() {
        return Ok(None);
    }
    Ok(Some(Catalog {
        source,
        entries,
        truncated,
        warnings,
    }))
}
