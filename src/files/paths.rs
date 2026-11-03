//! Bounded asynchronous directory enumeration for local path dialogs.
use std::{ffi::OsString, path::PathBuf, sync::atomic::AtomicBool};
#[derive(Debug)]
pub struct DirectoryEntry {
    pub path: PathBuf,
    pub name: OsString,
    pub directory: bool,
}
pub struct PathRequest {
    pub(crate) directory: PathBuf,
    pub(crate) prefix: String,
    pub(crate) cancelled: Arc<AtomicBool>,
}
pub struct PathCompletion {
    pub(crate) cancelled: Arc<AtomicBool>,
    pub(crate) result: Result<Vec<DirectoryEntry>, String>,
}
fn enumerate(request: &PathRequest) -> Result<Vec<DirectoryEntry>, String> {
    let fail = |error| format!("{}: {error}", request.directory.display());
    let directory = std::fs::canonicalize(&request.directory).map_err(fail)?;
    let mut entries = Vec::new();
    let mut bytes = 0usize;
    for entry in std::fs::read_dir(&directory).map_err(fail)? {
        if request.cancelled.load(Ordering::Relaxed) {
            return Ok(vec![]);
        }
        let entry = entry.map_err(fail)?;
        let name = entry.file_name();
        if !name.to_string_lossy().starts_with(&request.prefix) {
            continue;
        }
        let path = entry.path();
        // Follow directory symlinks; broken links remain selectable file entries.
        let directory = match std::fs::metadata(&path) {
            Ok(metadata) => metadata.is_dir(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => false,
            Err(error) => return Err(fail(error)),
        };
        bytes = bytes.saturating_add(name.len() * 3 + path.as_os_str().len() * 3 + 256);
        if entries.len() >= 10000 || bytes > 8 * 1024 * 1024 {
            return Err(
                "Directory completion exceeds its size limit; type a narrower prefix".into(),
            );
        }
        entries.push(DirectoryEntry {
            path,
            name,
            directory,
        });
    }
    entries.sort_by(|a, b| (!a.directory, &a.name, &a.path).cmp(&(!b.directory, &b.name, &b.path)));
    Ok(entries)
}
use std::{
    io,
    sync::{
        Arc, Condvar, Mutex,
        atomic::Ordering,
        mpsc::{self, Receiver},
    },
    thread::{self, JoinHandle},
};
#[derive(Default)]
struct Mailbox {
    pending: Option<PathRequest>,
    shutdown: bool,
}
pub struct PathRunner {
    state: Arc<(Mutex<Mailbox>, Condvar)>,
    receiver: Receiver<PathCompletion>,
    worker: Option<JoinHandle<()>>,
    active: Option<Arc<AtomicBool>>,
}
impl PathRunner {
    pub fn new() -> io::Result<Self> {
        let state = Arc::new((Mutex::new(Mailbox::default()), Condvar::new()));
        let shared = state.clone();
        let (sender, receiver) = mpsc::sync_channel(1);
        let worker = thread::Builder::new()
            .name("soda-paths".into())
            .spawn(move || {
                loop {
                    let request = {
                        let (lock, wake) = &*shared;
                        let mut mailbox = lock.lock().unwrap();
                        while mailbox.pending.is_none() && !mailbox.shutdown {
                            mailbox = wake.wait(mailbox).unwrap();
                        }
                        if mailbox.shutdown {
                            break;
                        }
                        mailbox.pending.take().unwrap()
                    };
                    if request.cancelled.load(Ordering::Relaxed) {
                        continue;
                    }
                    let completion = PathCompletion {
                        result: enumerate(&request),
                        cancelled: request.cancelled.clone(),
                    };
                    // Output never blocks shutdown. Keep the live result until the owner
                    // drains an older completion, checking cancellation between attempts.
                    let mut completion = completion;
                    loop {
                        if completion.cancelled.load(Ordering::Relaxed)
                            || shared.0.lock().unwrap().shutdown
                        {
                            break;
                        }
                        match sender.try_send(completion) {
                            Ok(()) => {
                                crate::wake::wake();
                                break;
                            }
                            Err(mpsc::TrySendError::Full(value)) => {
                                completion = value;
                                thread::park_timeout(std::time::Duration::from_millis(2));
                            }
                            Err(mpsc::TrySendError::Disconnected(_)) => return,
                        }
                    }
                }
            })?;
        Ok(Self {
            state,
            receiver,
            worker: Some(worker),
            active: None,
        })
    }
    pub fn submit(&mut self, request: PathRequest) {
        if let Some(old) = self.active.replace(request.cancelled.clone()) {
            old.store(true, Ordering::Relaxed);
        }
        let (lock, wake) = &*self.state;
        let mut mailbox = lock.lock().unwrap();
        if let Some(old) = mailbox.pending.replace(request) {
            old.cancelled.store(true, Ordering::Relaxed);
        }
        wake.notify_one();
    }
    pub fn poll(&mut self) -> Option<PathCompletion> {
        self.receiver.try_recv().ok()
    }
}
impl Drop for PathRunner {
    fn drop(&mut self) {
        if let Some(token) = self.active.take() {
            token.store(true, Ordering::Relaxed);
        }
        {
            let mut mailbox = self.state.0.lock().unwrap();
            mailbox.shutdown = true;
            if let Some(request) = mailbox.pending.take() {
                request.cancelled.store(true, Ordering::Relaxed);
            }
        }
        self.state.1.notify_one();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(directory: PathBuf, prefix: &str) -> PathRequest {
        PathRequest {
            directory,
            prefix: prefix.into(),
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }
    #[test]
    fn enumerates_one_level_including_hidden_names_and_directory_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::create_dir(temp.path().join("src")).unwrap();
        std::fs::write(temp.path().join("src/nested"), "").unwrap();
        std::fs::write(temp.path().join(".hidden"), "").unwrap();
        std::fs::write(temp.path().join("file"), "").unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(temp.path().join("src"), temp.path().join("linked"))
                .unwrap();
            std::os::unix::fs::symlink(temp.path().join("missing"), temp.path().join("broken"))
                .unwrap();
        }
        let entries = enumerate(&request(temp.path().to_owned(), "")).unwrap();
        assert!(!entries.iter().any(|entry| entry.name == ".."));
        assert!(entries.iter().any(|entry| entry.name == ".hidden"));
        assert!(!entries.iter().any(|entry| entry.name == "nested"));
        #[cfg(unix)]
        {
            assert!(
                entries
                    .iter()
                    .any(|entry| entry.name == "linked" && entry.directory)
            );
            assert!(
                entries
                    .iter()
                    .any(|entry| entry.name == "broken" && !entry.directory)
            );
        }
        let entries = enumerate(&request(temp.path().to_owned(), "fi")).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "file");
    }
    #[test]
    fn cancelled_reads_and_missing_directories_have_distinct_results() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::write(temp.path().join("x"), "").unwrap();
        let r = request(temp.path().to_owned(), "");
        r.cancelled.store(true, Ordering::Relaxed);
        assert!(enumerate(&r).unwrap().is_empty());
        assert!(
            enumerate(&request(temp.path().join("missing"), ""))
                .unwrap_err()
                .contains("missing")
        );
    }
    #[test]
    fn worker_output_backpressure_does_not_block_shutdown() {
        let temp = tempfile::tempdir().unwrap();
        let mut runner = PathRunner::new().unwrap();
        let first = request(temp.path().to_owned(), "");
        runner.submit(first);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while runner.receiver.try_iter().next().is_none() {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        runner.submit(request(temp.path().to_owned(), ""));
        std::thread::sleep(std::time::Duration::from_millis(10));
        runner.submit(request(temp.path().to_owned(), ""));
        drop(runner);
    }
}
