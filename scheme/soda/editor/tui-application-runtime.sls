(library (soda editor tui-application-runtime)
  (export tui-open!
          tui-close!
          tui-active-session
          tui-send!
          tui-send-message!
          tui-complete-command!
          tui-take-effects!
          tui-retry!
          tui-start-recording!
          tui-stop-recording!
          tui-replay!
          tui-lifecycle-snapshot
          tui-synchronize-view-lifecycle!
          tui-route-pointer-event
          tui-mouse-capability-active?)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor condition)
          (soda editor display-placement)
          (soda editor edit)
          (soda editor event)
          (soda editor presentation)
          (soda editor state)
          (soda editor tui-application)
          (soda editor window)
          (soda editor window-runtime)
          (soda tui application)
          (soda tui component)
          (soda tui frame))

  (define (session-mouse-capable? session)
    (memq
      'mouse
      (tui-application-definition-capabilities
        (tui-session-definition session))))

  (define (tui-mouse-capability-active? editor)
    (require-open-editor 'tui-mouse-capability-active? editor)
    (exists
      (lambda (view)
        (let ([session
                (editor-tui-session-for-buffer
                  editor
                  (buffer-id (view-buffer view)))])
          (and session (session-mouse-capable? session))))
      (editor-visible-views editor)))

  (define (window-component-id id)
    (string->symbol
      (string-append "editor.window." (number->string id))))

  (define (view-text-node editor frame view)
    (let* ([layout (frame-layout frame)]
           [window (editor-window-for-view editor (view-id view))]
           [window-node
             (and layout window
                  (component-node-find
                    layout
                    (window-component-id (window-leaf-id window))))])
      (or (and window-node
               (component-node-find window-node 'editor.text))
          (and (= (length (editor-visible-views editor)) 1)
               layout
               (component-node-find layout 'editor.text)))))

  (define (application-source-at frame event)
    (and (< (pointer-event-row event) (frame-rows frame))
         (< (pointer-event-column event) (frame-columns frame))
         (find
           (lambda (source)
             (eq? (cell-source-layer source) 'application))
           (cell-sources
             (frame-cell-ref
               frame
               (pointer-event-row event)
               (pointer-event-column event))))))

  (define (captured-target editor)
    (let session-loop
      ([sessions
         (tui-application-registry-sessions
           (editor-tui-application-registry editor))])
      (and
        (pair? sessions)
        (or
          (let view-loop
            ([states (tui-session-view-states (car sessions))])
            (and
              (pair? states)
              (or
                (and (tui-view-state-pointer-capture (car states))
                     (let ([view
                             (find
                               (lambda (candidate)
                                 (= (view-id candidate)
                                    (tui-view-state-view-id (car states))))
                               (editor-visible-views editor))])
                       (and view
                            (list
                              (car sessions)
                              view
                              (car states)
                              (tui-view-state-pointer-capture
                                (car states))))))
                (view-loop (cdr states)))))
          (session-loop (cdr sessions))))))

  (define (hit-target editor frame event)
    (let ([source (application-source-at frame event)])
      (and source
           (let* ([session
                    (tui-application-registry-ref
                      (editor-tui-application-registry editor)
                      (cell-source-owner source))]
                  [view
                    (and session
                         (find
                           (lambda (candidate)
                             (let ([node
                                     (view-text-node editor frame candidate)]
                                   [presentation
                                     (buffer-presentation
                                       (view-buffer candidate))])
                               (and
                                 node
                                 (tui-presentation? presentation)
                                 (= (tui-presentation-session-id
                                      presentation)
                                    (tui-session-id session))
                                 (rect-contains?
                                   (component-node-rect node)
                                   (pointer-event-row event)
                                   (pointer-event-column event)))))
                           (editor-visible-views editor)))])
             (and session view
                  (list
                    session
                    view
                    (tui-session-view-state session (view-id view))
                    (cell-source-detail source)))))))

  (define (pointer-local-rect editor frame target event)
    (let* ([state (caddr target)]
           [captured-key (tui-view-state-pointer-capture state)]
           [surface (tui-view-state-surface-cache state)]
           [view (cadr target)]
           [base (view-text-node editor frame view)]
           [arranged
             (and captured-key surface
                  (tui-arranged-node-find
                    (tui-surface-arranged-tree surface)
                    captured-key))]
           [entry
             (and captured-key
                  (find
                    (lambda (candidate)
                      (equal?
                        captured-key
                        (tui-focus-entry-node-key candidate)))
                    (tui-view-state-focus-ring state)))]
           [local
             (cond
               [arranged (tui-arranged-node-rect arranged)]
               [entry (tui-focus-entry-rect entry)]
               [else #f])])
      (cond
        [(and base local)
         (make-rect
           (+ (rect-row (component-node-rect base)) (rect-row local))
           (+ (rect-column (component-node-rect base)) (rect-column local))
           (rect-rows local)
           (rect-columns local))]
        [else
         (let* ([layout (frame-layout frame)]
                [path
                  (and layout
                       (< (pointer-event-row event) (frame-rows frame))
                       (< (pointer-event-column event) (frame-columns frame))
                       (component-node-path-at
                         layout
                         (pointer-event-row event)
                         (pointer-event-column event)))])
           (and (pair? path)
                (component-node-rect (car (reverse path)))))])))

  (define (tui-route-pointer-event editor frame event)
    (require-open-editor 'tui-route-pointer-event editor)
    (unless (frame? frame)
      (assertion-violation
        'tui-route-pointer-event "expected a Frame" frame))
    (unless (pointer-event? event)
      (assertion-violation
        'tui-route-pointer-event "expected a PointerEvent" event))
    (let* ([target (or (captured-target editor)
                       (hit-target editor frame event))]
           [session (and target (car target))])
      (and target
           (session-mouse-capable? session)
           (let* ([view (cadr target)]
                  [state (caddr target)]
                  [node-key (list-ref target 3)]
                  [rectangle
                    (pointer-local-rect editor frame target event)]
                  [path
                    (let ([layout (frame-layout frame)])
                      (if (and layout
                               (< (pointer-event-row event)
                                  (frame-rows frame))
                               (< (pointer-event-column event)
                                  (frame-columns frame)))
                          (map
                            component-node-id
                            (component-node-path-at
                              layout
                              (pointer-event-row event)
                              (pointer-event-column event)))
                          '()))]
                  [payload
                    (make-tui-pointer
                      (view-id view)
                      node-key
                      path
                      (if rectangle
                          (- (pointer-event-row event)
                             (rect-row rectangle))
                          (pointer-event-row event))
                      (if rectangle
                          (- (pointer-event-column event)
                             (rect-column rectangle))
                          (pointer-event-column event))
                      (pointer-event-button event)
                      (pointer-event-modifiers event)
                      (pointer-event-type event))])
             (make-tui-message
               (tui-session-id session)
               (tui-session-generation session)
               (view-id view)
               payload)))))

  (define (lifecycle-entry session view state)
    (list
      (tui-session-id session)
      (view-id view)
      (tui-view-state-focused? state)
      (tui-view-state-width state)
      (tui-view-state-height state)))

  (define (entry-session-id entry) (car entry))
  (define (entry-view-id entry) (cadr entry))
  (define (entry-focused? entry) (caddr entry))
  (define (entry-width entry) (cadddr entry))
  (define (entry-height entry) (car (cddddr entry)))

  (define (same-entry-identity? left right)
    (and (= (entry-session-id left) (entry-session-id right))
         (= (entry-view-id left) (entry-view-id right))))

  (define (tui-lifecycle-snapshot editor)
    (require-open-editor 'tui-lifecycle-snapshot editor)
    (fold-right
      (lambda (view result)
        (let ([session
                (editor-tui-session-for-buffer
                  editor
                  (buffer-id (view-buffer view)))])
          (if (and session
                   (editor-window-for-view editor (view-id view)))
              (let ([state
                      (tui-session-ensure-view-state!
                        session
                        (view-id view))])
                (cons (lifecycle-entry session view state) result))
              result)))
      '()
      (editor-views editor)))

  (define (entry-ref entries target)
    (find
      (lambda (entry) (same-entry-identity? entry target))
      entries))

  (define (entry-session editor entry)
    (tui-application-registry-ref
      (editor-tui-application-registry editor)
      (entry-session-id entry)))

  (define (entry-view editor entry)
    (find
      (lambda (view) (= (view-id view) (entry-view-id entry)))
      (editor-views editor)))

  (define (desired-focus? editor entry)
    (and (not (editor-active-prompt editor))
         (= (entry-view-id entry)
            (view-id (editor-active-view editor)))))

  (define (send-lifecycle! editor entry payload)
    (let ([session (entry-session editor entry)])
      (and session
           (tui-send!
             editor
             (tui-session-id session)
             payload
             (entry-view-id entry)))))

  (define (tui-synchronize-view-lifecycle! editor before)
    (require-open-editor 'tui-synchronize-view-lifecycle! editor)
    (unless (list? before)
      (assertion-violation
        'tui-synchronize-view-lifecycle!
        "before snapshot must be a list"
        before))
    (let ([after (tui-lifecycle-snapshot editor)])
      ;; Blur is globally ordered before resize/focus so keyboard ownership
      ;; never appears to belong to two application Views.
      (for-each
        (lambda (old)
          (let ([current (entry-ref after old)])
            (when (and (entry-focused? old)
                       (or (not current)
                           (not (desired-focus? editor current))))
              (let ([view (entry-view editor old)])
                (when view (view-clear-input-handler-pending! view)))
              (let* ([session (entry-session editor old)]
                     [state
                       (and session
                            (tui-session-view-state
                              session
                              (entry-view-id old)))])
                (when state
                  (tui-view-state-set-pointer-capture! state #f)))
              (send-lifecycle!
                editor old (make-tui-blur-event (entry-view-id old))))))
        before)
      (for-each
        (lambda (current)
          (let* ([old (entry-ref before current)]
                 [session (entry-session editor current)]
                 [view (entry-view editor current)]
                 [state
                   (and session
                        (tui-session-view-state
                          session
                          (entry-view-id current)))]
                 [width (and view (view-viewport-columns view))]
                 [height (and view (view-viewport-rows view))])
            (when (and state width height
                       (or (not old)
                           (not (= width (entry-width old)))
                           (not (= height (entry-height old)))))
              (tui-view-state-set-size! state width height)
              (send-lifecycle!
                editor
                current
                (make-tui-resize-event
                  (entry-view-id current) width height)))))
        after)
      (for-each
        (lambda (current)
          (let* ([old (entry-ref before current)]
                 [session (entry-session editor current)]
                 [state
                   (and session
                        (tui-session-view-state
                          session
                          (entry-view-id current)))]
                 [focused? (desired-focus? editor current)])
            (when state
              (tui-view-state-set-focused! state focused?)
              (when (and focused?
                         (or (not old) (not (entry-focused? old))))
                (send-lifecycle!
                  editor
                  current
                  (make-tui-focus-event (entry-view-id current)))))))
        after)
      after))

  (define (condition->string condition)
    (if (message-condition? condition)
        (condition-message condition)
        "TUI application update failed"))

  (define (view-present? editor target-view-id)
    (exists
      (lambda (view) (= (view-id view) target-view-id))
      (editor-views editor)))

  (define (assigned-command session message command)
    (make-tui-command
      (tui-session-allocate-command-id! session)
      (tui-command-kind command)
      (tui-command-payload command)
      (tui-command-scope command)
      (or
        (tui-command-origin-view-id command)
        (and
          (eq? (tui-command-scope command) 'view)
          (tui-message-origin-view-id message)))
      (tui-session-command-generation session)
      (tui-command-cancellation-key command)))

  (define (same-cancellation-key? left right)
    (and left right (equal? left right)))

  (define (enqueue-commands! editor session message commands)
    (let loop ([remaining commands]
               [pending (tui-session-pending-commands session)]
               [effects '()])
      (if (null? remaining)
          (begin
            (tui-session-set-pending-commands! session pending)
            (let ([ordered (reverse effects)])
              (editor-queue-tui-effects! editor ordered)
              ordered))
          (let* ([command
                   (assigned-command session message (car remaining))]
                 [key (tui-command-cancellation-key command)]
                 [kept
                   (if key
                       (filter
                         (lambda (candidate)
                           (not
                             (same-cancellation-key?
                               key
                               (tui-command-cancellation-key candidate))))
                         pending)
                       pending)])
            (loop
              (cdr remaining)
              (append kept (list command))
              (cons
                (make-command-effect
                  'tui.command
                  (make-tui-command-dispatch
                    (tui-session-id session)
                    command))
                effects))))))

  (define (target-view-states session message action)
    (let ([target (tui-view-action-target action)])
      (cond
        [(eq? target 'all-views) (tui-session-view-states session)]
        [(eq? target 'origin)
         (let ([origin (tui-message-origin-view-id message)])
           (if origin
               (let ([state (tui-session-view-state session origin)])
                 (if state (list state) '()))
               '()))]
        [else
         (let ([state (tui-session-view-state session target)])
           (if state (list state) '()))])))

  (define (apply-view-action! state action)
    (case (tui-view-action-kind action)
      [(focus)
       (tui-view-state-set-focused-node!
         state
         (tui-view-action-payload action))]
      [(scroll)
       (tui-view-state-set-viewport!
         state
         (tui-view-action-payload action))]
      [(cursor)
       (tui-view-state-set-cursor!
         state
         (tui-view-action-payload action))]
      [(pointer-capture)
       (tui-view-state-set-pointer-capture!
         state
         (tui-view-action-payload action))]
      [(overlay transient)
       (tui-view-state-set-transient-state!
         state
         (tui-view-action-payload action))]))

  (define (apply-view-actions! session message actions)
    (for-each
      (lambda (action)
        (let ([targets (target-view-states session message action)])
          (when (and (eq? (tui-view-action-kind action) 'pointer-capture)
                     (tui-view-action-payload action))
            (for-each
              (lambda (state)
                (unless (memq state targets)
                  (tui-view-state-set-pointer-capture! state #f)))
              (tui-session-view-states session)))
          (for-each
            (lambda (state) (apply-view-action! state action))
            targets)))
      actions))

  (define (application-resource name id)
    (string-append
      "*tui:"
      (symbol->string name)
      ":"
      (number->string id)
      "*"))

  (define (projection-bytes definition model context)
    (let ([project
            (tui-application-definition-text-projection definition)])
      (and
        project
        (let ([value (project model context)])
          (cond
            [(string? value) (string->utf8 value)]
            [(bytevector? value) value]
            [else
             (assertion-violation
               'tui.text-projection
               "text projection must return a string or bytevector"
               (tui-application-definition-name definition)
               value)])))))

  (define (sync-text-projection! editor session)
    (let ([bytes
            (projection-bytes
              (tui-session-definition session)
              (tui-session-model session)
              (make-tui-application-context
                editor
                (tui-session-id session)
                (tui-session-buffer-id session)
                #f
                #f))])
      (when bytes
        (let ([buffer
                (editor-buffer-ref
                  editor
                  (tui-session-buffer-id session))])
          (define size
            (let ([snapshot
                    (document-snapshot (buffer-document buffer))])
              (dynamic-wind
                (lambda () #f)
                (lambda ()
                  (let ([text (snapshot-text snapshot)])
                    (dynamic-wind
                      (lambda () #f)
                      (lambda () (text-size text))
                      (lambda () (text-close! text)))))
                (lambda () (snapshot-close! snapshot)))))
          (buffer-replace-range-internal!
            buffer
            0
            size
            bytes)))))

  (define (definition-ref editor name)
    (or
      (tui-application-catalog-ref
        (editor-tui-application-catalog editor)
        name)
      (assertion-violation
        'tui-open!
        "unknown TUI application"
        name)))

  (define (initialize definition context arguments)
    (call-with-values
      (lambda ()
        ((tui-application-definition-init definition)
         context
         arguments))
      (lambda (model commands)
        (unless (and (list? commands) (for-all tui-command? commands))
          (assertion-violation
            'tui-open!
            "application init commands must contain TuiCommand values"
            (tui-application-definition-name definition)
            commands))
        (values model commands))))

  (define tui-open!
    (case-lambda
      [(editor name arguments)
       (let ([definition (definition-ref editor name)])
         (tui-open!
           editor
           name
           arguments
           (tui-application-definition-default-display-intent definition)
           (view-id (editor-active-view editor))))]
      [(editor name arguments intent)
       (tui-open!
         editor
         name
         arguments
         intent
         (view-id (editor-active-view editor)))]
      [(editor name arguments intent origin-view-id)
       (require-open-editor 'tui-open! editor)
       (let* ([lifecycle-before (tui-lifecycle-snapshot editor)]
              [definition (definition-ref editor name)]
              [registry (editor-tui-application-registry editor)]
              [session-id
                (tui-application-registry-allocate-session-id! registry)]
              [buffer
                (editor-create-buffer!
                  editor
                  (application-resource name session-id)
                  (tui-application-definition-default-mode definition)
                  "")]
              [registered? #f])
         (guard
           (condition
             [else
              (when registered?
                (editor-close-tui-session! editor session-id))
              (when
                (and
                  (not (buffer-closed? buffer))
                  (not
                    (exists
                      (lambda (view)
                        (eq? (view-buffer view) buffer))
                      (editor-views editor))))
                (editor-remove-buffer! editor (buffer-id buffer)))
              (raise condition)])
           (let* ([context
                    (make-tui-application-context
                      editor
                      session-id
                      (buffer-id buffer)
                      origin-view-id
                      arguments)])
             (call-with-values
               (lambda () (initialize definition context arguments))
               (lambda (model commands)
                 (let ([session
                         (make-tui-session
                           session-id
                           definition
                           (buffer-id buffer)
                           model)])
                   (tui-application-registry-add! registry session)
                   (set! registered? #t)
                   (buffer-set-presentation!
                     buffer
                     (make-tui-presentation session-id))
                   (buffer-set-local-setting!
                     buffer 'track-modified? #f)
                   (buffer-set-local-setting! buffer 'read-only? #t)
                   (buffer-set-local-setting!
                     buffer 'confirm-on-exit? #f)
                   (buffer-set-local-setting!
                     buffer 'interaction-class 'interface)
                   (tui-session-set-state! session 'ready)
                   (sync-text-projection! editor session)
                   (let ([view
                           (editor-display-buffer!
                             editor
                             (make-display-request
                               (buffer-id buffer)
                               intent
                               origin-view-id
                               #f
                               #f))])
                     (enqueue-commands!
                       editor
                       session
                       (make-tui-message
                         session-id
                         (tui-session-generation session)
                         (view-id view)
                         'tui.init)
                       commands))
                   (tui-synchronize-view-lifecycle!
                     editor
                     lifecycle-before)
                   (editor-invalidate! editor 'application)
                   buffer))))))]))

  (define (fallback-buffer editor target)
    (or
      (find
        (lambda (buffer) (not (eq? buffer target)))
        (editor-buffers editor))
      (editor-create-buffer!
        editor
        "*scratch*"
        'fundamental-mode
        "")))

  (define (tui-close! editor session-id)
    (require-open-editor 'tui-close! editor)
    (let* ([session (editor-tui-session-ref editor session-id)]
           [buffer
             (editor-buffer-ref editor (tui-session-buffer-id session))]
           [fallback (fallback-buffer editor buffer)])
      (for-each
        (lambda (view)
          (when (eq? (view-buffer view) buffer)
            (view-clear-input-handler-pending! view)))
        (editor-views editor))
      (for-each
        (lambda (view)
          (when (eq? (view-buffer view) buffer)
            (editor-set-view-buffer!
              editor
              (view-id view)
              (buffer-id fallback))))
        (editor-views editor))
      (editor-remove-buffer! editor (buffer-id buffer))
      (editor-invalidate! editor 'application)
      session))

  (define (tui-active-session editor)
    (require-open-editor 'tui-active-session editor)
    (editor-tui-session-for-buffer
      editor
      (buffer-id (view-buffer (editor-active-view editor)))))

  (define (tui-start-recording! editor session-id)
    (let* ([session (editor-tui-session-ref editor session-id)]
           [replay
             (make-tui-replay
               (tui-application-definition-name
                 (tui-session-definition session)))])
      (tui-session-set-replay-recorder! session replay)
      replay))

  (define (tui-stop-recording! editor session-id)
    (let* ([session (editor-tui-session-ref editor session-id)]
           [replay (tui-session-replay-recorder session)])
      (tui-session-set-replay-recorder! session #f)
      replay))

  (define (tui-replay! editor session-id replay)
    (require-open-editor 'tui-replay! editor)
    (unless (tui-replay? replay)
      (assertion-violation 'tui-replay! "expected a TuiReplay" replay))
    (let* ([session (editor-tui-session-ref editor session-id)]
           [name
             (tui-application-definition-name
               (tui-session-definition session))]
           [recorder (tui-session-replay-recorder session)])
      (unless (eq? name (tui-replay-application-name replay))
        (assertion-violation
          'tui-replay!
          "replay belongs to a different application"
          (tui-replay-application-name replay)
          name))
      (dynamic-wind
        (lambda () (tui-session-set-replay-recorder! session #f))
        (lambda ()
          (for-each
            (lambda (entry)
              (tui-send!
                editor
                session-id
                (tui-replay-entry-payload entry)
                (tui-replay-entry-origin-view-id entry)
                (tui-replay-entry-prefix entry)))
            (tui-replay-entries replay))
          (tui-session-model session))
        (lambda ()
          (tui-session-set-replay-recorder! session recorder)))))

  (define (tui-send-message! editor message)
    (require-open-editor 'tui-send-message! editor)
    (unless (tui-message? message)
      (assertion-violation
        'tui-send-message!
        "expected a TuiMessage"
        message))
    (let ([session
            (tui-application-registry-ref
              (editor-tui-application-registry editor)
              (tui-message-session-id message))])
      (cond
        [(or (not session)
             (eq? (tui-session-state session) 'closed)
             (not
               (= (tui-message-session-generation message)
                  (tui-session-generation session))))
         #f]
        [(eq? (tui-session-state session) 'failed)
         #f]
        [else
         (let ([recorder (tui-session-replay-recorder session)])
           (when recorder (tui-replay-record! recorder message)))
         (guard
           (condition
             [(editor-user-error-condition? condition)
              (editor-set-status-message!
                editor
                (condition->string condition))
              #f]
             [else
              (tui-session-set-last-message! session message)
              (tui-session-set-state! session 'failed)
              (editor-invalidate! editor 'application)
              (raise condition)])
           (let ([result
                   ((tui-application-definition-update
                      (tui-session-definition session))
                    (tui-session-model session)
                    message
                    (make-tui-application-context
                      editor
                      (tui-session-id session)
                      (tui-session-buffer-id session)
                      (tui-message-origin-view-id message)
                      #f
                      (and
                        (tui-message-origin-view-id message)
                        (tui-session-view-state
                          session
                          (tui-message-origin-view-id message)))))])
             (unless (tui-update-result? result)
               (assertion-violation
                 'tui-send-message!
                 "application update must return a TuiUpdateResult"
                 (tui-application-definition-name
                   (tui-session-definition session))
                 result))
             (tui-session-set-last-message! session message)
             (tui-session-set-model!
               session
               (tui-update-result-model result))
             (sync-text-projection! editor session)
             (apply-view-actions!
               session
               message
               (tui-update-result-view-actions result))
             (when (and (tui-pointer? (tui-message-payload message))
                        (eq? (tui-pointer-type
                               (tui-message-payload message))
                             'release)
                        (tui-message-origin-view-id message))
               (let ([state
                       (tui-session-view-state
                         session
                         (tui-message-origin-view-id message))])
                 (when state
                   (tui-view-state-set-pointer-capture! state #f))))
             (tui-session-advance-generation! session)
             (enqueue-commands!
               editor
               session
               message
               (tui-update-result-commands result))
             (editor-invalidate! editor 'application)
             result))])))

  (define tui-send!
    (case-lambda
      [(editor session-id payload)
       (tui-send! editor session-id payload #f #f)]
      [(editor session-id payload origin-view-id)
       (tui-send! editor session-id payload origin-view-id #f)]
      [(editor session-id payload origin-view-id prefix)
       (let ([session (editor-tui-session-ref editor session-id)])
         (tui-send-message!
           editor
           (make-tui-message
             session-id
             (tui-session-generation session)
             origin-view-id
             payload
             prefix)))]))

  (define (retire-command! session command-id)
    (let ([command
            (find
              (lambda (candidate)
                (= (tui-command-id candidate) command-id))
              (tui-session-pending-commands session))])
      (when command
        (tui-session-set-pending-commands!
          session
          (filter
            (lambda (candidate)
              (not (= (tui-command-id candidate) command-id)))
            (tui-session-pending-commands session))))
      command))

  (define (tui-complete-command! editor session-id command-id value)
    (require-open-editor 'tui-complete-command! editor)
    (let ([session
            (tui-application-registry-ref
              (editor-tui-application-registry editor)
              session-id)])
      (and
        session
        (let ([command (retire-command! session command-id)])
          (and
            command
            (= (tui-command-generation command)
               (tui-session-command-generation session))
            (or
              (eq? (tui-command-scope command) 'session)
              (and
                (tui-command-origin-view-id command)
                (view-present?
                  editor
                  (tui-command-origin-view-id command))))
            (tui-send!
              editor
              session-id
              (make-tui-command-result command-id value)
              (tui-command-origin-view-id command)))))))

  (define (tui-take-effects! editor)
    (editor-take-tui-effects! editor))

  (define (tui-retry! editor session-id)
    (let* ([session (editor-tui-session-ref editor session-id)]
           [message (tui-session-last-message session)])
      (if (not message)
          #f
          (begin
            (tui-session-set-state! session 'ready)
            (tui-send!
              editor
              session-id
              (tui-message-payload message)
              (tui-message-origin-view-id message))))))
)
