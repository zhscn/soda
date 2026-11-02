//! Owner-thread picker state and typed tasks. Workers never mutate widgets or
//! editors; completions are accepted only by their live request identity.
mod list;
mod matching;
pub(crate) use matching::fuzzy_match;
mod source;
mod worker;
pub use list::{Candidate, CandidateKey, CandidateListState, ListMotion, MatchedCandidate};
use std::{
    io,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    task::Waker,
};
pub use worker::PickerRunner;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PickerId(u64);
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SourceKey {
    pub session: PickerId,
    pub generation: u64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RequestKey {
    pub source: SourceKey,
    pub query_generation: u64,
}
pub const MAX_QUERY_BYTES: usize = 4096;
// With the path scorer's maximum per-character bonus, 2048 matched graphemes
// leave headroom in its u16 score. Byte length alone does not bound the score.
pub const MAX_QUERY_GRAPHEMES: usize = 2048;
pub(super) fn validate_query(text: &str) -> Result<(), &'static str> {
    use unicode_segmentation::UnicodeSegmentation;
    if text.len() > MAX_QUERY_BYTES {
        return Err("Query exceeds 4096 bytes");
    }
    if text.graphemes(true).take(MAX_QUERY_GRAPHEMES + 1).count() > MAX_QUERY_GRAPHEMES {
        return Err("Query exceeds 2048 graphemes");
    }
    Ok(())
}
#[derive(Clone, Copy, Debug)]
pub struct PickerLimits {
    pub max_candidates: usize,
    pub max_catalog_bytes: usize,
    pub max_results: usize,
}
impl Default for PickerLimits {
    fn default() -> Self {
        Self {
            max_candidates: 100_000,
            max_catalog_bytes: 64 * 1024 * 1024,
            max_results: 1000,
        }
    }
}
struct Source {
    key: SourceKey,
    root: PathBuf,
    limits: PickerLimits,
    closed: AtomicBool,
    query_generation: AtomicU64,
    waker: Mutex<Option<Waker>>,
}
impl Source {
    fn close(&self) {
        self.closed.store(true, Ordering::Relaxed);
        if let Some(waker) = self.waker.lock().unwrap().take() {
            waker.wake();
        }
    }
    fn bind_waker(&self, waker: Waker) {
        *self.waker.lock().unwrap() = Some(waker);
    }

