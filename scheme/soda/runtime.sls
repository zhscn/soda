(library (soda runtime)
  (export make-runtime
          runtime?
          runtime-close!
          runtime-poll!
          runtime-poll-nowait!
          runtime-start-timer!
          runtime-watch-fd!
          runtime-read-file!
          runtime-write-file!
          runtime-scan-directory!
          runtime-stat-path!
          runtime-cancel!
          runtime-status-name
          runtime-status-message
          make-terminal
          terminal?
          terminal-close!
          terminal-enter-raw!
          terminal-leave-raw!
          terminal-read
          terminal-write-some!
          terminal-write!
          terminal-size
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

  (define %abi-version
    (foreign-procedure __atomic "soda_runtime_abi_version" () unsigned-32))

  (define abi-version-checked
    (unless (= (%abi-version) 5)
      (error 'soda-runtime "unsupported native runtime ABI version")))

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
  (define %write-file
    (foreign-procedure __atomic "soda_runtime_write_file"
                       (void* string u8* size_t)
                       unsigned-64))
  (define %scan-directory
    (foreign-procedure __atomic "soda_runtime_scan_directory"
                       (void* string)
                       unsigned-64))
  (define %stat-path
    (foreign-procedure __atomic "soda_runtime_stat_path"
                       (void* string int)
                       unsigned-64))
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
  (define %status-name
    (foreign-procedure __atomic "soda_runtime_status_name" (int) string))
  (define %status-message
    (foreign-procedure __atomic "soda_runtime_status_message" (int) string))
  (define %last-error
    (foreign-procedure __atomic "soda_runtime_last_error" (void*) string))
  (define %terminal-create
    (foreign-procedure __atomic "soda_terminal_create" (int int) void*))
  (define %terminal-destroy
    (foreign-procedure __atomic "soda_terminal_destroy" (void*) void))
  (define %terminal-enter-raw
    (foreign-procedure __atomic "soda_terminal_enter_raw" (void*) int))
  (define %terminal-leave-raw
    (foreign-procedure __atomic "soda_terminal_leave_raw" (void*) int))
  (define %terminal-read
    (foreign-procedure __atomic "soda_terminal_read"
                       (void* u8* size_t)
                       integer-64))
  (define %terminal-write
    (foreign-procedure __atomic "soda_terminal_write"
                       (void* u8* size_t)
                       int))
  (define %terminal-write-some
    (foreign-procedure __atomic "soda_terminal_write_some"
                       (void* u8* size_t size_t)
                       integer-64))
  (define %terminal-size
    (foreign-procedure __atomic "soda_terminal_size"
                       (void* void* void*)
                       int))
  (define %terminal-last-error
    (foreign-procedure __atomic "soda_terminal_last_error" (void*) string))

  (define-record-type (runtime %make-runtime runtime?)
    (fields (mutable pointer)))

  (define-record-type (terminal %make-terminal terminal?)
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

  (define (require-terminal who value)
    (unless (terminal? value)
      (assertion-violation who "expected a terminal" value))
    (unless (terminal-pointer value)
      (assertion-violation who "terminal is closed" value)))

  (define (terminal-error who terminal)
    (error who (%terminal-last-error (terminal-pointer terminal))))

  (define (make-runtime)
    (let ([pointer (%runtime-create)])
      (unless pointer
        (error 'make-runtime "cannot create native runtime"))
      (%make-runtime pointer)))

  (define (runtime-close! runtime)
    (unless (runtime? runtime)
      (assertion-violation
        'runtime-close!
        "expected a runtime"
        runtime))
    (when (runtime-pointer runtime)
      (%runtime-destroy (runtime-pointer runtime))
      (runtime-pointer-set! runtime #f)))

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

  (define (runtime-write-file! runtime path data)
    (require-runtime 'runtime-write-file! runtime)
    (unless (string? path)
      (assertion-violation
        'runtime-write-file!
        "path must be a string"
        path))
    (unless (bytevector? data)
      (assertion-violation
        'runtime-write-file!
        "data must be a bytevector"
        data))
    (let ([source
            (%write-file
              (runtime-pointer runtime)
              path
              data
              (bytevector-length data))])
      (if (zero? source)
          (native-error 'runtime-write-file! runtime)
          source)))

  (define (runtime-scan-directory! runtime path)
    (require-runtime 'runtime-scan-directory! runtime)
    (unless (and (string? path) (positive? (string-length path)))
      (assertion-violation
        'runtime-scan-directory!
        "path must be a non-empty string"
        path))
    (let ([source
            (%scan-directory
              (runtime-pointer runtime)
              path)])
      (if (zero? source)
          (native-error 'runtime-scan-directory! runtime)
          source)))

  (define runtime-stat-path!
    (case-lambda
      [(runtime path) (runtime-stat-path! runtime path #t)]
      [(runtime path follow-symlinks?)
       (require-runtime 'runtime-stat-path! runtime)
       (unless (and (string? path) (positive? (string-length path)))
         (assertion-violation
           'runtime-stat-path!
           "path must be a non-empty string"
           path))
       (let ([source
               (%stat-path
                 (runtime-pointer runtime)
                 path
                 (if follow-symlinks? 1 0))])
         (if (zero? source)
             (native-error 'runtime-stat-path! runtime)
             source))]))

  (define (runtime-cancel! runtime source)
    (require-runtime 'runtime-cancel! runtime)
    (let ([status (%cancel (runtime-pointer runtime) source)])
      (if (negative? status)
          (native-error 'runtime-cancel! runtime)
          (not (zero? status)))))

  (define (runtime-status-name status)
    (unless (and (integer? status) (exact? status))
      (assertion-violation
        'runtime-status-name
        "status must be an exact integer"
        status))
    (%status-name status))

  (define (runtime-status-message status)
    (unless (and (integer? status) (exact? status))
      (assertion-violation
        'runtime-status-message
        "status must be an exact integer"
        status))
    (%status-message status))

  (define make-terminal
    (case-lambda
      [() (make-terminal 0 1)]
      [(input-fd output-fd)
       (let ([pointer (%terminal-create input-fd output-fd)])
         (unless pointer
           (error 'make-terminal "cannot create terminal"))
         (%make-terminal pointer))]))

  (define (terminal-close! terminal)
    (when (and (terminal? terminal) (terminal-pointer terminal))
      (%terminal-destroy (terminal-pointer terminal))
      (terminal-pointer-set! terminal #f)))

  (define (terminal-enter-raw! terminal)
    (require-terminal 'terminal-enter-raw! terminal)
    (when (negative? (%terminal-enter-raw (terminal-pointer terminal)))
      (terminal-error 'terminal-enter-raw! terminal)))

  (define (terminal-leave-raw! terminal)
    (require-terminal 'terminal-leave-raw! terminal)
    (when (negative? (%terminal-leave-raw (terminal-pointer terminal)))
      (terminal-error 'terminal-leave-raw! terminal)))

  (define terminal-read
    (case-lambda
      [(terminal) (terminal-read terminal 4096)]
      [(terminal capacity)
       (require-terminal 'terminal-read terminal)
       (let* ([buffer (make-bytevector capacity)]
              [size
                (%terminal-read
                  (terminal-pointer terminal)
                  buffer
                  capacity)])
         (when (negative? size)
           (terminal-error 'terminal-read terminal))
         (if (= size capacity)
             buffer
             (let ([output (make-bytevector size)])
               (bytevector-copy! buffer 0 output 0 size)
               output)))]))

  (define (terminal-write! terminal data)
    (require-terminal 'terminal-write! terminal)
    (let ([bytes
            (cond
              [(bytevector? data) data]
              [(string? data) (string->utf8 data)]
              [else
               (assertion-violation
                 'terminal-write!
                 "expected a bytevector or string"
                 data)])])
      (when (negative?
              (%terminal-write
                (terminal-pointer terminal)
                bytes
                (bytevector-length bytes)))
        (terminal-error 'terminal-write! terminal))))

  (define (terminal-write-some! terminal data offset)
    (require-terminal 'terminal-write-some! terminal)
    (unless (bytevector? data)
      (assertion-violation
        'terminal-write-some!
        "expected a bytevector"
        data))
    (unless (and (integer? offset)
                 (exact? offset)
                 (<= 0 offset (bytevector-length data)))
      (assertion-violation
        'terminal-write-some!
        "offset is outside the bytevector"
        offset))
    (let ([result
            (%terminal-write-some
              (terminal-pointer terminal)
              data
              (bytevector-length data)
              offset)])
      (cond
        [(= result -2) #f]
        [(negative? result)
         (terminal-error 'terminal-write-some! terminal)]
        [else result])))

  (define (terminal-size terminal)
    (require-terminal 'terminal-size terminal)
    (let ([rows (foreign-alloc 4)]
          [columns (foreign-alloc 4)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (when (negative?
                  (%terminal-size
                    (terminal-pointer terminal)
                    rows
                    columns))
            (terminal-error 'terminal-size terminal))
          (cons (foreign-ref 'unsigned-32 rows 0)
                (foreign-ref 'unsigned-32 columns 0)))
        (lambda ()
          (foreign-free rows)
          (foreign-free columns)))))

  (define (integer->event-kind value)
    (case value
      [(1) 'timer]
      [(2) 'fd-ready]
      [(3) 'file-read]
      [(4) 'file-write]
      [(5) 'directory-scan]
      [(6) 'path-stat]
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
