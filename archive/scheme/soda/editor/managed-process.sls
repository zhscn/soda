(library (soda editor managed-process)
  (export make-managed-process
          managed-process?
          managed-process-name
          managed-process-arguments
          managed-process-working-directory
          managed-process-transport
          managed-process-terminal-rows
          managed-process-terminal-columns
          managed-process-owner
          managed-process-state
          managed-process-generation
          managed-process-source
          managed-process-input-open?
          managed-process-exit-status
          managed-process-termination-signal
          managed-process-running?
          managed-process-event?
          managed-process-event-process
          managed-process-event-generation
          managed-process-event-kind
          managed-process-event-status
          managed-process-event-flags
          managed-process-event-data
          managed-process-event-restarted?
          make-managed-process-write-request
          managed-process-write-request-process
          managed-process-write-request-data
          make-managed-process-signal-request
          managed-process-signal-request?
          managed-process-signal-request-process
          managed-process-signal-request-signal
          make-managed-process-resize-request
          install-managed-process-runtime!
          managed-process-runtime?
          managed-process-runtime-handle-event)
  (import (rnrs)
          (soda editor command)
          (soda editor effect)
          (soda editor event)
          (soda runtime))

  (define-record-type
    (managed-process %make-managed-process managed-process?)
    (fields
      name
      arguments
      working-directory
      transport
      (mutable terminal-rows
               managed-process-terminal-rows
               managed-process-terminal-rows-set!)
      (mutable terminal-columns
               managed-process-terminal-columns
               managed-process-terminal-columns-set!)
      owner
      output-command
      exit-command
      (mutable state
               managed-process-state
               managed-process-state-set!)
      (mutable generation
               managed-process-generation
               managed-process-generation-set!)
      (mutable source
               managed-process-source
               managed-process-source-set!)
      (mutable input-open?
               managed-process-input-open?
               managed-process-input-open?-set!)
      (mutable exit-status
               managed-process-exit-status
               managed-process-exit-status-set!)
      (mutable termination-signal
               managed-process-termination-signal
               managed-process-termination-signal-set!)
      (mutable restart-pending?
               managed-process-restart-pending?
               managed-process-restart-pending?-set!)))

  (define-record-type managed-process-write-request
    (fields process data))

  (define-record-type managed-process-signal-request
    (fields process signal))

  (define-record-type managed-process-resize-request
    (fields process rows columns))

  (define-record-type managed-process-event
    (fields
      process
      generation
      kind
      status
      flags
      data
      restarted?))

  (define-record-type
    (managed-process-runtime
      %make-managed-process-runtime
      managed-process-runtime?)
    (fields runtime processes))

  (define make-managed-process
    (case-lambda
      [(name arguments working-directory owner output-command exit-command)
       (make-managed-process
         name arguments working-directory owner output-command exit-command
         'pipe 24 80)]
      [(name arguments working-directory owner output-command exit-command
             transport terminal-rows terminal-columns)
       (unless (and (string? name) (positive? (string-length name)))
         (assertion-violation
           'make-managed-process
           "name must be a non-empty string"
           name))
       (unless
         (and
           (pair? arguments)
           (list? arguments)
           (for-all string? arguments)
           (positive? (string-length (car arguments))))
         (assertion-violation
           'make-managed-process
           "arguments must be a non-empty list of strings"
           arguments))
       (unless
         (and
           (string? working-directory)
           (positive? (string-length working-directory)))
         (assertion-violation
           'make-managed-process
           "working directory must be a non-empty string"
           working-directory))
       (unless (memq transport '(pipe pty))
         (assertion-violation
           'make-managed-process
           "transport must be pipe or pty"
           transport))
       (unless
         (and
           (integer? terminal-rows) (exact? terminal-rows)
           (positive? terminal-rows)
           (integer? terminal-columns) (exact? terminal-columns)
           (positive? terminal-columns))
         (assertion-violation
           'make-managed-process
           "terminal rows and columns must be positive exact integers"
           terminal-rows terminal-columns))
       (unless (and (symbol? output-command) (symbol? exit-command))
         (assertion-violation
           'make-managed-process
           "output and exit commands must be symbols"
           output-command
           exit-command))
       (%make-managed-process
         name arguments working-directory transport
         terminal-rows terminal-columns owner output-command exit-command
         'created 0 #f #f #f #f #f)]))

  (define (managed-process-running? process)
    (unless (managed-process? process)
      (assertion-violation
        'managed-process-running?
        "expected a managed process"
        process))
    (memq (managed-process-state process) '(running stopping)))

  (define (require-process who process)
    (unless (managed-process? process)
      (assertion-violation
        who
        "expected a managed process"
        process))
    process)

  (define (require-running-process who process)
    (require-process who process)
    (unless (eq? (managed-process-state process) 'running)
      (assertion-violation
        who
        "managed process is not accepting operations"
        (managed-process-state process)))
    process)

  (define (spawn-process! adapter process)
    (unless
      (memq (managed-process-state process) '(created exited))
      (assertion-violation
        'managed-process.start
        "managed process cannot start from its current state"
        (managed-process-state process)))
    (let ([source
            (if
              (eq? (managed-process-transport process) 'pty)
              (runtime-spawn-terminal-process!
                (managed-process-runtime-runtime adapter)
                (managed-process-arguments process)
                (managed-process-working-directory process)
                (managed-process-terminal-rows process)
                (managed-process-terminal-columns process))
              (runtime-spawn-process!
                (managed-process-runtime-runtime adapter)
                (managed-process-arguments process)
                (managed-process-working-directory process)))])
      (managed-process-generation-set!
        process
        (+ 1 (managed-process-generation process)))
      (managed-process-source-set! process source)
      (managed-process-state-set! process 'running)
      (managed-process-input-open?-set! process #t)
      (managed-process-exit-status-set! process #f)
      (managed-process-termination-signal-set! process #f)
      (hashtable-set!
        (managed-process-runtime-processes adapter)
        source
        process)
      source))

  (define (start-process! adapter process)
    (require-process 'managed-process.start process)
    (spawn-process! adapter process)
    (make-effect-result #t '()))

  (define (write-process! adapter request)
    (unless (managed-process-write-request? request)
      (assertion-violation
        'managed-process.write
        "expected a managed process write request"
        request))
    (let ([process
            (require-running-process
              'managed-process.write
              (managed-process-write-request-process request))]
          [data (managed-process-write-request-data request)])
      (unless (managed-process-input-open? process)
        (assertion-violation
          'managed-process.write
          "managed process input is closed"))
      (unless (bytevector? data)
        (assertion-violation
          'managed-process.write
          "process input must be a bytevector"
          data))
      (runtime-write-process!
        (managed-process-runtime-runtime adapter)
        (managed-process-source process)
        data)
      (make-effect-result #t '())))

  (define (close-process-input! adapter process)
    (require-running-process 'managed-process.close-input process)
    (unless (managed-process-input-open? process)
      (assertion-violation
        'managed-process.close-input
        "managed process input is already closed"))
    (if
      (eq? (managed-process-transport process) 'pty)
      (runtime-write-process!
        (managed-process-runtime-runtime adapter)
        (managed-process-source process)
        #vu8(4))
      (runtime-close-process-input!
        (managed-process-runtime-runtime adapter)
        (managed-process-source process)))
    (managed-process-input-open?-set! process #f)
    (make-effect-result #t '()))

  (define (resize-process-terminal! adapter request)
    (unless (managed-process-resize-request? request)
      (assertion-violation
        'managed-process.resize-terminal
        "expected a managed process resize request"
        request))
    (let ([process
            (require-running-process
              'managed-process.resize-terminal
              (managed-process-resize-request-process request))]
          [rows (managed-process-resize-request-rows request)]
          [columns (managed-process-resize-request-columns request)])
      (unless (eq? (managed-process-transport process) 'pty)
        (assertion-violation
          'managed-process.resize-terminal
          "managed process does not use a pseudo-terminal"))
      (unless
        (and
          (integer? rows) (exact? rows) (positive? rows)
          (integer? columns) (exact? columns) (positive? columns))
        (assertion-violation
          'managed-process.resize-terminal
          "terminal rows and columns must be positive exact integers"
          rows columns))
      (runtime-resize-process-terminal!
        (managed-process-runtime-runtime adapter)
        (managed-process-source process)
        rows
        columns)
      (managed-process-terminal-rows-set! process rows)
      (managed-process-terminal-columns-set! process columns)
      (make-effect-result #t '())))

  (define (signal-process! adapter request)
    (unless (managed-process-signal-request? request)
      (assertion-violation
        'managed-process.signal
        "expected a managed process signal request"
        request))
    (let ([process
            (require-process
              'managed-process.signal
              (managed-process-signal-request-process request))]
          [signal (managed-process-signal-request-signal request)])
      (unless
        (memq (managed-process-state process) '(running stopping))
        (assertion-violation
          'managed-process.signal
          "managed process is not running"
          (managed-process-state process)))
      (unless
        (and (integer? signal) (exact? signal) (positive? signal))
        (assertion-violation
          'managed-process.signal
          "signal must be a positive exact integer"
          signal))
      (runtime-signal-process!
        (managed-process-runtime-runtime adapter)
        (managed-process-source process)
        signal)
      (when (memv signal '(9 15))
        (managed-process-state-set! process 'stopping))
      (make-effect-result #t '())))

  (define (restart-process! adapter process)
    (require-process 'managed-process.restart process)
    (case (managed-process-state process)
      [(created exited)
       (spawn-process! adapter process)]
      [(running)
       (managed-process-restart-pending?-set! process #t)
       (runtime-signal-process!
         (managed-process-runtime-runtime adapter)
         (managed-process-source process)
         15)
       (managed-process-state-set! process 'stopping)]
      [(stopping)
       (managed-process-restart-pending?-set! process #t)]
      [else
       (assertion-violation
         'managed-process.restart
         "managed process has an invalid state"
         (managed-process-state process))])
    (make-effect-result #t '()))

  (define (install-managed-process-runtime! executor runtime)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-managed-process-runtime!
        "expected an effect executor"
        executor))
    (unless (runtime? runtime)
      (assertion-violation
        'install-managed-process-runtime!
        "expected a runtime"
        runtime))
    (let ([adapter
            (%make-managed-process-runtime
              runtime
              (make-eqv-hashtable))])
      (register-effect-handler!
        executor
        'managed-process.start
        (lambda (process)
          (start-process! adapter process)))
      (register-effect-handler!
        executor
        'managed-process.write
        (lambda (request)
          (write-process! adapter request)))
      (register-effect-handler!
        executor
        'managed-process.close-input
        (lambda (process)
          (close-process-input! adapter process)))
      (register-effect-handler!
        executor
        'managed-process.resize-terminal
        (lambda (request)
          (resize-process-terminal! adapter request)))
      (register-effect-handler!
        executor
        'managed-process.signal
        (lambda (request)
          (signal-process! adapter request)))
      (register-effect-handler!
        executor
        'managed-process.restart
        (lambda (process)
          (restart-process! adapter process)))
      adapter))

  (define (process-event-message
            process
            event
            generation
            restarted?)
    (let ([kind (event-kind event)])
      (make-internal-command-message
        (if
          (eq? kind 'process-output)
          (managed-process-output-command process)
          (managed-process-exit-command process))
        (make-managed-process-event
          process
          generation
          kind
          (event-status event)
          (event-flags event)
          (event-data event)
          restarted?))))

  (define (managed-process-runtime-handle-event adapter event)
    (unless (managed-process-runtime? adapter)
      (assertion-violation
        'managed-process-runtime-handle-event
        "expected a managed process runtime"
        adapter))
    (unless (event? event)
      (assertion-violation
        'managed-process-runtime-handle-event
        "expected a runtime event"
        event))
    (let ([process
            (hashtable-ref
              (managed-process-runtime-processes adapter)
              (event-source event)
              #f)])
      (and
        process
        (case (event-kind event)
          [(process-output)
           (process-event-message
             process
             event
             (managed-process-generation process)
             #f)]
          [(process-exit)
           (let ([generation
                   (managed-process-generation process)]
                 [restart?
                   (managed-process-restart-pending? process)])
             (hashtable-delete!
               (managed-process-runtime-processes adapter)
               (event-source event))
             (managed-process-source-set! process #f)
             (managed-process-input-open?-set! process #f)
             (managed-process-exit-status-set!
               process
               (event-status event))
             (managed-process-termination-signal-set!
               process
               (event-flags event))
             (managed-process-state-set! process 'exited)
             (managed-process-restart-pending?-set!
               process
               #f)
             (when restart?
               (spawn-process! adapter process))
             (process-event-message
               process
               event
               generation
               restart?))]
          [else #f]))))
)
