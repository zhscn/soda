//! Waking the frontend's loop when something ready for `Runtime::poll`
//! arrives from another thread: a file read, a language server's message,
//! a search's matches. The loop waits for input, a wake or the runtime's
//! next deadline, and polls; nothing polls on a schedule.
//!
//! There is one loop in a process, so the waker is the process's. Without
//! one, as in tests, waking does nothing.
use std::sync::Mutex;

type Waker = Box<dyn Fn() + Send + Sync>;
static WAKER: Mutex<Option<Waker>> = Mutex::new(None);

/// What wakes the loop from now on.
pub(crate) fn set(waker: impl Fn() + Send + Sync + 'static) {
    *WAKER.lock().unwrap_or_else(|e| e.into_inner()) = Some(Box::new(waker));
}
/// Wakes the loop; call after handing over something to poll.
pub(crate) fn wake() {
    if let Some(waker) = &*WAKER.lock().unwrap_or_else(|e| e.into_inner()) {
        waker();
    }
}
