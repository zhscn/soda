(library (soda runtime)
  (export make-runtime
          runtime?
          runtime-close!
          runtime-poll!
          runtime-poll-nowait!
          runtime-start-timer!
          runtime-watch-fd!
          runtime-read-file!
          runtime-cancel!
          event?
          event-kind
          event-source
          event-status
          event-flags
          event-data
          fd-readable
          fd-writable)
  (import (chezscheme))

  (define shared-library
    (let ([path (or (getenv "SODA_RUNTIME_LIBRARY") "libsoda_runtime.so")])
      (load-shared-object path)
      path))

  (define %runtime-create
    (foreign-procedure __atomic "soda_runtime_create" () void*))
  (define %runtime-destroy
    (foreign-procedure __atomic "soda_runtime_destroy" (void*) void))
  (define %start-timer
    (foreign-procedure __atomic "soda_runtime_start_timer"
                       (void* unsigned-64 unsigned-64)
                       unsigned-64))
  (define %watch-fd
    (foreign-procedure __atomic "soda_runtime_watch_fd"
                       (void* int unsigned-32)
                       unsigned-64))
  (define %read-file
    (foreign-procedure __atomic "soda_runtime_read_file" (void* string) unsigned-64))
  (define %cancel
    (foreign-procedure __atomic "soda_runtime_cancel" (void* unsigned-64) int))
  (define %poll
    (foreign-procedure __atomic "soda_runtime_poll" (void* int) int))
  (define %next-event
    (foreign-procedure __atomic "soda_runtime_next_event" (void*) int))
  (define %event-kind
    (foreign-procedure __atomic "soda_runtime_event_kind" (void*) unsigned-32))
  (define %event-source
    (foreign-procedure __atomic "soda_runtime_event_source" (void*) unsigned-64))
  (define %event-status
    (foreign-procedure __atomic "soda_runtime_event_status" (void*) int))
  (define %event-flags
    (foreign-procedure __atomic "soda_runtime_event_flags" (void*) unsigned-32))
  (define %event-data-size
    (foreign-procedure __atomic "soda_runtime_event_data_size" (void*) size_t))
  (define %copy-event-data
    (foreign-procedure __atomic "soda_runtime_copy_event_data"
                       (void* u8* size_t)
                       size_t))
  (define %last-error
    (foreign-procedure __atomic "soda_runtime_last_error" (void*) string))

  (define-record-type (runtime %make-runtime runtime?)
    (fields (mutable pointer)))

  (define-record-type event
    (fields kind source status flags data))

  (define fd-readable #x1)
  (define fd-writable #x2)

  (define (require-runtime who value)
    (unless (runtime? value)
      (assertion-violation who "expected a runtime" value))
    (unless (runtime-pointer value)
      (assertion-violation who "runtime is closed" value)))

  (define (native-error who runtime)
    (error who (%last-error (runtime-pointer runtime))))

  (define (make-runtime)
    (let ([pointer (%runtime-create)])
      (unless pointer
        (error 'make-runtime "cannot create native runtime"))
      (%make-runtime pointer)))

  (define (runtime-close! runtime)
    (require-runtime 'runtime-close! runtime)
    (%runtime-destroy (runtime-pointer runtime))
    (runtime-pointer-set! runtime #f))

  (define (runtime-start-timer! runtime timeout-ms repeat-ms)
    (require-runtime 'runtime-start-timer! runtime)
    (let ([source (%start-timer (runtime-pointer runtime) timeout-ms repeat-ms)])
      (if (zero? source)
          (native-error 'runtime-start-timer! runtime)
          source)))

  (define (runtime-watch-fd! runtime fd events)
    (require-runtime 'runtime-watch-fd! runtime)
    (let ([source (%watch-fd (runtime-pointer runtime) fd events)])
      (if (zero? source)
          (native-error 'runtime-watch-fd! runtime)
          source)))

  (define (runtime-read-file! runtime path)
    (require-runtime 'runtime-read-file! runtime)
    (let ([source (%read-file (runtime-pointer runtime) path)])
      (if (zero? source)
          (native-error 'runtime-read-file! runtime)
          source)))

  (define (runtime-cancel! runtime source)
    (require-runtime 'runtime-cancel! runtime)
    (let ([status (%cancel (runtime-pointer runtime) source)])
      (if (negative? status)
          (native-error 'runtime-cancel! runtime)
          (not (zero? status)))))

  (define (integer->event-kind value)
    (case value
      [(1) 'timer]
      [(2) 'fd-ready]
      [(3) 'file-read]
      [else (error 'runtime-poll! "unknown native event kind" value)]))

  (define (copy-current-data pointer)
    (let* ([size (%event-data-size pointer)]
           [data (make-bytevector size)])
      (unless (zero? size)
        (unless (= (%copy-event-data pointer data size) size)
          (error 'runtime-poll! "cannot copy native event data")))
      data))

  (define (drain-events runtime)
    (let ([pointer (runtime-pointer runtime)])
      (let loop ([events '()])
        (let ([status (%next-event pointer)])
          (cond
            [(negative? status) (native-error 'runtime-poll! runtime)]
            [(zero? status) (reverse events)]
            [else
             (loop
               (cons
                 (make-event (integer->event-kind (%event-kind pointer))
                             (%event-source pointer)
                             (%event-status pointer)
                             (%event-flags pointer)
                             (copy-current-data pointer))
                 events))])))))

  (define (poll runtime mode)
    (require-runtime 'runtime-poll! runtime)
    (when (negative? (%poll (runtime-pointer runtime) mode))
      (native-error 'runtime-poll! runtime))
    (drain-events runtime))

  (define (runtime-poll! runtime)
    (poll runtime 1))

  (define (runtime-poll-nowait! runtime)
    (poll runtime 0)))
