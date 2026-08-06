(library (soda packages interaction)
  (export make-interaction-service!
          interaction-service?
          interaction-service-current
          interaction-service-sessions
          interaction-service-submit!
          interaction-service-cancel!
          interaction-service-cancel-all!
          interaction-service-add-listener!
          interaction-session?
          interaction-session-invocation-id
          interaction-session-command-name
          interaction-session-reader-name
          interaction-session-status
          interaction-session-request
          interaction-session-context
          make-interaction-request
          interaction-request?
          interaction-request-kind
          interaction-request-prompt
          interaction-request-initial-value
          interaction-request-completion-source
          interaction-request-selection-policy
          interaction-request-validator
          interaction-request-keymap
          make-interaction-string-reader)
  (import (rnrs)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host value))

  ;; InteractionSession is the frontend-neutral representation of one
  ;; suspended InteractiveReader.  The request is opaque package data; a TUI,
  ;; RPC client, or test adapter chooses how to render and answer it.
  (define-record-type
    (interaction-session %make-interaction-session interaction-session?)
    (fields
      (immutable invocation-id interaction-session-invocation-id)
      (immutable command-name interaction-session-command-name)
      (immutable reader-name interaction-session-reader-name)
      (mutable status interaction-session-status interaction-session-status-set!)
      (immutable request interaction-session-request)
      (immutable context interaction-session-context)))

  (define-record-type interaction-listener
    (fields owner procedure))

  (define-record-type
    (interaction-service %make-interaction-service interaction-service?)
    (fields
      (immutable runtime interaction-service-runtime)
      (mutable sessions interaction-service-sessions interaction-service-sessions-set!)
      (mutable listeners interaction-service-listeners interaction-service-listeners-set!)
      (mutable registration interaction-service-registration interaction-service-registration-set!)))

  (define (session-active? service session)
    (and (command-runtime-invocation
           (interaction-service-runtime service)
           (interaction-session-invocation-id session) #f)
         #t))

  (define (notify! service kind session)
    (for-each
      (lambda (listener)
        ;; UI observers never execute a user command.  Their failures must not
        ;; turn a suspended invocation into a command condition.
        (guard (ignored [else #f])
          ((interaction-listener-procedure listener) kind session)))
      (interaction-service-listeners service)))

  (define (remove-session! service target event)
    (let ([sessions (interaction-service-sessions service)])
      (interaction-service-sessions-set!
        service (filter (lambda (session) (not (eq? session target))) sessions))
      (when event (notify! service event target))
    target))

  (define (prune-sessions! service)
    (let ([stale
            (filter (lambda (session) (not (session-active? service session)))
                    (interaction-service-sessions service))])
      (for-each (lambda (session) (remove-session! service session 'cancelled)) stale)))

  (define (interaction-service-current service)
    (unless (interaction-service? service)
      (assertion-violation 'interaction-service-current "expected an interaction service" service))
    (prune-sessions! service)
    (let ([sessions (interaction-service-sessions service)])
      (and (pair? sessions) (car sessions))))

  (define (interaction-service-add-listener! service owner procedure)
    (unless (and (interaction-service? service) (owner? owner) (procedure? procedure))
      (assertion-violation 'interaction-service-add-listener!
                           "expected an interaction service, owner, and procedure"
                           service owner procedure))
    (owner-assert-active 'interaction-service-add-listener! owner)
    (let ([listener (make-interaction-listener owner procedure)])
      (interaction-service-listeners-set!
        service (append (interaction-service-listeners service) (list listener)))
      (make-registration
        owner
        (lambda ()
          (interaction-service-listeners-set!
            service
            (filter (lambda (item) (not (eq? item listener)))
                    (interaction-service-listeners service)))))))

  (define (reader-name invocation)
    (let ([readers (command-invocation-remaining-readers invocation)])
      (and (pair? readers) (interactive-reader-name (car readers)))))

  (define (open-session! service invocation request)
    (let ([session
            (%make-interaction-session
              (command-invocation-id invocation)
              (command-definition-name (command-invocation-definition invocation))
              (reader-name invocation)
              'open request
              (command-invocation-context invocation))])
      (interaction-service-sessions-set!
        service (cons session (interaction-service-sessions service)))
      (notify! service 'opened session)
      session))

  ;; Requests are immutable UI contracts.  A completion source is intentionally
  ;; opaque: the interaction frontend, not CommandRuntime, owns candidate
  ;; evaluation and presentation.
  (define-record-type
    (interaction-request %make-interaction-request interaction-request?)
    (fields
      (immutable kind interaction-request-kind)
      (immutable prompt interaction-request-prompt)
      (immutable initial-value interaction-request-initial-value)
      (immutable completion-source interaction-request-completion-source)
      (immutable selection-policy interaction-request-selection-policy)
      (immutable validator interaction-request-validator)
      ;; A request-specific keymap adds discrete answers without giving the
      ;; interaction service any knowledge of a particular command.  The
      ;; minibuffer places it above its ordinary editing keymap.
      (immutable keymap interaction-request-keymap)))

  (define make-interaction-request
    (case-lambda
      [(kind prompt)
       (make-interaction-request kind prompt #f #f 'free #f #f)]
      [(kind prompt initial-value completion-source selection-policy)
       (make-interaction-request kind prompt initial-value completion-source selection-policy #f #f)]
      [(kind prompt initial-value completion-source selection-policy validator)
       (make-interaction-request kind prompt initial-value completion-source selection-policy validator #f)]
      [(kind prompt initial-value completion-source selection-policy validator keymap)
       (unless (and (symbol? kind) (string? prompt)
                    (memq selection-policy '(free must-match))
                    (or (not validator) (procedure? validator))
                    (or (not keymap) (keymap? keymap)))
         (assertion-violation 'make-interaction-request "invalid interaction request"
                              kind prompt selection-policy))
       (%make-interaction-request kind prompt initial-value completion-source selection-policy
                                  validator keymap)]))

  ;; The basic string reader provides the common bridge from an ordinary
  ;; command parameter to a frontend request.  Typed readers can use the same
  ;; request constructor with a domain-specific decoder.
  (define make-interaction-string-reader
    (case-lambda
      [(name prompt)
       (make-interaction-string-reader name prompt #f)]
      [(name prompt initial-value)
       (make-interactive-reader
         name
         (lambda (context arguments)
           (make-interactive-suspend
             (make-interaction-request 'string prompt initial-value #f 'free #f)
             (lambda (value) (make-interactive-ready (list value))))))]))

  (define (interaction-service-session-for-id service id)
    (let loop ([sessions (interaction-service-sessions service)])
      (and (pair? sessions)
           (if (= (interaction-session-invocation-id (car sessions)) id)
               (car sessions)
               (loop (cdr sessions))))))

  ;; Submission and cancellation travel through Runtime's queue.  This keeps
  ;; native input, TUI actions, and RPC adapters at the same command boundary.
  (define (interaction-service-submit! service value)
    (unless (interaction-service? service)
      (assertion-violation 'interaction-service-submit! "expected an interaction service" service))
    (let ([session (interaction-service-current service)])
      (and session (eq? (interaction-session-status session) 'open)
           (begin
             (command-runtime-enqueue!
               (interaction-service-runtime service)
               (make-command-resume-message
                 (interaction-session-invocation-id session) value))
             (remove-session! service session 'accepted)
             session))))

  (define (interaction-service-cancel! service)
    (unless (interaction-service? service)
      (assertion-violation 'interaction-service-cancel! "expected an interaction service" service))
    (let ([session (interaction-service-current service)])
      (and session (eq? (interaction-session-status session) 'open)
           (begin
             (command-runtime-enqueue!
               (interaction-service-runtime service)
               (make-command-cancel-message
                 (interaction-session-invocation-id session)))
             (interaction-session-status-set! session 'cancelling)
             session))))

  (define (interaction-service-cancel-all! service)
    (unless (interaction-service? service)
      (assertion-violation 'interaction-service-cancel-all! "expected an interaction service" service))
    (prune-sessions! service)
    (let ([sessions
            (filter (lambda (session) (eq? (interaction-session-status session) 'open))
                    (interaction-service-sessions service))])
      (for-each
        (lambda (session)
          (command-runtime-enqueue!
            (interaction-service-runtime service)
            (make-command-cancel-message (interaction-session-invocation-id session)))
          (interaction-session-status-set! session 'cancelling))
        sessions)
      sessions))

  (define (make-interaction-service! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-interaction-service!
                           "expected a command runtime and owner" runtime owner))
    (owner-assert-active 'make-interaction-service! owner)
    (let ([service (%make-interaction-service runtime '() '() #f)])
      (interaction-service-registration-set!
        service
        (command-runtime-set-interaction-handler!
          runtime owner
          (lambda (ignored invocation request)
            (open-session! service invocation request))))
      (command-runtime-add-hook!
        runtime 'command-cancel owner 'close-interaction-session
        (lambda (invocation)
          (let ([session
                 (interaction-service-session-for-id
                   service (command-invocation-id invocation))])
            (when session (remove-session! service session 'cancelled)))))
      service))
)
