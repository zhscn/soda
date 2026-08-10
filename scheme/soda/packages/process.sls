(library (soda packages process)
  (export make-process-service!
          process-service?
          process-keymap
          process-service-attach-runtime!
          make-process-job
          process-job?
          process-service-run!
          process-service-handle-runtime-event!)
  (import (rnrs)
          (only (chezscheme) current-directory)
          (prefix (soda ffi runtime) native:)
          (soda kernel change)
          (soda kernel document)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host buffer)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host value)
          (soda host view)
          (soda packages interaction))

  ;; ProcessService owns package-level process identity and output Buffer
  ;; routing.  The terminal frontend supplies a native Runtime at composition
  ;; time; commands do not otherwise depend on terminal implementation.
  (define-record-type
    (process-service %make-process-service process-service?)
    (fields host owner keymap processes
            (mutable runtime process-service-runtime process-service-runtime-set!)))

  ;; A ProcessJob is the package boundary for a finite, pipe-backed external
  ;; task.  `input` is written once and stdin is then closed, so jobs cannot
  ;; accidentally retain a subprocess waiting for terminal input.  Callbacks
  ;; run on the host runtime turn that delivered the native event.
  (define-record-type
    (process-job %make-process-job process-job?)
    (fields arguments working-directory input on-output on-exit))

  (define (valid-process-arguments? arguments)
    (and (pair? arguments)
         (list? arguments)
         (string? (car arguments))
         (positive? (string-length (car arguments)))
         (for-all
           (lambda (argument)
             (and (string? argument)
                  (not (exists (lambda (character) (char=? character #\nul))
                               (string->list argument)))))
           arguments)))

  (define (make-process-job arguments working-directory input on-output on-exit)
    (unless (valid-process-arguments? arguments)
      (assertion-violation 'make-process-job
                           "arguments must be a non-empty string list with a non-empty executable"
                           arguments))
    (unless (string? working-directory)
      (assertion-violation 'make-process-job "working directory must be a string"
                           working-directory))
    (unless (bytevector? input)
      (assertion-violation 'make-process-job "input must be a bytevector" input))
    (unless (or (not on-output) (procedure? on-output))
      (assertion-violation 'make-process-job "output callback must be a procedure or false"
                           on-output))
    (unless (or (not on-exit) (procedure? on-exit))
      (assertion-violation 'make-process-job "exit callback must be a procedure or false"
                           on-exit))
    (%make-process-job (list-copy arguments) working-directory input on-output on-exit))

  (define-record-type process-request
    (fields context command))

  (define-record-type process-task
    (fields source job))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (process-keymap service)
    (unless (process-service? service)
      (assertion-violation 'process-keymap "expected a process service" service))
    (process-service-keymap service))

  (define (make-process-buffer-name command)
    (string-append "*command: " command "*"))

  (define (make-process-request-reader)
    (make-interaction-string-reader 'shell-command "Execute command: "))

  (define (process-output-transaction buffer data)
    (let* ([state (buffer-state buffer)]
           [length (snapshot-byte-size (buffer-state-document state))])
      (make-transaction-spec
        (buffer-id buffer) (buffer-state-generation state)
        (make-change-set length (list (make-text-change length length data))))))

  (define (append-output! service buffer-id bytes)
    (let ([buffer
           (package-host-buffer-ref (process-service-host service) buffer-id #f)])
      (if buffer
          (package-host-dispatch! (process-service-host service)
            (process-output-transaction buffer bytes))
          #f)))

  (define (open-output-buffer! service request)
    (let* ([host (process-service-host service)]
           [context (process-request-context request)]
           [configuration
            (buffer-state-configuration (command-context-buffer-state context))]
           [buffer
            (package-host-create-buffer!
              host (process-service-owner service)
              (make-process-buffer-name (process-request-command request))
              (make-document "") configuration)]
           [view
            (package-host-create-view! host (process-service-owner service) buffer configuration)])
      (unless
        (package-host-replace-window-view!
          host (command-context-surface-id context)
          (command-context-window-id context) (view-id view))
        (package-host-close-buffer! host (buffer-id buffer))
        (assertion-violation 'process.execute
                             "origin Window is no longer available" context))
      buffer))

  (define (process-service-run! service job)
    (unless (and (process-service? service) (process-job? job))
      (assertion-violation 'process-service-run! "expected a process service and job"
                           service job))
    (let ([runtime (process-service-runtime service)])
      (unless runtime
        (assertion-violation 'process-service-run!
                             "no native process runtime is attached" service))
      (let ([source
             (native:runtime-spawn-process!
               runtime (process-job-arguments job) (process-job-working-directory job))])
        (guard
          (condition
            [else
             (guard (ignored [else #f])
               (native:runtime-cancel! runtime source))
             (raise condition)])
          (native:runtime-write-process! runtime source (process-job-input job))
          (native:runtime-close-process-input! runtime source)
          (hashtable-set! (process-service-processes service) source
                          (make-process-task source job))
          source))))

  (define (start-process! service request)
    (unless (process-request? request)
      (assertion-violation 'process.spawn "invalid process request" request))
    (let* ([buffer (open-output-buffer! service request)]
           [buffer-id (buffer-id buffer)]
           [job
            (make-process-job
              (list "/bin/sh" "-c" (process-request-command request))
              (current-directory) (make-bytevector 0)
              (lambda (event)
                (append-output! service buffer-id (native:event-data event)))
              (lambda (status flags)
                (append-output!
                  service buffer-id
                  (string->utf8
                    (string-append "\n[Process exited with status "
                                   (number->string status) "]\n")))))])
      (process-service-run! service job)))

  (define (process-service-attach-runtime! service runtime)
    (unless (and (process-service? service) (native:runtime? runtime))
      (assertion-violation 'process-service-attach-runtime!
                           "expected a process service and native runtime" service runtime))
    (process-service-runtime-set! service runtime)
    service)

  ;; The terminal adapter calls this for unclaimed native events.  Output is
  ;; appended through Dispatcher transactions, preserving published Buffer
  ;; state and View-local selections while a subprocess runs.
  (define (process-service-handle-runtime-event! service event)
    (unless (and (process-service? service) (native:event? event))
      (assertion-violation 'process-service-handle-runtime-event!
                           "expected a process service and native event" service event))
    (let ([task
           (hashtable-ref (process-service-processes service)
                          (native:event-source event) #f)])
      (and task
           (let ([job (process-task-job task)])
             (case (native:event-kind event)
               [(process-output)
                (let ([callback (process-job-on-output job)])
                  (when callback (callback event)))
                #t]
               [(process-exit)
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (let ([callback (process-job-on-exit job)])
                      (when callback
                        (callback (native:event-status event) (native:event-flags event)))))
                  (lambda ()
                    (hashtable-delete! (process-service-processes service)
                                       (process-task-source task))))
                #t]
               [else #f])))))

  (define (make-process-service! host owner)
    (unless (and (package-host? host) (owner? owner))
      (assertion-violation 'make-process-service! "invalid process service dependencies"
                           host owner))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-keymap 'process)]
           [service (%make-process-service host owner keymap (make-eqv-hashtable) #f)])
      (command-runtime-register-effect-handler!
        runtime 'process.spawn owner 'native-process-spawn
        (lambda (ignored invocation effect)
          (start-process! service (command-effect-payload effect))))
      (define-command
        runtime owner 'process.execute (context command)
        (documentation "Execute a shell command and display its output in a Buffer.")
        (class 'process)
        (interactive (make-interactive-plan (list (make-process-request-reader))))
        (undo 'ignore)
        (make-command-effect
          'process.spawn (make-process-request context command)))
      (keymap-bind!
        keymap
        (list (make-key-stroke 'character (char->integer #\!) 2))
        'process.execute)
      service)))
