//! Owner-thread picker state and typed tasks. Workers never mutate widgets or
//! editors; completions are accepted only by their live request identity.
mod list;
mod matching;
mod source;
mod worker;
use super::TextInput;
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
    pub catalog_count: usize,
    pub truncated: bool,
    pub warnings: Vec<String>,
}
impl<T> Default for PickerResults<T> {
    fn default() -> Self {
        Self {
            rows: Vec::new(),
            matched: 0,
            catalog_count: 0,
            truncated: false,
            warnings: Vec::new(),
        }
    }
}
/// Each completion replaces a whole ordered snapshot. Revisions and sequence
/// numbers order snapshots within one request; request identities are exact.
pub struct PickerCompletion {
    pub key: RequestKey,
    pub data_revision: u64,
    pub sequence: u64,
    pub result: Result<PickerResults<PathBuf>, String>,
}
#[derive(Debug)]
pub enum PickerStatus {
    Loading,
    Ready,
    Failed(String),
}
pub struct PickerSession {
    input: TextInput,
    source: Arc<Source>,
    key: RequestKey,
    results: PickerResults<PathBuf>,
    version: Option<(u64, u64)>,
    list: CandidateListState,
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
            input: TextInput::default(),
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
            version: None,
            list: CandidateListState::default(),
            status: PickerStatus::Loading,
        })
    }
    pub fn id(&self) -> PickerId {
        self.key.source.session
    }
    pub fn key(&self) -> RequestKey {
        self.key
    }
    pub fn input(&self) -> &TextInput {
        &self.input
    }
    pub(super) fn input_mut(&mut self) -> &mut TextInput {
        &mut self.input
    }
    pub fn results(&self) -> &PickerResults<PathBuf> {
        &self.results
    }
    pub fn list(&self) -> &CandidateListState {
        &self.list
    }
    pub fn status(&self) -> &PickerStatus {
        &self.status
    }
    pub fn task(&self) -> PickerTask {
        PickerTask {
            key: self.key,
            query: self.input.text().into(),
            source: self.source.clone(),
        }
    }
    pub(super) fn query_changed(&mut self) -> Option<PickerTask> {
        self.key.query_generation = self
            .key
            .query_generation
            .checked_add(1)
            .expect("Picker query generations exhausted");
        self.source
            .query_generation
            .store(self.key.query_generation, Ordering::Relaxed);
        self.results = PickerResults::default();
        self.version = None;
        self.list.reset();
        if let Err(error) = validate_query(self.input.text()) {
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
        self.version = None;
        self.list.reset();
        self.status = PickerStatus::Loading;
        Ok(self.task())
    }
    pub fn accept(&mut self, completion: PickerCompletion) -> bool {
        let version = (completion.data_revision, completion.sequence);
        if completion.key != self.key
            || self.source.closed()
            || self.version.is_some_and(|old| version <= old)
        {
            return false;
        }
        self.version = Some(version);
        match completion.result {
            Ok(results) => {
                self.list.update(&self.results.rows, &results.rows);
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
                self.list.reset();
                self.status = PickerStatus::Failed(format!("{error}; {reset_error}"));
            }
        }
    }
    pub fn resize(&mut self, rows: usize) -> bool {
        self.list.resize(&self.results.rows, rows)
    }
    pub fn navigate(&mut self, motion: ListMotion, wrap: bool) -> bool {
        self.list.navigate(&self.results.rows, motion, wrap)
    }
    pub fn selected_path(&self) -> Option<&std::path::Path> {
        self.list
            .index(&self.results.rows)
            .map(|index| self.results.rows[index].candidate.payload.as_path())
    }
}
impl Drop for PickerSession {
    fn drop(&mut self) {
        self.source.close();
    }
}
