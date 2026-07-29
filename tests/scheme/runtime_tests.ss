#!r6rs
(import (rnrs)
        (only (chezscheme) getenv path-last path-parent)
        (soda runtime)
        (soda vfs))

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

(define directory-scan
  (runtime-scan-directory! runtime (path-parent test-file)))
(let* ([events (runtime-poll! runtime)]
       [event (and (= (length events) 1) (car events))]
       [entries
         (and
           event
           (zero? (event-status event))
           (decode-vfs-directory-entries
             (event-data event)))]
       [test-entry
         (and
           entries
           (find
             (lambda (entry)
               (string=?
                 (vfs-entry-name entry)
                 (path-last test-file)))
             entries))])
  (unless
    (and
      event
      (= (event-source event) directory-scan)
      (eq? (event-kind event) 'directory-scan)
      test-entry
      (eq? (vfs-entry-kind test-entry) 'file))
    (error 'runtime-tests
           "directory scan did not return typed VFS entries"
           events)))

(define save-file (getenv "SODA_SAVE_TEST_FILE"))
(when (file-exists? save-file)
  (delete-file save-file))
(define expected-save-data (string->utf8 "saved λ"))
(define file-write
  (runtime-write-file! runtime save-file expected-save-data))
(define write-events (runtime-poll! runtime))

(unless (= (length write-events) 1)
  (error 'runtime-tests "expected one file write event" write-events))

(let ([event (car write-events)])
  (unless (eq? (event-kind event) 'file-write)
    (error 'runtime-tests "expected file-write event" event))
  (unless (= (event-source event) file-write)
    (error 'runtime-tests "file write source differs" event))
  (unless (zero? (event-status event))
    (error 'runtime-tests "file write failed" event))
  (unless (zero? (bytevector-length (event-data event)))
    (error 'runtime-tests "file write returned unexpected data" event)))

(define saved-read (runtime-read-file! runtime save-file))
(let ([events (runtime-poll! runtime)])
  (unless (and (= (length events) 1)
               (= (event-source (car events)) saved-read)
               (bytevector=? (event-data (car events)) expected-save-data))
    (error 'runtime-tests "saved file bytes differ" events)))
(delete-file save-file)

(define missing-file (string-append save-file ".missing"))
(when (file-exists? missing-file)
  (delete-file missing-file))
(define missing-read (runtime-read-file! runtime missing-file))
(let* ([events (runtime-poll! runtime)]
       [event (and (= (length events) 1) (car events))])
  (unless
    (and
      event
      (= (event-source event) missing-read)
      (negative? (event-status event))
      (string=? (runtime-status-name (event-status event)) "ENOENT")
      (positive?
        (string-length
          (runtime-status-message (event-status event)))))
    (error 'runtime-tests
           "runtime did not classify a missing file"
           events)))

(runtime-close! runtime)
(runtime-close! runtime)
