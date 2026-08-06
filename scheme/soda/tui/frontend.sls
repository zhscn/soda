(library (soda tui frontend)
  (export make-frontend
          frontend?
          frontend-host-state
          frontend-surface
          frontend-dirty?
          frontend-enqueue!
          frontend-dispatch-input!
          frontend-handle-message!
          frontend-drain!
          frontend-render!
          frontend-step!
          frontend-resize!
          frontend-close!)
  (import (rnrs)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host condition)
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host render)
          (soda host render-service)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host runtime)
          (soda host value)
          (soda view theme))

  ;; Frontend owns the control-flow boundary between a Surface's normalized
  ;; input and the host queue.  It does not interpret text, commands, or
  ;; keymap layers: those policies are injected by feature packages.
  (define-record-type
    (frontend %make-frontend frontend?)
    (fields
      (immutable host-state frontend-host-state)
      (immutable surface frontend-surface)
      (immutable resolve-input-context frontend-resolve-input-context)
      (immutable handle-disposition frontend-handle-disposition)
      (immutable present! frontend-present!)
      (immutable render-service frontend-render-service)
      (immutable theme frontend-theme)
      (mutable dirty? frontend-dirty? frontend-dirty?-set!)
      (mutable update-registration frontend-update-registration
                                   frontend-update-registration-set!)
      (mutable host-update-registration frontend-host-update-registration
                                        frontend-host-update-registration-set!)
      (mutable closed? frontend-closed? frontend-closed?-set!)))

  (define (require-open who value)
    (unless (frontend? value)
      (assertion-violation who "expected a frontend" value))
    (when (frontend-closed? value)
      (assertion-violation who "frontend is closed" value)))

  (define (registered-surface? state surface)
    (eq? surface
         (surface-service-ref
           (host-state-surfaces state) (surface-id surface) #f)))

  (define (make-frontend state surface resolve-input-context handle-disposition
                         present! render-service theme)
    (unless (and (host-state? state) (not (host-state-closed? state))
                 (surface? surface) (registered-surface? state surface)
                 (procedure? resolve-input-context)
                 (procedure? handle-disposition)
                 (procedure? present!)
                 (render-service? render-service)
                 (theme? theme))
      (assertion-violation 'make-frontend "invalid frontend dependencies"))
    (let* ([dispatcher (host-state-dispatch state)]
           [owner (host-state-owner state)]
           [value
            (%make-frontend state surface resolve-input-context handle-disposition
                            present! render-service theme #t #f #f #f)])
      (frontend-update-registration-set!
        value
        (dispatcher-add-listener!
          dispatcher owner (lambda (update) (frontend-dirty?-set! value #t))))
      (frontend-host-update-registration-set!
        value
        (dispatcher-add-host-listener!
          dispatcher owner (lambda (update) (frontend-dirty?-set! value #t))))
      value))

  (define (frontend-enqueue! value message)
    (require-open 'frontend-enqueue! value)
    (runtime-enqueue! (host-state-runtime (frontend-host-state value)) message))

  (define (active-view value)
    (let* ([state (frontend-host-state value)]
           [surface (frontend-surface value)]
           [context (surface-active-context surface (host-state-views state))]
           [view (and context
                      (view-service-ref
                        (host-state-views state) (active-context-view-id context) #f))])
      (and context view (cons context view))))

  (define (validate-input-context! context active view)
    (unless (and (input-context? context)
                 (= (input-context-view-id context) (active-context-view-id active))
                 (= (input-context-buffer-id context) (active-context-buffer-id active))
                 (eq? (input-context-stack context)
                      (view-state-input-state (view-state view))))
      (assertion-violation
        'frontend-dispatch-input!
        "input context does not describe the active View"
        context active view)))

  (define (event-key-sequence context event)
    (if (key-event? event)
        (append (or (input-stack-pending-sequence (input-context-stack context)) '())
                (list (key-event->key-stroke event)))
        '()))

  (define (make-active-command-context value active view event sequence prefix-argument)
    (let* ([state (frontend-host-state value)]
           [current-view
            (or (view-service-ref
                  (host-state-views state) (active-context-view-id active) #f)
                (assertion-violation 'frontend-dispatch-input!
                                     "active View closed during input dispatch" active))]
           [buffer (view-buffer current-view)])
      (make-command-context
        #f
        (active-context-surface-id active)
        (active-context-window-id active)
        (view-id current-view)
        (buffer-id buffer)
        (buffer-state buffer)
        (view-state current-view)
        event
        sequence
        prefix-argument
        active
        'tui-frontend)))

  (define (enqueue-disposition-result! value result)
    (when result
      (unless (or (command-invoke-message? result)
                  (command-resume-message? result))
        (assertion-violation
          'frontend-dispatch-input!
          "input disposition handler returned an unsupported runtime message"
          result))
      (command-runtime-enqueue!
        (host-state-command-runtime (frontend-host-state value)) result)))

  (define (frontend-dispatch-input! value event)
    (require-open 'frontend-dispatch-input! value)
    (unless (input-event? event)
      (assertion-violation 'frontend-dispatch-input! "expected an input event" event))
    ;; Surface messages are echo-area feedback.  The next user input clears a
    ;; previous message before dispatching its command, while a command that
    ;; emits a new message publishes it again at the same boundary.
    (when (surface-status-message (frontend-surface value))
      (dispatcher-dispatch-host!
        (host-state-dispatch (frontend-host-state value))
        (make-set-surface-message-operation
          (surface-id (frontend-surface value)) #f)))
    (let ([current (active-view value)])
      (and current
           (let* ([active (car current)]
                  [view (cdr current)]
                  [context ((frontend-resolve-input-context value) active view)]
                  [_context-valid (validate-input-context! context active view)]
                  [sequence (event-key-sequence context event)]
                  [disposition (input-dispatch context event)]
                  [next-input (input-disposition-input-state disposition)])
             ;; InputState is published through the Dispatcher before a command
             ;; snapshot is made. The command therefore observes the reset
             ;; prefix/session state that the next event will observe too.
             (unless (eq? next-input (view-state-input-state (view-state view)))
               (dispatcher-dispatch-view!
                 (host-state-dispatch (frontend-host-state value))
                 (make-view-transaction-spec
                   (view-id view) (view-state-generation (view-state view))
                   #f #f next-input '() '() #f)))
               (let ([command-context
                    (make-active-command-context
                      value active view event sequence
                      (input-stack-pending-argument (input-context-stack context)))])
               (case (input-disposition-kind disposition)
                 [(command)
                  (let ([name (input-disposition-value disposition)])
                    (unless (symbol? name)
                      (assertion-violation 'frontend-dispatch-input!
                                           "keymap command binding must be a symbol" name))
                    (command-runtime-enqueue!
                      (host-state-command-runtime (frontend-host-state value))
                      ;; Keymap bindings preserve the command declaration:
                      ;; commands with an InteractivePlan (save, close,
                      ;; search, quit) collect their arguments through the
                      ;; interaction service; primitive edit commands run
                      ;; immediately with no synthetic reader.
                      (make-command-invoke-message
                        name command-context '()
                        (command-runtime-command-interactive?
                          (host-state-command-runtime (frontend-host-state value))
                          name))))]
                 [else
                  (enqueue-disposition-result!
                    value
                    ((frontend-handle-disposition value)
                     command-context disposition))])
               disposition)))))

  (define (frontend-handle-message! value message)
    (require-open 'frontend-handle-message! value)
    (and (surface-input-message? message)
         (= (surface-input-message-surface-id message)
            (surface-id (frontend-surface value)))
         (frontend-dispatch-input! value (surface-input-message-event message))))

  (define (frontend-handle-queued-message! value message)
    (guard
      (condition
        [else
         (condition-service-capture
           (host-state-conditions (frontend-host-state value))
           (host-state-owner (frontend-host-state value))
           (list 'tui-frontend message condition)
           (lambda arguments #f)
           '(dismiss))
         #t])
      (frontend-handle-message! value message)))

  (define frontend-drain!
    (case-lambda
      [(value)
       (frontend-drain! value #f)]
      [(value limit)
       (require-open 'frontend-drain! value)
       (if limit
           (host-state-run!
             (frontend-host-state value)
             (lambda (message) (frontend-handle-queued-message! value message))
             limit)
           (host-state-run!
             (frontend-host-state value)
             (lambda (message) (frontend-handle-queued-message! value message))))]))

  (define (add-render-occurrence groups id occurrence)
    (let loop ([remaining groups])
      (cond [(null? remaining) (list (cons id (list occurrence)))]
            [(= id (caar remaining))
             (cons (cons id (cons occurrence (cdar remaining))) (cdr remaining))]
            [else (cons (car remaining) (loop (cdr remaining)))])))

  (define (frontend-render! value)
    (require-open 'frontend-render! value)
    (if (not (frontend-dirty? value))
        #f
        (let ([render
               (render-service-render!
                 (frontend-render-service value)
                 (frontend-surface value)
                 (host-state-views (frontend-host-state value)))])
          ((frontend-present! value) render (frontend-theme value))
          (let loop ([rendered (surface-render-rendered-views render)] [groups '()])
            (if (null? rendered)
                (for-each
                  (lambda (group)
                    (frontend-enqueue!
                      value
                      (lambda ()
                        (when (view-service-publish-occurrences!
                                (host-state-views (frontend-host-state value))
                                (car group) (reverse (cdr group)))
                          (frontend-dirty?-set! value #t)))))
                  groups)
                (let ([item (car rendered)])
                  (loop (cdr rendered)
                        (add-render-occurrence groups (rendered-view-view-id item)
                                        (rendered-view-occurrence item))))))
          (for-each
            (lambda (rendered)
              (for-each
                (lambda (failure)
                  (frontend-enqueue!
                    value
                    (lambda ()
                      (when (view-service-retire-projection-failure!
                              (host-state-views (frontend-host-state value))
                              (rendered-view-view-id rendered)
                              (rendered-view-projection-generation rendered)
                              (car failure) (cadr failure))
                        (frontend-dirty?-set! value #t)))))
                (rendered-view-transform-failures rendered)))
            (surface-render-rendered-views render))
          (frontend-dirty?-set! value #f)
          render)))

  (define frontend-step!
    (case-lambda
      [(value)
       (frontend-step! value #f)]
      [(value limit)
       (let ([processed (frontend-drain! value limit)])
         (frontend-render! value)
         processed)]))

  (define (frontend-resize! value size)
    (require-open 'frontend-resize! value)
    (dispatcher-dispatch-host!
      (host-state-dispatch (frontend-host-state value))
      (make-resize-surface-operation (surface-id (frontend-surface value)) size)))

  (define (frontend-close! value)
    (unless (frontend? value)
      (assertion-violation 'frontend-close! "expected a frontend" value))
    (if (frontend-closed? value)
        #f
        (begin
          (frontend-closed?-set! value #t)
          (let ([update (frontend-update-registration value)]
                [host-update (frontend-host-update-registration value)])
            (when update (registration-close! update))
            (when host-update (registration-close! host-update))
            (frontend-update-registration-set! value #f)
            (frontend-host-update-registration-set! value #f))
          #t)))
)
