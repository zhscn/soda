//! Fixed file workers with bounded job and completion queues. Requests retain
//! workspace reservations until completion or cancellation is reduced.
use super::{
    FileService, OpenCompletion, OpenId, OpenRequest, SaveCompletion, SaveId, SaveRequest,
};
use crate::editor::DocumentId;
use std::{
    io,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

pub enum FileTask {
    Open(OpenRequest),
    Save(Box<SaveRequest>),
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FileTaskKey {
    Open(OpenId),
    Save {
        document: DocumentId,
        request: SaveId,
    },
}
impl FileTask {
    pub fn key(&self) -> FileTaskKey {
        match self {
            Self::Open(request) => FileTaskKey::Open(request.id()),
            Self::Save(request) => FileTaskKey::Save {
                document: request.document_id(),
                request: request.id(),
            },
        }
    }
}
pub enum FileCompletion {
    Open(OpenCompletion),
    Save(SaveCompletion),
    Failed { key: FileTaskKey, error: String },
}
struct Job {
    service: FileService,
    task: FileTask,
}

pub struct FileRunner {
    sender: Option<SyncSender<Job>>,
    input: Arc<Mutex<Receiver<Job>>>,
    receiver: Receiver<FileCompletion>,
    stopped: Arc<AtomicBool>,
    workers: Vec<JoinHandle<()>>,
}
impl FileRunner {
    pub fn new() -> io::Result<Self> {
        Self::with_limits(2, 16, 16)
    }
    fn with_limits(workers: usize, jobs: usize, completions: usize) -> io::Result<Self> {
        let (sender, input) = mpsc::sync_channel::<Job>(jobs);
        let input = Arc::new(Mutex::new(input));
        let (output, receiver) = mpsc::sync_channel(completions);
        let stopped = Arc::new(AtomicBool::new(false));
        let mut runner = Self {
            sender: Some(sender),
            input: input.clone(),
            receiver,
            stopped: stopped.clone(),
            workers: vec![],
        };
        for index in 0..workers {
            let input = input.clone();
            let output = output.clone();
            let stopped = stopped.clone();
            runner.workers.push(
                thread::Builder::new()
                    .name(format!("soda-file-{index}"))
                    .spawn(move || {
                        loop {
                            let Ok(job) = input.lock().unwrap().recv() else {
                                break;
                            };
                            if stopped.load(Ordering::Acquire) {
                                drop(job);
                                continue;
                            }
                            let key = job.task.key();
                            let mut completion =
                                match catch_unwind(AssertUnwindSafe(|| match job.task {
                                    FileTask::Open(request) => {
                                        FileCompletion::Open(job.service.read_request(request))
                                    }
                                    FileTask::Save(request) => {
                                        FileCompletion::Save(job.service.write(*request))
                                    }
                                })) {
                                    Ok(completion) => completion,
                                    Err(_) => FileCompletion::Failed {
                                        key,
                                        error: "File worker task panicked".into(),
                                    },
                                };
                            loop {
                                if stopped.load(Ordering::Acquire) {
                                    drop(completion);
                                    break;
                                }
                                match output.try_send(completion) {
                                    Ok(()) => {
                                        crate::wake::wake();
                                        break;
                                    }
                                    Err(TrySendError::Disconnected(_)) => break,
                                    Err(TrySendError::Full(value)) => {
                                        completion = value;
                                        thread::sleep(Duration::from_millis(2));
                                    }
                                }
                            }
                        }
                    })?,
            );
        }
        Ok(runner)
    }
    /// Never waits for queue space. Rejected tasks drop their reservations via
    /// the normal workspace cancellation route; the owner must poll outcomes.
    pub fn submit(&mut self, service: FileService, task: FileTask) -> io::Result<()> {
        let Some(sender) = &self.sender else {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "File workers stopped",
            ));
        };
        sender
            .try_send(Job { service, task })
            .map_err(|error| match error {
                TrySendError::Full(_) => {
                    io::Error::new(io::ErrorKind::WouldBlock, "File task queue is full")
                }
                TrySendError::Disconnected(_) => {
                    io::Error::new(io::ErrorKind::BrokenPipe, "File workers stopped")
                }
            })
    }
    pub fn poll(&mut self) -> io::Result<Option<FileCompletion>> {
        match self.receiver.try_recv() {
            Ok(completion) => Ok(Some(completion)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "File workers stopped",
            )),
        }
    }
    /// Pending jobs are cancelled; active writes finish before workers join.
    /// Results abandoned during shutdown route back to their workspace.
    pub fn shutdown(&mut self) {
        self.stopped.store(true, Ordering::Release);
        self.sender.take();
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
        while self.input.lock().unwrap().try_recv().is_ok() {}
        while self.receiver.try_recv().is_ok() {}
    }
}
impl Drop for FileRunner {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        editor::Language,
        files::{FileError, Workspace},
    };
    #[test]
    fn full_queue_cancels_rejected_requests_and_shutdown_drains_backpressure() {
        let directory = tempfile::tempdir().unwrap();
        let mut workspace = Workspace::default();
        // No workers makes queue occupancy deterministic.
        let mut runner = FileRunner::with_limits(0, 1, 1).unwrap();
        let first = workspace.new_document(Language::PlainText);
        let second = workspace.new_document(Language::PlainText);
        let request = workspace
            .prepare_save(first, Some(&directory.path().join("a")))
            .unwrap();
        runner
            .submit(
                workspace.service().clone(),
                FileTask::Save(Box::new(request)),
            )
            .unwrap();
        let request = workspace
            .prepare_save(second, Some(&directory.path().join("b")))
            .unwrap();
        let rejected = request.id();
        assert_eq!(
            runner
                .submit(
                    workspace.service().clone(),
                    FileTask::Save(Box::new(request))
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::WouldBlock
        );
        let result = workspace.poll_file_results().pop().unwrap();
        assert_eq!(result.request, Some(rejected));
        assert!(matches!(result.result, Err(FileError::Cancelled)));
        runner.shutdown();
        workspace.poll_file_results();
        assert!(!workspace.is_saving(first));
        assert!(!workspace.is_saving(second));
    }
    #[test]
    fn shutdown_releases_a_worker_blocked_by_the_completion_queue() {
        let directory = tempfile::tempdir().unwrap();
        let mut workspace = Workspace::default();
        let mut runner = FileRunner::with_limits(1, 2, 1).unwrap();
        let mut documents = vec![];
        for name in ["a", "b"] {
            let document = workspace.new_document(Language::PlainText);
            let path = directory.path().join(name);
            let request = workspace.prepare_save(document, Some(&path)).unwrap();
            runner
                .submit(
                    workspace.service().clone(),
                    FileTask::Save(Box::new(request)),
                )
                .unwrap();
            documents.push(document);
        }
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !directory.path().join("b").exists() {
            assert!(std::time::Instant::now() < deadline);
            thread::sleep(Duration::from_millis(2));
        }
        runner.shutdown();
        let results = workspace.poll_file_results();
        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|result| result.result.is_ok()));
        assert!(documents.iter().all(|id| !workspace.is_saving(*id)));
    }
}
