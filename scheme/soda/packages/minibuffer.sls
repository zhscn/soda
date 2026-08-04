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
          prompt-snapshot-session-id prompt-snapshot-input
          prompt-snapshot-origin-context prompt-snapshot-completion-generation
          minibuffer-service-refresh-completion!
          minibuffer-service-select-completion!
          minibuffer-input-context
          minibuffer-service-submit!
          minibuffer-service-cancel!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
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
    (fields interaction buffer-id view-id origin-view-id surface-id
            (mutable completion minibuffer-session-completion minibuffer-session-completion-set!)))
  (define-record-type
    (prompt-snapshot %make-prompt-snapshot prompt-snapshot?)
    (fields session-id input origin-context completion-generation))
  (define-record-type
    (minibuffer-service %make-minibuffer-service minibuffer-service?)
    (fields state interactions owner keymap
            (mutable sessions minibuffer-service-sessions minibuffer-service-sessions-set!)
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
  (define (session-snapshot service session)
    (%make-prompt-snapshot
      (interaction-session-invocation-id (minibuffer-session-interaction session))
      (or (session-input service session) "")
      (interaction-session-context (minibuffer-session-interaction session))
      (let ([controller (minibuffer-session-completion session)])
        (if controller (completion-controller-generation controller) 0))))
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
          (minibuffer-service-sessions-set!
            service
            (cons (%make-minibuffer-session interaction (buffer-id buffer) (view-id view)
                                             (view-id origin) (surface-id surface) #f)
                  (minibuffer-service-sessions service))))))
        )
  (define (close! service interaction)
    (let ([session (session-for service interaction)])
      (when session
        (let ([controller (minibuffer-session-completion session)])
          (when controller (completion-controller-restore! controller (session-snapshot service session))))
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
                  [policy (interaction-request-selection-policy
                            (interaction-session-request (minibuffer-session-interaction session)))]
                  [value (if candidate (completion-candidate-insert-text candidate) raw)])
             (and value (or (eq? policy 'free) candidate)
                  (begin
                    (when controller (completion-controller-accept! controller
                                                                      (session-snapshot service session)))
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
                    (completion-controller-refresh! controller (session-snapshot service session))))))))
  (define (minibuffer-service-select-completion! service index)
    (let ([session (minibuffer-service-current service)])
      (and session (minibuffer-session-completion session)
           (completion-controller-select! (minibuffer-session-completion session) index
                                          (session-snapshot service session)))))
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
      (let ([service (%make-minibuffer-service state interactions owner keymap '() #f)])
      (minibuffer-service-registration-set!
        service
        (interaction-service-add-listener!
          interactions owner
          (lambda (kind interaction)
            (cond [(eq? kind 'opened) (open! service interaction)]
                  [(memq kind '(accepted cancelled)) (close! service interaction)]))))
      service)))
)
