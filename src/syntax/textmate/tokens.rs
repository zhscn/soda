//! A document's TextMate results, shared between the language session that
//! asks about them and the frontend that draws them. Clones are cheap and
//! share one cache, which brings itself up to date with the snapshot of each
//! request; that is why speculative language sessions can hold them too.
//! Grammars compile once, on the first request that needs them.
use super::{Lines, Registry};
use crate::{
    core::Snapshot,
    language::ItemKind,
    syntax::{Category, Runs},
};
use std::{
    ops::Range,
    sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError},
    time::Duration,
};

/// Scanning time an edit may wait for, in a large file not scanned yet.
const QUERY_BUDGET: Duration = Duration::from_millis(16);

fn registry() -> MutexGuard<'static, Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY
        .get_or_init(|| Mutex::new(Registry::bundled()))
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}
enum Cache {
    /// Nothing asked yet.
    Waiting,
    Ready(Lines),
    /// The grammar failed to load.
    Failed,
}
#[derive(Clone)]
pub struct Tokens {
    scope: Arc<str>,
    cache: Arc<Mutex<Cache>>,
}
impl Tokens {
    pub fn new(scope: &str) -> Self {
        Self {
            scope: scope.into(),
            cache: Arc::new(Mutex::new(Cache::Waiting)),
        }
    }
    fn with<T>(
        &self,
        snapshot: &Snapshot,
        ask: impl FnOnce(&mut Lines, &mut Registry) -> T,
    ) -> Option<T> {
        let mut cache = self.cache.lock().unwrap_or_else(PoisonError::into_inner);
        let mut registry = registry();
        if matches!(*cache, Cache::Waiting) {
            *cache = match registry.grammar(&self.scope) {
                Some(grammar) => Cache::Ready(Lines::new(&registry, grammar)),
                None => Cache::Failed,
            };
        }
        let Cache::Ready(lines) = &mut *cache else {
            return None;
        };
        lines.update(snapshot);
        Some(ask(lines, &mut registry))
    }
    /// Category runs of `lines`, and whether all of them were reached:
    /// scanning stops after `budget` and later lines come back empty.
    pub fn lines(
        &self,
        snapshot: &Snapshot,
        lines: Range<usize>,
        budget: Option<Duration>,
    ) -> (Vec<Runs>, bool) {
        self.with(snapshot, |cache, registry| {
            let runs = cache.highlights_within(registry, snapshot, lines.clone(), budget);
            (runs, cache.complete(&lines, snapshot))
        })
        .unwrap_or((vec![], true))
    }
    /// The comments and strings of one line, relative to its start. A line
    /// too far to scan within `QUERY_BUDGET` has none for now.
    pub fn literals(&self, snapshot: &Snapshot, line: usize) -> Vec<(Range<usize>, ItemKind)> {
        let (runs, _) = self.lines(snapshot, line..line + 1, Some(QUERY_BUDGET));
        let mut spans: Vec<(Range<usize>, ItemKind)> = vec![];
        for (range, category) in runs.into_iter().flatten() {
            let kind = match category.root() {
                Category::Comment => ItemKind::Comment,
                Category::String | Category::Escape => ItemKind::Literal,
                _ => continue,
            };
            match spans.last_mut() {
                Some((last, same)) if *same == kind && last.end == range.start => {
                    last.end = range.end;
                }
                _ => spans.push((range, kind)),
            }
        }
        spans
    }
    /// Whether a position is inside a comment or a string; the end of a
    /// line comment or of an unfinished string counts as inside. A place
    /// too far to scan within `QUERY_BUDGET` counts as code for now.
    pub fn in_literal(&self, snapshot: &Snapshot, position: usize) -> bool {
        self.with(snapshot, |cache, registry| {
            cache.in_literal(registry, snapshot, position, Some(QUERY_BUDGET))
        })
        .unwrap_or(false)
    }
}
