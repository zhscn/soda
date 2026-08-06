(library (soda packages process)
  (export make-process-service!
          process-service?
          process-keymap
          process-service-attach-runtime!
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
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal operation)
          (soda host internal state)
          (soda host internal view)
          (soda host value)
          (soda packages interaction))

  ;; ProcessService owns package-level process identity and output Buffer
  ;; routing.  The terminal frontend supplies a native Runtime at composition
  ;; time; commands do not otherwise depend on terminal implementation.
  (define-record-type
    (process-service %make-process-service process-service?)
    (fields state owner keymap processes
            (mutable runtime process-service-runtime process-service-runtime-set!)))

  (define-record-type process-request
    (fields context command))

  (define-record-type process-task
    (fields source buffer-id command))

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

  (define (append-output! service task bytes)
    (let ([buffer
           (buffer-service-ref
             (host-state-buffers (process-service-state service))
             (process-task-buffer-id task) #f)])
      (if buffer
          (dispatcher-dispatch!
            (host-state-dispatch (process-service-state service))
            (process-output-transaction buffer bytes))
          #f)))

  (define (open-output-buffer! service request)
    (let* ([state (process-service-state service)]
           [context (process-request-context request)]
           [buffers (host-state-buffers state)]
           [views (host-state-views state)]
           [configuration
            (buffer-state-configuration (command-context-buffer-state context))]
           [buffer
            (buffer-service-create!
              buffers (process-service-owner service)
              (make-process-buffer-name (process-request-command request))
              (make-document "") configuration)]
           [view
            (view-service-create! views (process-service-owner service) buffer configuration)])
      (unless
        (dispatcher-dispatch-host!
          (host-state-dispatch state)
          (make-replace-window-view-operation
            (command-context-surface-id context)
            (command-context-window-id context) (view-id view)))
        (view-service-close-view! views (view-id view))
        (buffer-service-close-buffer! buffers (buffer-id buffer))
        (assertion-violation 'process.execute
                             "origin Window is no longer available" context))
      buffer))

  (define (start-process! service request)
    (unless (process-request? request)
      (assertion-violation 'process.spawn "invalid process request" request))
    (let ([runtime (process-service-runtime service)])
      (unless runtime
        (assertion-violation 'process.spawn
                             "no native process runtime is attached" request))
      (let* ([buffer (open-output-buffer! service request)]
             [source
              (native:runtime-spawn-process!
                runtime
                (list "/bin/sh" "-c" (process-request-command request))
                (current-directory))]
             [task (make-process-task source (buffer-id buffer)
                                      (process-request-command request))])
        (hashtable-set! (process-service-processes service) source task)
        task)))

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
           (case (native:event-kind event)
             [(process-output)
              (append-output! service task (native:event-data event))
              #t]
             [(process-exit)
              (append-output!
                service task
                (string->utf8
                  (string-append "\n[Process exited with status "
                                 (number->string (native:event-status event)) "]\n")))
              (hashtable-delete! (process-service-processes service)
                                 (process-task-source task))
              #t]
             [else #f]))))

  (define (make-process-service! state owner)
    (unless (and (host-state? state) (owner? owner))
      (assertion-violation 'make-process-service! "invalid process service dependencies"
                           state owner))
    (let* ([runtime (host-state-command-runtime state)]
           [keymap (make-keymap 'process)]
           [service (%make-process-service state owner keymap (make-eqv-hashtable) #f)])
      (command-runtime-register-effect-handler!
        runtime 'process.spawn owner 'native-process-spawn
        (lambda (ignored invocation effect)
          (start-process! service (command-effect-payload effect))))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'process.execute
          (lambda (context command)
            (make-command-effect
              'process.spawn (make-process-request context command)))
          owner "Execute a shell command and display its output in a Buffer."
          'process (make-interactive-plan (list (make-process-request-reader)))))
      (keymap-bind! keymap (list (control-stroke #\t)) 'process.execute)
      service)))
