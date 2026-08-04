(library (soda packages minibuffer)
  (export make-minibuffer-service!
          minibuffer-service?
          minibuffer-service-current
          minibuffer-service-sessions
          minibuffer-session?
          minibuffer-session-interaction
          minibuffer-session-buffer-id
          minibuffer-session-view-id
          minibuffer-session-origin-view-id
          minibuffer-session-completion
          prompt-snapshot?
          prompt-snapshot-session-id prompt-snapshot-request
          prompt-snapshot-input prompt-snapshot-input-revision
          prompt-snapshot-point prompt-snapshot-selection
          prompt-snapshot-origin-context prompt-snapshot-completion-generation
          prompt-snapshot-presentation
          minibuffer-session-snapshot
          minibuffer-service-add-hook!
          minibuffer-service-refresh-completion!
          minibuffer-service-select-completion!
          minibuffer-input-context
          minibuffer-service-submit!
          minibuffer-service-cancel!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host value)
          (soda packages interaction)
          (soda packages completion))

  ;; Prompt buffers are ordinary transient buffers.  The service owns only
  ;; their session stack and its interaction overlay placement.
  (define-record-type
    (minibuffer-session %make-minibuffer-session minibuffer-session?)
    (fields interaction buffer-id view-id origin-view-id surface-id rectangle
            (mutable completion minibuffer-session-completion minibuffer-session-completion-set!)))
  (define-record-type
    (prompt-snapshot %make-prompt-snapshot prompt-snapshot?)
    (fields session-id request input input-revision point selection origin-context
            completion-generation presentation))
  (define-record-type minibuffer-hook
    (fields owner procedure))
  (define-record-type
    (minibuffer-service %make-minibuffer-service minibuffer-service?)
    (fields state interactions owner keymap
            (mutable sessions minibuffer-service-sessions minibuffer-service-sessions-set!)
            (mutable setup-hooks minibuffer-service-setup-hooks minibuffer-service-setup-hooks-set!)
            (mutable exit-hooks minibuffer-service-exit-hooks minibuffer-service-exit-hooks-set!)
            (mutable registration minibuffer-service-registration minibuffer-service-registration-set!)))

  (define (session-for service interaction)
    (let loop ([sessions (minibuffer-service-sessions service)])
      (and (pair? sessions)
           (if (eq? interaction (minibuffer-session-interaction (car sessions)))
               (car sessions) (loop (cdr sessions))))))
  (define (minibuffer-service-current service)
    (and (minibuffer-service? service)
         (let ([sessions (minibuffer-service-sessions service)])
           (and (pair? sessions) (car sessions)))))
  (define (session-input service session)
    (let ([buffer (buffer-service-ref (host-state-buffers (minibuffer-service-state service))
                                      (minibuffer-session-buffer-id session) #f)])
      (and buffer (snapshot-string (buffer-state-document (buffer-state buffer))))))
  (define (minibuffer-session-snapshot service session)
    (unless (and (minibuffer-service? service) (minibuffer-session? session))
      (assertion-violation 'minibuffer-session-snapshot
                           "expected a minibuffer service and session" service session))
    (let* ([state (minibuffer-service-state service)]
           [buffer (buffer-service-ref (host-state-buffers state)
                                       (minibuffer-session-buffer-id session) #f)]
           [view (view-service-ref (host-state-views state)
                                   (minibuffer-session-view-id session) #f)]
           [selection (and view (view-state-selection (view-state view)))]
           [range (and selection (selection-primary-range selection))]
           [controller (minibuffer-session-completion session)]
           [surface (surface-service-ref (host-state-surfaces state)
                                         (minibuffer-session-surface-id session) #f)])
      (%make-prompt-snapshot
        (interaction-session-invocation-id (minibuffer-session-interaction session))
        (interaction-session-request (minibuffer-session-interaction session))
        (if buffer (snapshot-string (buffer-state-document (buffer-state buffer))) "")
        (if buffer (buffer-state-generation (buffer-state buffer)) 0)
        (if range (selection-range-head range) 0)
        selection
        (interaction-session-context (minibuffer-session-interaction session))
        (if controller (completion-controller-generation controller) 0)
        (list (cons 'surface-id (minibuffer-session-surface-id session))
              (cons 'surface-size (and surface (surface-size surface)))
              (cons 'overlay-rectangle (minibuffer-session-rectangle session))))))
  (define (notify-hooks! hooks snapshot)
    (for-each
      (lambda (hook)
        (guard (ignored [else #f])
          ((minibuffer-hook-procedure hook) snapshot)))
      hooks))
  (define (minibuffer-service-add-hook! service phase owner procedure)
    (unless (and (minibuffer-service? service) (memq phase '(setup exit))
                 (owner? owner) (procedure? procedure))
      (assertion-violation 'minibuffer-service-add-hook!
                           "expected a minibuffer service, phase, owner, and procedure"
                           service phase owner procedure))
    (owner-assert-active 'minibuffer-service-add-hook! owner)
    (let* ([hook (make-minibuffer-hook owner procedure)]
           [accessor (if (eq? phase 'setup)
                         minibuffer-service-setup-hooks
                         minibuffer-service-exit-hooks)]
           [setter (if (eq? phase 'setup)
                       minibuffer-service-setup-hooks-set!
                       minibuffer-service-exit-hooks-set!)])
      (setter service (append (accessor service) (list hook)))
      (make-registration
        owner
        (lambda ()
          (setter service
                  (filter (lambda (item) (not (eq? item hook)))
                          (accessor service)))))))
  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))
  (define (minibuffer-input-context service active view)
    (let ([session (minibuffer-service-current service)])
      (and session (= (minibuffer-session-view-id session) (view-id view))
           (make-input-context
             (active-context-view-id active) (active-context-buffer-id active)
             (list (make-input-layer 'minibuffer (minibuffer-service-keymap service) #f 'accept))
             (view-state-input-state (view-state view))))))
  (define (origin-surface service interaction)
    (surface-service-ref
      (host-state-surfaces (minibuffer-service-state service))
      (command-context-surface-id (interaction-session-context interaction)) #f))
  (define (open! service interaction)
    (let* ([state (minibuffer-service-state service)]
           [context (interaction-session-context interaction)]
           [origin (view-service-ref (host-state-views state) (command-context-view-id context) #f)]
           [surface (origin-surface service interaction)])
      (when (and origin surface)
        (let* ([configuration (view-state-configuration (view-state origin))]
               [request (interaction-session-request interaction)]
               [document (make-document (or (interaction-request-initial-value request) ""))]
               [buffer (buffer-service-create! (host-state-buffers state) (minibuffer-service-owner service)
                                               " *minibuffer*" document configuration)]
               [view (view-service-create! (host-state-views state) (minibuffer-service-owner service)
                                          buffer configuration)]
               [size (surface-size surface)]
               [rectangle (list (max 0 (- (cdr size) 1)) 0 (car size) 1)])
          (surface-push-interaction! surface (view-id view) rectangle)
          (let ([session
                  (%make-minibuffer-session interaction (buffer-id buffer) (view-id view)
                                             (view-id origin) (surface-id surface) rectangle #f)])
            (minibuffer-service-sessions-set!
              service (cons session (minibuffer-service-sessions service)))
            (notify-hooks! (minibuffer-service-setup-hooks service)
                           (minibuffer-session-snapshot service session))))))
        )
  (define (close! service interaction)
    (let ([session (session-for service interaction)])
      (when session
        (let ([controller (minibuffer-session-completion session)])
          (when controller
            (completion-controller-restore! controller
                                            (minibuffer-session-snapshot service session))))
        (notify-hooks! (minibuffer-service-exit-hooks service)
                       (minibuffer-session-snapshot service session))
        (minibuffer-service-sessions-set!
          service (filter (lambda (item) (not (eq? item session)))
                          (minibuffer-service-sessions service)))
        (let ([surface (surface-service-ref (host-state-surfaces (minibuffer-service-state service))
                                            (minibuffer-session-surface-id session) #f)])
          (when surface (surface-pop-interaction! surface)))
        (buffer-service-close-buffer! (host-state-buffers (minibuffer-service-state service))
                                      (minibuffer-session-buffer-id session)))))
  (define (minibuffer-service-submit! service)
    (let ([session (minibuffer-service-current service)])
      (and session
           (let* ([buffer (buffer-service-ref (host-state-buffers (minibuffer-service-state service))
                                               (minibuffer-session-buffer-id session) #f)]
                  [raw (and buffer (snapshot-string (buffer-state-document (buffer-state buffer))))]
                  [controller (minibuffer-session-completion session)]
                  [candidate (and controller (completion-controller-selected controller))]
                  [snapshot (minibuffer-session-snapshot service session)]
                  [request (interaction-session-request (minibuffer-session-interaction session))]
                  [policy (interaction-request-selection-policy
                            request)]
                  [value (if candidate (completion-candidate-insert-text candidate) raw)])
             (and value
                  (or (eq? policy 'free) candidate
                      (let ([validator (interaction-request-validator request)])
                        (or (and validator (validator value snapshot))
                            (and controller
                                 (completion-controller-valid-input? controller value snapshot)))))
                  (begin
                    (when controller (completion-controller-accept! controller
                                                                      snapshot))
                    (interaction-service-submit! (minibuffer-service-interactions service) value)))))))
  (define (minibuffer-service-refresh-completion! service)
    (let ([session (minibuffer-service-current service)])
      (and session
           (let* ([request (interaction-session-request (minibuffer-session-interaction session))]
                  [source (interaction-request-completion-source request)])
             (and (completion-source? source)
                  (let ([controller (or (minibuffer-session-completion session)
                                        (make-completion-controller
                                          source (interaction-request-selection-policy request)))])
                    (minibuffer-session-completion-set! session controller)
                    (completion-controller-refresh! controller
                                                    (minibuffer-session-snapshot service session))))))))
  (define (minibuffer-service-select-completion! service index)
    (let ([session (minibuffer-service-current service)])
      (and session (minibuffer-session-completion session)
           (completion-controller-select! (minibuffer-session-completion session) index
                                          (minibuffer-session-snapshot service session)))))
  (define (minibuffer-service-cancel! service)
    (and (minibuffer-service-current service)
         (interaction-service-cancel! (minibuffer-service-interactions service))))
  (define (make-minibuffer-service! state interactions owner)
    (unless (and (host-state? state) (interaction-service? interactions) (owner? owner))
      (assertion-violation 'make-minibuffer-service! "invalid minibuffer dependencies"))
    (let ([keymap (make-keymap 'minibuffer)])
      (keymap-bind! keymap (list (make-key-stroke 'enter #f 0)) 'minibuffer.accept)
      (keymap-bind! keymap (list (control-stroke #\j)) 'minibuffer.accept)
      (keymap-bind! keymap (list (control-stroke #\g)) 'minibuffer.cancel)
      (keymap-bind! keymap (list (make-key-stroke 'escape #f 0)) 'minibuffer.cancel)
      (let ([service (%make-minibuffer-service state interactions owner keymap '() '() '() #f)])
      (command-runtime-register-command!
        (host-state-command-runtime state)
        (make-command-definition
          'minibuffer.accept
          (lambda (context) (minibuffer-service-submit! service) (command-handled))
          owner "Accept the current minibuffer input." 'minibuffer #f))
      (command-runtime-register-command!
        (host-state-command-runtime state)
        (make-command-definition
          'minibuffer.cancel
          (lambda (context) (minibuffer-service-cancel! service) (command-handled))
          owner "Cancel the current minibuffer input." 'minibuffer #f))
      (minibuffer-service-registration-set!
        service
        (interaction-service-add-listener!
          interactions owner
          (lambda (kind interaction)
            (cond [(eq? kind 'opened) (open! service interaction)]
                  [(memq kind '(accepted cancelled)) (close! service interaction)]))))
      service)))
)