    fn closed(&self) -> bool {
        self.closed.load(Ordering::Relaxed)
    }
}
#[derive(Clone)]
pub struct PickerTask {
    key: RequestKey,
    query: String,
    source: Arc<Source>,
}
impl PickerTask {
    pub fn key(&self) -> RequestKey {
        self.key
    }
    pub fn query(&self) -> &str {
        &self.query
    }
    pub fn obsolete(&self) -> bool {
        self.source.closed()
            || self.source.query_generation.load(Ordering::Relaxed) != self.key.query_generation
    }
}
pub enum PickerEffect {
    Run(PickerTask),
    Cancel(PickerId),
}
#[derive(Debug)]
pub struct PickerResults<T> {
    pub rows: Vec<MatchedCandidate<T>>,
    pub matched: usize,
    pub truncated: bool,
}
impl<T> Default for PickerResults<T> {
    fn default() -> Self {
        Self {
            rows: Vec::new(),
            matched: 0,
            truncated: false,
        }
    }
}
/// A completion replaces the whole result list; only the first for the
/// session's current request identity is taken.
pub struct PickerCompletion {
    pub key: RequestKey,
    pub result: Result<PickerResults<PathBuf>, String>,
}
#[derive(Debug)]
pub enum PickerStatus {
    Loading,
    Ready,
    Failed(String),
}
pub struct PickerSession {
    query: String,
    source: Arc<Source>,
    key: RequestKey,
    results: PickerResults<PathBuf>,
    /// The current request has its results.
    answered: bool,
    status: PickerStatus,
}
impl PickerSession {
    pub fn new(root: PathBuf, limits: PickerLimits) -> io::Result<Self> {
        static NEXT: Mutex<u64> = Mutex::new(1);
        if !root.is_absolute()
            || limits.max_candidates == 0
            || limits.max_catalog_bytes == 0
            || limits.max_results == 0
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Picker requires an absolute root and positive limits",
            ));
        }
        let id = {
            let mut next = NEXT.lock().unwrap();
            let id = *next;
            *next = next
                .checked_add(1)
                .ok_or_else(|| io::Error::other("Picker identities exhausted"))?;
            id
        };
        let key = RequestKey {
            source: SourceKey {
                session: PickerId(id),
                generation: 0,
            },
            query_generation: 0,
        };
        Ok(Self {
            query: String::new(),
            source: Arc::new(Source {
                key: key.source,
                root,
                limits,
                closed: AtomicBool::new(false),
                query_generation: AtomicU64::new(0),
                waker: Mutex::new(None),
            }),
            key,
            results: PickerResults::default(),
            answered: false,
            status: PickerStatus::Loading,
        })
    }
    pub fn id(&self) -> PickerId {
        self.key.source.session
    }
    pub fn key(&self) -> RequestKey {
        self.key
    }
    pub fn results(&self) -> &PickerResults<PathBuf> {
        &self.results
    }
    pub fn status(&self) -> &PickerStatus {
        &self.status
    }
    pub fn task(&self) -> PickerTask {
        PickerTask {
            key: self.key,
            query: self.query.clone(),
            source: self.source.clone(),
        }
    }
    /// Replaces the query; returns the matching task when it is valid.
    pub(super) fn set_query(&mut self, text: &str) -> Option<PickerTask> {
        if self.query == text {
            return None;
        }
        self.query = text.into();
        self.key.query_generation = self
            .key
            .query_generation
            .checked_add(1)
            .expect("Picker query generations exhausted");
        self.source
            .query_generation
            .store(self.key.query_generation, Ordering::Relaxed);
        self.results = PickerResults::default();
        self.answered = false;
        if let Err(error) = validate_query(&self.query) {
            self.status = PickerStatus::Failed(error.into());
            None
        } else {
            self.status = PickerStatus::Loading;
            Some(self.task())
        }
    }
    pub fn change_source(&mut self, root: PathBuf) -> io::Result<PickerTask> {
        if !root.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Picker root must be absolute",
            ));
        }
        let next = self
            .key
            .source
            .generation
            .checked_add(1)
            .ok_or_else(|| io::Error::other("Picker source generations exhausted"))?;
        self.source.close();
        self.key.source.generation = next;
        self.source = Arc::new(Source {
            key: self.key.source,
            root,
            limits: self.source.limits,
            closed: AtomicBool::new(false),
            query_generation: AtomicU64::new(self.key.query_generation),
            waker: Mutex::new(None),
        });
        self.results = PickerResults::default();
        self.answered = false;
        self.status = PickerStatus::Loading;
        Ok(self.task())
    }
    pub fn accept(&mut self, completion: PickerCompletion) -> bool {
        if completion.key != self.key || self.source.closed() || self.answered {
            return false;
        }
        self.answered = true;
        match completion.result {
            Ok(results) => {
                self.results = results;
                self.status = PickerStatus::Ready;
            }
            Err(error) => self.fail(error),
        }
        true
    }
    pub(super) fn fail(&mut self, error: String) {
        // A rebuilt catalog is a new source lifetime: discovery-local candidate
        // keys must never be reused as identities for a previous catalog.
        let root = self.source.root.clone();
        match self.change_source(root) {
            Ok(_) => self.status = PickerStatus::Failed(error),
            Err(reset_error) => {
                self.source.close();
                self.results = PickerResults::default();
                self.status = PickerStatus::Failed(format!("{error}; {reset_error}"));
            }
        }
    }
}
impl Drop for PickerSession {
    fn drop(&mut self) {
        self.source.close();
    }
}
