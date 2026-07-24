#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda runtime))

(define runtime (make-runtime))
(define timer (runtime-start-timer! runtime 1 0))
(define events (runtime-poll! runtime))

(unless (= (length events) 1)
  (error 'runtime-tests "expected one event" events))

(let ([event (car events)])
  (unless (eq? (event-kind event) 'timer)
    (error 'runtime-tests "expected timer event" event))
  (unless (= (event-source event) timer)
    (error 'runtime-tests "timer source differs" event))
  (unless (zero? (event-status event))
    (error 'runtime-tests "timer failed" event))
  (unless (zero? (bytevector-length (event-data event)))
    (error 'runtime-tests "timer returned data" event)))

(define test-file (getenv "SODA_TEST_FILE"))
(define file-read (runtime-read-file! runtime test-file))
(define file-events (runtime-poll! runtime))

(unless (= (length file-events) 1)
  (error 'runtime-tests "expected one file event" file-events))

(let ([event (car file-events)])
  (unless (eq? (event-kind event) 'file-read)
    (error 'runtime-tests "expected file-read event" event))
  (unless (= (event-source event) file-read)
    (error 'runtime-tests "file source differs" event))
  (unless (zero? (event-status event))
    (error 'runtime-tests "file read failed" event))
  (unless (positive? (bytevector-length (event-data event)))
    (error 'runtime-tests "file read returned no data" event)))

(runtime-close! runtime)
