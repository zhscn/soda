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
          frontend-set-theme!
          frontend-close!)
  (import (rnrs)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host command-runtime)
          (soda host buffer)
          (soda host context)
          (soda host dispatch)
          (soda host frontend)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host render)
          (soda host render-service)
          (soda host state)
          (soda host surface)
          (soda host value)
          (soda host view)
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
      (mutable theme frontend-theme frontend-theme-set!)
      (mutable dirty? frontend-dirty? frontend-dirty?-set!)
      (mutable pending-scroll frontend-pending-scroll frontend-pending-scroll-set!)
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
    (host-frontend-surface-registered? state surface))

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
    (let ([value
            (%make-frontend state surface resolve-input-context handle-disposition
                            present! render-service theme #t #f #f #f #f)])
      (frontend-update-registration-set!
        value
        (host-frontend-add-update-listener!
          state
          (lambda (update)
            (frontend-dirty?-set! value #t)
            (let ([request (editor-update-scroll-request update)])
              (when (scroll-request? request)
                (frontend-pending-scroll-set! value request)))
            (frontend-resolve-scroll-request! value))))
      (frontend-host-update-registration-set!
        value
        (host-frontend-add-host-listener!
          state (lambda (update) (frontend-dirty?-set! value #t))))
      value))

  (define (frontend-enqueue! value message)
    (require-open 'frontend-enqueue! value)
    (host-frontend-enqueue! (frontend-host-state value) message))

  (define (active-view value)
    (host-frontend-active-view
      (frontend-host-state value) (frontend-surface value)))

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

  ;; A layout is command input only while it still describes the same document,
  ;; viewport, and View configuration.  Selection and InputState may change
  ;; between consecutive key events without invalidating DisplayMap geometry.
  (define (active-command-layout value active view)
    (let ([render (render-service-last-render (frontend-render-service value))]
          [state (view-state view)]
          [buffer-state (buffer-state (view-buffer view))])
      (and render
           (let find ([rendered (surface-render-rendered-views render)])
             (and (pair? rendered)
                  (let ([candidate (car rendered)])
                    (if (and (= (rendered-view-view-id candidate) (view-id view))
                             (= (rendered-view-window-id candidate)
                                (active-context-window-id active))
                             (= (rendered-view-buffer-generation candidate)
                                (buffer-state-generation buffer-state))
                             (viewport=? (rendered-view-viewport candidate)
                                         (view-state-viewport state))
                             (eq? (rendered-view-configuration candidate)
                                  (view-state-configuration state)))
                        (rendered-view-layout candidate)
                        (find (cdr rendered)))))))))

  ;; Scroll requests are resolved after a command publishes immutable editor
  ;; state and before the next presentation.  This boundary has both the
  ;; command's window identity and the last compatible TextLayout, while
  ;; command packages remain independent of viewport measurement.
  (define (frontend-resolve-scroll-request! value)
    (let ([request (frontend-pending-scroll value)])
      (when request
        (let ([current (active-view value)])
          (when current
            (let* ([active (car current)]
                   [view (cdr current)]
                   [layout (active-command-layout value active view)])
              (when (and layout
                         (host-frontend-resolve-scroll-request!
                           (frontend-host-state value) active layout request))
                (frontend-pending-scroll-set! value #f))))))))

  (define (make-active-command-context value active view event sequence prefix-argument)
    (host-frontend-make-command-context
      (frontend-host-state value) active event sequence prefix-argument
      'tui-frontend (active-command-layout value active view)))

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
    (when (host-frontend-surface-message
            (frontend-host-state value) (frontend-surface value))
      (host-frontend-dispatch-host!
        (frontend-host-state value)
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
               (host-frontend-dispatch-view!
                 (frontend-host-state value)
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
         (host-frontend-capture-condition!
           (frontend-host-state value) (list 'tui-frontend message condition))
         #t])
      (frontend-handle-message! value message)))

  (define frontend-drain!
    (case-lambda
      [(value)
       (frontend-drain! value #f)]
      [(value limit)
       (require-open 'frontend-drain! value)
       (if limit
           (host-frontend-run!
             (frontend-host-state value)
             (lambda (message) (frontend-handle-queued-message! value message))
             limit)
           (host-frontend-run!
             (frontend-host-state value)
             (lambda (message) (frontend-handle-queued-message! value message))))]))

  (define (frontend-render! value)
    (require-open 'frontend-render! value)
    (if (not (frontend-dirty? value))
        #f
        (begin
          ;; A scroll intent resolved from this render may publish a newer
          ;; viewport and set dirty again.  Clear the old damage first so that
          ;; notification is retained for the follow-up render.
          (frontend-dirty?-set! value #f)
          (let ([render
               (host-frontend-render!
                 (frontend-host-state value) (frontend-render-service value)
                 (frontend-surface value))])
          ((frontend-present! value) render (frontend-theme value))
          (host-frontend-publish-render-feedback!
            (frontend-host-state value) render
            (lambda () (frontend-dirty?-set! value #t)))
          (frontend-resolve-scroll-request! value)
          render))))

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
    (host-frontend-dispatch-host!
      (frontend-host-state value)
      (make-resize-surface-operation (surface-id (frontend-surface value)) size)))

  (define (frontend-set-theme! value theme)
    (require-open 'frontend-set-theme! value)
    (unless (theme? theme)
      (assertion-violation 'frontend-set-theme! "expected a Theme" theme))
    (unless (eq? theme (frontend-theme value))
      (frontend-theme-set! value theme)
      (frontend-dirty?-set! value #t))
    theme)

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
