//! One worker, a latest-request mailbox and a bounded completion queue.
use super::{
    PickerCompletion, PickerId, PickerTask, Source, matching,
    source::{self, Catalog},
};
use std::{
    io,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Condvar, Mutex,
        mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
    },
    task::{Wake, Waker},
    thread::{self, JoinHandle},
    time::Duration,
};

#[derive(Default)]
struct Mailbox {
    pending: Option<PickerTask>,
    clear: bool,
    shutdown: bool,
}
struct Shared {
    mailbox: Mutex<Mailbox>,
    wake: Condvar,
}
struct WorkerWake(std::sync::Weak<Shared>);
impl Wake for WorkerWake {
    fn wake(self: Arc<Self>) {
        if let Some(shared) = self.0.upgrade() {
            let _guard = shared.mailbox.lock().unwrap();
            shared.wake.notify_one();
        }
    }
}
pub struct PickerRunner {
    shared: Arc<Shared>,
    receiver: Receiver<PickerCompletion>,
    worker: Option<JoinHandle<()>>,
    active: Option<Arc<Source>>,
    waker: Waker,
    failure_reported: bool,
}
impl PickerRunner {
    pub fn new() -> io::Result<Self> {
        let (sender, receiver) = mpsc::sync_channel(4);
        let shared = Arc::new(Shared {
            mailbox: Mutex::new(Mailbox::default()),
            wake: Condvar::new(),
        });
        let state = shared.clone();
        let worker = thread::Builder::new()
            .name("soda-picker".into())
            .spawn(move || run(state, sender))?;
        let waker = Waker::from(Arc::new(WorkerWake(Arc::downgrade(&shared))));
        Ok(Self {
            shared,
            receiver,
            worker: Some(worker),
            active: None,
            waker,
            failure_reported: false,
        })
    }
    pub fn submit(&mut self, task: PickerTask) -> io::Result<()> {
        if task.obsolete() {
            return Ok(());
        }
        if self.failure_reported
            || self
                .worker
                .as_ref()
                .is_some_and(|worker| worker.is_finished())
        {
            let replacement = Self::new()?;
            if let Some(source) = self.active.take()
                && source.key != task.key.source
            {
                source.close();
            }
            *self = replacement;
        }
        task.source.bind_waker(self.waker.clone());
        if self
            .active
            .as_ref()
            .is_some_and(|source| source.key != task.key.source)
        {
            self.active.as_ref().unwrap().close();
        }
        self.active = Some(task.source.clone());
        self.shared.mailbox.lock().unwrap().pending = Some(task);
        self.shared.wake.notify_one();
        Ok(())
    }
    pub fn cancel(&mut self, id: PickerId) {
        if !self
            .active
            .as_ref()
            .is_some_and(|source| source.key.session == id)
        {
            return;
        }
        self.active.take().unwrap().close();
        let mut mailbox = self.shared.mailbox.lock().unwrap();
        mailbox.pending = None;
        mailbox.clear = true;
        self.shared.wake.notify_one();
    }
    pub fn poll(&mut self) -> io::Result<Option<PickerCompletion>> {
        match self.receiver.try_recv() {
            Ok(completion) => Ok(Some(completion)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) if !self.failure_reported => {
                self.failure_reported = true;
                Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "Picker worker stopped unexpectedly",
                ))
            }
            Err(TryRecvError::Disconnected) => Ok(None),
        }
    }
}
impl Drop for PickerRunner {
    fn drop(&mut self) {
        if let Some(source) = self.active.take() {
            source.close();
        }
        {
            let mut mailbox = self.shared.mailbox.lock().unwrap();
            mailbox.pending = None;
            mailbox.shutdown = true;
        }
        self.shared.wake.notify_one();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn publish(
    sender: &SyncSender<PickerCompletion>,
    task: &PickerTask,
    mut completion: PickerCompletion,
) {
    while !task.obsolete() {
        match sender.try_send(completion) {
            Ok(()) | Err(TrySendError::Disconnected(_)) => return,
            Err(TrySendError::Full(value)) => {
                completion = value;
                thread::sleep(Duration::from_millis(2));
            }
        }
    }
}
enum Work {
    Clear,
    Task(PickerTask),
}
type Failure = Option<(Arc<Source>, String)>;
fn compute(
    catalog: &mut Option<Catalog>,
    failure: &mut Failure,
    task: &PickerTask,
    matcher: &mut nucleo_matcher::Matcher,
) -> Option<Result<super::PickerResults<std::path::PathBuf>, String>> {
    if let Err(error) = super::validate_query(&task.query) {
        return Some(Err(error.into()));
    }
    if !catalog
        .as_ref()
        .is_some_and(|cat| cat.source.key == task.key.source)
        && !failure
            .as_ref()
            .is_some_and(|(source, _)| source.key == task.key.source)
    {
        *catalog = None;
        *failure = None;
        match source::collect(task.source.clone()) {
            Ok(Some(value)) => *catalog = Some(value),
            Ok(None) => return None,
            Err(error) => *failure = Some((task.source.clone(), error)),
        }
    }
    if task.obsolete() {
        return None;
    }
    Some(match catalog {
        Some(catalog) => Ok(matching::filter(catalog, task, matcher)?),
        None => Err(failure.as_ref().unwrap().1.clone()),
    })
}
fn run(shared: Arc<Shared>, sender: SyncSender<PickerCompletion>) {
    let mut catalog: Option<Catalog> = None;
    let mut failure: Failure = None;
    let new_matcher =
        || nucleo_matcher::Matcher::new(nucleo_matcher::Config::DEFAULT.match_paths());
    let mut matcher = new_matcher();
    loop {
        let work = {
            let mut mailbox = shared.mailbox.lock().unwrap();
            loop {
                if mailbox.shutdown {
                    return;
                }
                if mailbox.clear
                    || catalog.as_ref().is_some_and(|cat| cat.source.closed())
                    || failure.as_ref().is_some_and(|(source, _)| source.closed())
                {
                    mailbox.clear = false;
                    break Work::Clear;
                }
                if let Some(task) = mailbox.pending.take() {
                    break Work::Task(task);
                }
                mailbox = shared.wake.wait(mailbox).unwrap();
            }
        };
        let task = match work {
            Work::Clear => {
                catalog = None;
                failure = None;
                continue;
            }
            Work::Task(task) => task,
        };
        if task.source.closed() {
            continue;
        }
        let result = match catch_unwind(AssertUnwindSafe(|| {
            compute(&mut catalog, &mut failure, &task, &mut matcher)
        })) {
            Ok(Some(result)) => result,
            Ok(None) => continue,
            Err(_) => {
                catalog = None;
                failure = None;
                matcher = new_matcher();
                Err("Picker task failed unexpectedly".into())
            }
        };
        publish(
            &sender,
            &task,
            PickerCompletion {
                key: task.key,
                data_revision: 0,
                sequence: 0,
                result,
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interaction::picker::{PickerLimits, PickerResults, PickerSession};
    #[test]
    fn cancellation_interrupts_completion_backpressure() {
        let directory = tempfile::tempdir().unwrap();
        let session = PickerSession::new(directory.path().into(), PickerLimits::default()).unwrap();
        let task = session.task();
        let (sender, receiver) = mpsc::sync_channel(1);
        let packet = |sequence| PickerCompletion {
            key: task.key(),
            data_revision: 0,
            sequence,
            result: Ok(PickerResults::default()),
        };
        sender.send(packet(0)).unwrap();
        let pending = packet(1);
        let (done, finished) = mpsc::channel();
        let (started, running) = mpsc::channel();
        let worker = thread::spawn(move || {
            started.send(()).unwrap();
            publish(&sender, &task, pending);
            done.send(()).unwrap();
        });
        running.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(matches!(
            finished.recv_timeout(Duration::from_millis(20)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        drop(session);
        finished.recv_timeout(Duration::from_secs(2)).unwrap();
        worker.join().unwrap();
        assert_eq!(receiver.try_recv().unwrap().sequence, 0);
        assert!(receiver.try_recv().is_err());
    }
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    use crate::interaction::picker::{PickerLimits, PickerSession};
    #[test]
    fn disconnected_worker_is_reported_once_and_next_request_restarts_it() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("a"), "").unwrap();
        let session = PickerSession::new(root.path().into(), PickerLimits::default()).unwrap();
        let mut runner = PickerRunner::new().unwrap();
        runner.shared.mailbox.lock().unwrap().shutdown = true;
        runner.shared.wake.notify_one();
        runner.worker.take().unwrap().join().unwrap();
        assert_eq!(
            runner.poll().err().unwrap().kind(),
            io::ErrorKind::BrokenPipe
        );
        assert!(runner.poll().unwrap().is_none());
        runner.submit(session.task()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(completion) = runner.poll().unwrap() {
                assert_eq!(completion.result.unwrap().matched, 1);
                break;
            }
            assert!(std::time::Instant::now() < deadline);
            thread::sleep(Duration::from_millis(1));
        }
    }
}
