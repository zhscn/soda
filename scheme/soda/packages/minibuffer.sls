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
          minibuffer-service-submit!
          minibuffer-service-cancel!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host internal buffer)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host value)
          (soda packages interaction))

  ;; Prompt buffers are ordinary transient buffers.  The service owns only
  ;; their session stack and its interaction overlay placement.
  (define-record-type
    (minibuffer-session %make-minibuffer-session minibuffer-session?)
    (fields interaction buffer-id view-id origin-view-id surface-id))
  (define-record-type
    (minibuffer-service %make-minibuffer-service minibuffer-service?)
    (fields state interactions owner
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
                                             (view-id origin) (surface-id surface))
                  (minibuffer-service-sessions service))))))
        )
  (define (close! service interaction)
    (let ([session (session-for service interaction)])
      (when session
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
                  [value (and buffer (snapshot-string (buffer-state-document (buffer-state buffer))))])
             (and value (interaction-service-submit! (minibuffer-service-interactions service) value))))))
  (define (minibuffer-service-cancel! service)
    (and (minibuffer-service-current service)
         (interaction-service-cancel! (minibuffer-service-interactions service))))
  (define (make-minibuffer-service! state interactions owner)
    (unless (and (host-state? state) (interaction-service? interactions) (owner? owner))
      (assertion-violation 'make-minibuffer-service! "invalid minibuffer dependencies"))
    (let ([service (%make-minibuffer-service state interactions owner '() #f)])
      (minibuffer-service-registration-set!
        service
        (interaction-service-add-listener!
          interactions owner
          (lambda (kind interaction)
            (cond [(eq? kind 'opened) (open! service interaction)]
                  [(memq kind '(accepted cancelled)) (close! service interaction)]))))
      service))
)
