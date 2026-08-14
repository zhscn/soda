(library (soda tui frontend)
  (export make-frontend
          frontend?
          frontend-host-state
          frontend-surface
          frontend-dirty?
          frontend-enqueue!
          frontend-pending?
          frontend-step-input-burst!
          frontend-step-action!
          frontend-step!
          frontend-resize!
          frontend-cancel-pointer-capture!
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
          (soda host feedback)
          (soda host frontend)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host render)
          (soda host render-service)
          (soda host prefix-guidance)
          (soda host state)
          (soda host surface)
          (soda host value)
          (soda host view)
          (soda tui input-scheduler)
          (soda view theme))

  ;; Frontend owns the control-flow boundary between a Surface's normalized
  ;; input and the host queue.  It does not interpret text, commands, or
  ;; keymap layers: those policies are injected by feature packages.
  (define-record-type
    (frontend %make-frontend frontend?)
    (fields
      (immutable owner frontend-owner)
      (immutable host-state frontend-host-state)
      (immutable surface frontend-surface)
      (immutable resolve-input-context frontend-resolve-input-context)
      (immutable handle-disposition frontend-handle-disposition)
      (immutable present! frontend-present!)
      (immutable render-service frontend-render-service)
      (immutable viewport-resolution-cache frontend-viewport-resolution-cache)
      (immutable input-scheduler frontend-input-scheduler)
      (mutable theme frontend-theme frontend-theme-set!)
      (mutable dirty? frontend-dirty? frontend-dirty?-set!)
      (mutable defer-presentation? frontend-defer-presentation?
                                   frontend-defer-presentation?-set!)
      (mutable refreshing-presentation? frontend-refreshing-presentation?
                                        frontend-refreshing-presentation?-set!)
      (mutable pending-scroll frontend-pending-scroll frontend-pending-scroll-set!)
      (mutable routing-registration frontend-routing-registration
                                    frontend-routing-registration-set!)
      (mutable update-registration frontend-update-registration
                                   frontend-update-registration-set!)
      (mutable host-update-registration frontend-host-update-registration
                                        frontend-host-update-registration-set!)
      (mutable pointer-capture frontend-pointer-capture
                              frontend-pointer-capture-set!)
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
    (let* ([owner (make-owner 'frontend)]
           [value
            (%make-frontend owner state surface resolve-input-context handle-disposition
                            present! render-service (make-viewport-resolution-cache)
                            (make-input-scheduler state)
                            theme #t #f #f #f #f #f #f #f #f)])
      (frontend-routing-registration-set!
        value
        (host-frontend-register-handler!
          state (surface-id surface) owner
          (lambda (message) (frontend-handle-queued-message! value message))))
      (frontend-update-registration-set!
        value
        (host-frontend-add-update-listener!
          state
          (lambda (update)
            (frontend-dirty?-set! value #t)
            (frontend-update-presentation! value)
            (frontend-reconcile-pointer-capture! value)
            (let ([request (editor-update-scroll-request update)])
              (when (scroll-request? request)
                (frontend-handle-scroll-request! value request))))))
      (frontend-host-update-registration-set!
        value
        (host-frontend-add-host-listener!
          state
          (lambda (update)
            (frontend-dirty?-set! value #t)
            (frontend-update-presentation! value)
            (frontend-reconcile-pointer-capture! value))))
      (command-runtime-add-hook!
        (host-state-command-runtime state)
        'execution-record owner
        (string->symbol
          (string-append "frontend-activate-transient-"
                         (number->string (surface-id surface))))
        (lambda (record)
          (frontend-install-pending-transient! value)
          (frontend-update-presentation! value)))
      (frontend-update-presentation! value)
      value))

  (define (frontend-cancel-pointer-capture! value)
    (require-open 'frontend-cancel-pointer-capture! value)
    (let ([capture (frontend-pointer-capture value)])
      (frontend-pointer-capture-set! value #f)
      (and capture #t)))

  (define (frontend-reconcile-pointer-capture! value)
    (let ([capture (frontend-pointer-capture value)])
      (when (and capture
                 (not (host-frontend-pointer-capture-current?
                        (frontend-host-state value)
                        (frontend-surface value) capture)))
        (frontend-pointer-capture-set! value #f))))

  (define (frontend-enqueue! value message)
    (require-open 'frontend-enqueue! value)
    (input-scheduler-enqueue! (frontend-input-scheduler value) message))

  (define (frontend-pending? value)
    (require-open 'frontend-pending? value)
    (host-frontend-pending? (frontend-host-state value)))

  (define (active-view value)
    (host-frontend-active-view
      (frontend-host-state value) (frontend-surface value)))

  (define (frontend-refresh-prefix-guidance! value)
    (let ([current (active-view value)])
      (when current
        (let* ([active (car current)]
               [view (cdr current)]
               [context ((frontend-resolve-input-context value) active view)]
               [pending
                (or (input-stack-pending-sequence
                      (input-context-stack context)) '())])
          (validate-input-context! context active view)
          (host-frontend-dispatch-host!
            (frontend-host-state value)
            (make-set-surface-prefix-guidance-operation
              (surface-id (frontend-surface value))
              (if (null? pending)
                  '()
                  (command-prefix-guidance
                    (host-state-command-runtime (frontend-host-state value))
                    (make-active-command-context
                      value active view #f pending
                      (input-stack-prefix-argument (input-context-stack context))
                      active context)
                    context))))))))

  (define (frontend-update-presentation! value)
    (unless (frontend-refreshing-presentation? value)
      (dynamic-wind
        (lambda () (frontend-refreshing-presentation?-set! value #t))
        (lambda () (frontend-refresh-prefix-guidance! value))
        (lambda () (frontend-refreshing-presentation?-set! value #f)))))

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

  (define (frontend-install-command-transient! value active view)
    (let* ([runtime (host-state-command-runtime (frontend-host-state value))]
           [state
            (command-runtime-take-transient-state!
              runtime (active-context-surface-id active))])
      (when state
        (let ([view-state (view-state view)])
          (host-frontend-dispatch-view!
            (frontend-host-state value)
            (make-view-transaction-spec
              (view-id view) (view-state-generation view-state)
              #f #f
              (input-stack-push (view-state-input-state view-state) state)
              '() '() #f))))))

  (define (frontend-install-pending-transient! value)
    (let ([current (active-view value)])
      (when current
        (frontend-install-command-transient! value (car current) (cdr current)))))

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
  (define (deferred-reveal-request? value request)
    (and (frontend-defer-presentation? value)
         (eq? (scroll-request-kind request) 'reveal-point)))

  ;; Point motion publishes reveal-point after every command.  During one
  ;; terminal input burst only its final selection can affect the committed
  ;; viewport, so retain that last intent until the batch is rendered.  Other
  ;; scroll requests are barriers: page and explicit scrolling remain ordered
  ;; relative to the next input action.
  (define (frontend-handle-scroll-request! value request)
    (when (and (not (deferred-reveal-request? value request))
               (frontend-pending-scroll value))
      (frontend-resolve-scroll-request! value))
    (frontend-pending-scroll-set! value request)
    (unless (deferred-reveal-request? value request)
      (frontend-resolve-scroll-request! value)))

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
                           (frontend-host-state value) active layout request
                           (frontend-viewport-resolution-cache value)))
                (frontend-pending-scroll-set! value #f))))))))

  (define (make-active-command-context
            value active view event sequence prefix-argument target input-context)
    (host-frontend-make-command-context
      (frontend-host-state value) active event sequence prefix-argument
      'tui-frontend (active-command-layout value active view) target
      (input-layers-snapshot (input-context-layers input-context))))

  (define (pointer-route value event)
    (let* ([render
            (render-service-last-render (frontend-render-service value))]
           [capture (frontend-pointer-capture value)]
           [phase (pointer-event-phase event)]
           [candidate
            (and render
                 (or capture (not (memq phase '(move release))))
                 (if (and capture (memq phase '(move release)))
                     (surface-render-hit-test-window
                       render (surface-hit-window-id capture)
                       (pointer-event-row event) (pointer-event-column event))
                     (surface-render-hit-test
                       render (pointer-event-row event)
                       (pointer-event-column event))))]
           [target
            (and candidate
                 (host-frontend-pointer-target
                   (frontend-host-state value)
                   (frontend-surface value) candidate))])
      (cond
        [(eq? phase 'press)
         (frontend-pointer-capture-set! value (and target candidate))
         (when target
           (host-frontend-dispatch-host!
             (frontend-host-state value)
             (make-focus-window-operation
               (surface-id (frontend-surface value))
               (surface-hit-window-id candidate))))]
        [(eq? phase 'release)
         (frontend-pointer-capture-set! value #f)])
      (and target (list (car target) (cdr target) candidate))))

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
    (input-scheduler-begin-cycle! (frontend-input-scheduler value))
    (let* ([route (and (pointer-event? event) (pointer-route value event))]
           [current
            (if route
                (cons (car route) (cadr route))
                (and (not (pointer-event? event)) (active-view value)))])
      (and current
           (let* ([active (car current)]
                  [view (cdr current)]
                  [context ((frontend-resolve-input-context value) active view)]
                  [_context-valid (validate-input-context! context active view)]
                  [sequence (event-key-sequence context event)]
                  [disposition (input-dispatch context event)]
                  [next-input (input-disposition-input-state disposition)])
             ;; Feedback lifetime follows semantic input rather than terminal
             ;; event shape.  Prefixes, text, and commands retire the prior
             ;; command result; ignored input retains it.  A routed pointer
             ;; action changes the selected Window and is likewise a new
             ;; editor action even when it has no key disposition.
             (when (or route (input-disposition-clears-feedback? disposition))
               (host-frontend-clear-surface-feedback!
                 (frontend-host-state value) (frontend-surface value)))
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
                      (input-stack-prefix-argument (input-context-stack context))
                      (if route (caddr route) active)
                      context)])
               (case (input-disposition-kind disposition)
                 [(command)
                  (let ([name (input-disposition-value disposition)])
                    (unless (symbol? name)
                      (assertion-violation 'frontend-dispatch-input!
                                           "keymap command binding must be a symbol" name))
                    (let ([runtime
                           (host-state-command-runtime (frontend-host-state value))])
                      ;; Keymaps compose independently of mode ownership, so
                      ;; an optional or configured binding can resolve before
                      ;; its command applies to this Buffer.  Treat that as a
                      ;; normal input result instead of queueing an invocation
                      ;; that will only fail at the runtime boundary.  The
                      ;; runtime retains its own availability check for queued
                      ;; and asynchronous invocations.
                      (if (command-runtime-command-available?
                            runtime name command-context)
                          (command-runtime-enqueue!
                            runtime
                            ;; Keymap bindings preserve the command declaration:
                            ;; commands with an InteractivePlan (save, close,
                            ;; search, quit) collect their arguments through the
                            ;; interaction service; primitive edit commands run
                            ;; immediately with no synthetic reader.
                            (make-command-invoke-message
                              name command-context '()
                              (command-runtime-command-interactive? runtime name)
                              (or (input-disposition-requested-command disposition)
                                  name)))
                          (host-frontend-dispatch-host!
                            (frontend-host-state value)
                            (make-set-surface-feedback-operation
                              (surface-id (frontend-surface value))
                              (make-user-feedback
                                (string-append
                                  (key-sequence-label sequence)
                                  " is not available in this context")
                                'warning))))))]
                 [else
                  (let ([result
                         ((frontend-handle-disposition value)
                          command-context disposition)])
                    (enqueue-disposition-result! value result)
                    (when (and (eq? (input-disposition-kind disposition) 'undefined)
                               (not result))
                      (host-frontend-dispatch-host!
                        (frontend-host-state value)
                        (make-set-surface-feedback-operation
                          (surface-id (frontend-surface value))
                          (make-user-feedback
                            (string-append
                              (key-sequence-label
                                (input-disposition-value disposition))
                              " is undefined")
                            'warning)))))])
               disposition)))))

  (define (frontend-handle-message! value message)
    (require-open 'frontend-handle-message! value)
    (and (surface-input-message? message)
         (= (surface-input-message-surface-id message)
            (surface-id (frontend-surface value)))
         (let ([event (surface-input-message-event message)])
           ;; Key release reports carry no editor action. Dropping them at the
           ;; frontend boundary also avoids clearing feedback and presenting a
           ;; second frame for one physical key cycle.
           (if (and (key-event? event) (eq? (key-event-type event) 'release))
               #t
               (begin
                 ;; Input coordinates and visual-row motion are interpreted
                 ;; against a committed Frame.  Publish preceding host damage
                 ;; before starting the next input transaction.
                 (when (and (not (frontend-defer-presentation? value))
                            (frontend-dirty? value)
                            (input-scheduler-presentation-ready?
                              (frontend-input-scheduler value)))
                   (%frontend-render! value))
                 (frontend-dispatch-input! value event))))))

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
           (host-frontend-run! (frontend-host-state value) limit)
           (host-frontend-run! (frontend-host-state value)))]))

  (define (%frontend-render! value)
    (require-open 'frontend-render! value)
    (if (not (frontend-dirty? value))
        #f
        (let stage ()
          ;; A request may need a layout for a View that has never been
          ;; presented. Render it provisionally, resolve the semantic scroll
          ;; intent, then commit only the Frame for the resulting viewport.
          ;; This keeps an off-screen point from flashing for one frame.
          (frontend-dirty?-set! value #f)
          (let ([render
                 (host-frontend-render!
                   (frontend-host-state value) (frontend-render-service value)
                   (frontend-surface value))])
            (frontend-resolve-scroll-request! value)
            (if (and (frontend-dirty? value)
                     (not (frontend-pending-scroll value)))
                (stage)
                (begin
                  ((frontend-present! value) render (frontend-theme value))
                  (host-frontend-publish-render-feedback!
                    (frontend-host-state value) render
                    (lambda () (frontend-dirty?-set! value #t)))
                  render))))))

  ;; Public callers cannot present a partially dispatched input action.
  (define (frontend-render! value)
    (and (input-scheduler-presentation-ready?
           (frontend-input-scheduler value))
         (%frontend-render! value)))

  (define (frontend-render-if-ready! value)
    (and (input-scheduler-presentation-ready?
           (frontend-input-scheduler value))
         (%frontend-render! value)))

  ;; Runtime work and completed user actions are separate budgets.  This keeps
  ;; the host queue generic while allowing an interactive frontend to yield at
  ;; an action boundary instead of after an arbitrary number of messages.
  (define (frontend-advance! who value limit action-limit present-each-action?)
    (require-open who value)
    (unless (and (integer? limit) (exact? limit) (> limit 0))
      (assertion-violation who "limit must be a positive exact integer" limit))
    (let ([previous-defer? (frontend-defer-presentation? value)])
      (dynamic-wind
        (lambda ()
          (when (not present-each-action?)
            (frontend-defer-presentation?-set! value #t)))
        (lambda ()
          (let loop ([processed 0]
                     [completed
                      (input-scheduler-completed-generation
                        (frontend-input-scheduler value))]
                     [actions 0]
                     [presented? #f])
            (if (or (>= processed limit)
                    (and action-limit (>= actions action-limit))
                    (not (frontend-pending? value)))
                (begin
                  (unless presented? (frontend-render-if-ready! value))
                  processed)
                (let* ([count (frontend-drain! value 1)]
                       [next-completed
                        (input-scheduler-completed-generation
                          (frontend-input-scheduler value))]
                       [cycle-completed? (> next-completed completed)])
                  (when (and cycle-completed? present-each-action?)
                    (frontend-render-if-ready! value))
                  (loop (+ processed count) next-completed
                        (+ actions (if cycle-completed? 1 0))
                        (or presented? (and cycle-completed? present-each-action?)))))))
        (lambda ()
          (frontend-defer-presentation?-set! value previous-defer?)))))

  (define frontend-step!
    (case-lambda
      [(value) (frontend-step! value 32)]
      [(value limit) (frontend-advance! 'frontend-step! value limit #f #t)]))

  ;; A terminal read is one ordered input burst.  Its actions still run in
  ;; order and each command receives the preceding command's state, but their
  ;; Frames are coalesced into one presentation.  This keeps movement paced by
  ;; available terminal input rather than by render round trips.
  (define (frontend-step-input-burst! value action-count)
    (unless (and (integer? action-count) (exact? action-count)
                 (positive? action-count))
      (assertion-violation
        'frontend-step-input-burst! "expected a positive action count" action-count))
    (frontend-advance!
      'frontend-step-input-burst! value
      (max 64 (* action-count 16)) action-count #f))

  ;; Advance through exactly one complete user action.  Internal runtime
  ;; messages needed by that action remain atomic, but control returns as soon
  ;; as its cycle boundary commits so a frontend can poll for newer input
  ;; before starting queued repeat debt.
  (define frontend-step-action!
    (case-lambda
      [(value) (frontend-step-action! value 32)]
      [(value limit)
       (frontend-advance! 'frontend-step-action! value limit 1 #t)]))

  (define (frontend-resize! value size)
    (require-open 'frontend-resize! value)
    (let ([changed
           (host-frontend-dispatch-host!
             (frontend-host-state value)
             (make-resize-surface-operation
               (surface-id (frontend-surface value)) size))])
      (when changed
        (let ([current (active-view value)])
          (when current
            (let ([active (car current)] [view (cdr current)])
              ;; Resize invalidates the geometry used by any older scroll
              ;; intent. Reveal the active point against the new layout.
              (frontend-pending-scroll-set!
                value
                (make-scroll-request
                  'reveal-point
                  (active-context-surface-id active)
                  (active-context-window-id active)
                  (view-id view)))))))
      changed))

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
          (frontend-pointer-capture-set! value #f)
          (let ([routing (frontend-routing-registration value)]
                [update (frontend-update-registration value)]
                [host-update (frontend-host-update-registration value)])
            (when routing (registration-close! routing))
            (when update (registration-close! update))
            (when host-update (registration-close! host-update))
            (frontend-routing-registration-set! value #f)
            (frontend-update-registration-set! value #f)
            (frontend-host-update-registration-set! value #f))
          (owner-close! (frontend-owner value))
          #t)))
)
