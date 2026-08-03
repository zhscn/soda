(library (soda editor tui-state)
  (export editor-tui-application-catalog
          editor-register-tui-application!
          editor-remove-tui-application!
          editor-tui-sessions
          editor-tui-session-ref
          editor-tui-session-for-buffer
          editor-release-view-pointer-capture!
          editor-close-tui-session!
          editor-queue-tui-effects!
          editor-take-tui-effects!
          attach-tui-view-state!
          detach-tui-view-state!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor contract)
          (soda editor editor-storage)
          (soda editor entity-registry)
          (soda editor input-state)
          (soda editor invalidation)
          (soda editor presentation)
          (soda editor status)
          (soda editor tui-application)
          (soda editor view))

  (define (editor-tui-application-catalog value)
    (require-open-editor 'editor-tui-application-catalog value)
    (tui-application-registry-catalog
      (editor-tui-application-registry value)))

  (define (editor-register-tui-application! value definition)
    (require-open-editor 'editor-register-tui-application! value)
    (let ([result
            (tui-application-catalog-register!
              (editor-tui-application-catalog value)
              definition)])
      (editor-invalidate! value 'configuration)
      result))

  (define (editor-remove-tui-application! value name)
    (require-open-editor 'editor-remove-tui-application! value)
    (let ([result
            (tui-application-catalog-remove!
              (editor-tui-application-catalog value)
              name)])
      (when result
        (editor-invalidate! value 'configuration))
      result))

  (define (editor-tui-sessions value)
    (require-open-editor 'editor-tui-sessions value)
    (tui-application-registry-sessions
      (editor-tui-application-registry value)))

  (define (editor-tui-session-ref value id)
    (require-open-editor 'editor-tui-session-ref value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'editor-tui-session-ref
        "session id must be a non-negative exact integer"
        id))
    (or
      (tui-application-registry-ref
        (editor-tui-application-registry value)
        id)
      (assertion-violation
        'editor-tui-session-ref
        "unknown TUI application session"
        id)))

  (define (editor-tui-session-for-buffer value buffer-id)
    (require-open-editor 'editor-tui-session-for-buffer value)
    (tui-application-registry-for-buffer
      (editor-tui-application-registry value)
      buffer-id))

  (define (editor-release-view-pointer-capture! value view)
    (require-open-editor 'editor-release-view-pointer-capture! value)
    (unless (view? view)
      (assertion-violation
        'editor-release-view-pointer-capture!
        "expected a view"
        view))
    (let* ([session
             (editor-tui-session-for-buffer
               value
               (buffer-id (view-buffer view)))]
           [state
             (and session
                  (tui-session-view-state session (view-id view)))])
      (when state
        (tui-view-state-set-pointer-capture! state #f))))

  (define (editor-close-tui-session! value id)
    (require-open-editor 'editor-close-tui-session! value)
    (let* ([registry (editor-tui-application-registry value)]
           [session (tui-application-registry-ref registry id)])
      (when session
        (let ([failure #f]
              [buffer
                (entity-registry-ref
                  (editor-buffer-registry value)
                  (tui-session-buffer-id session))])
          (for-each
            (lambda (view)
              (when (and buffer (eq? (view-buffer view) buffer))
                (view-clear-input-handler-pending! view)))
            (entity-registry-values (editor-view-registry value)))
          (guard
            (condition
              [else
               (set! failure condition)
               (tui-session-set-state! session 'closed)])
            (tui-session-close!
              session
              (make-tui-application-context
                value
                id
                (tui-session-buffer-id session)
                #f
                #f)))
          (when
            (and
              buffer
              (tui-presentation? (buffer-presentation buffer))
              (=
                id
                (tui-presentation-session-id
                  (buffer-presentation buffer))))
            (buffer-set-presentation!
              buffer
              (make-document-presentation)))
          (tui-application-registry-remove! registry id)
          (when failure
            (editor-set-status-message!
              value
              "TUI application close failed"
              'error)
            (raise failure))))
      session))

  (define (editor-queue-tui-effects! value effects)
    (require-open-editor 'editor-queue-tui-effects! value)
    (unless (and (list? effects) (for-all command-effect? effects))
      (assertion-violation
        'editor-queue-tui-effects!
        "expected command effects"
        effects))
    (editor-effects-set!
      value
      (append (editor-effects value) effects))
    effects)

  (define (editor-take-tui-effects! value)
    (require-open-editor 'editor-take-tui-effects! value)
    (let ([effects
            (filter
              (lambda (effect)
                (if (eq? (command-effect-kind effect) 'tui.command)
                    (let* ([dispatch (command-effect-payload effect)]
                           [session
                             (and
                               (tui-command-dispatch? dispatch)
                               (tui-application-registry-ref
                                 (editor-tui-application-registry value)
                                 (tui-command-dispatch-session-id dispatch)))]
                           [command
                             (and
                               session
                               (tui-command-dispatch-command dispatch))])
                      (and
                        command
                        (exists
                          (lambda (pending)
                            (= (tui-command-id pending)
                               (tui-command-id command)))
                          (tui-session-pending-commands session))))
                    #t))
              (editor-effects value))])
      (editor-effects-set! value '())
      effects))

  (define (view-tui-session value view)
    (let ([presentation (buffer-presentation (view-buffer view))])
      (and
        (tui-presentation? presentation)
        (tui-application-registry-ref
          (editor-tui-application-registry value)
          (tui-presentation-session-id presentation)))))

  (define (attach-tui-view-state! value view)
    (let ([session (view-tui-session value view)])
      (if session
          (begin
            (view-replace-input-states!
              view
              (list
                (make-input-state
                  'application
                  '(tui.application)
                  'application
                  #f)))
            (tui-session-ensure-view-state! session (view-id view)))
          (when
            (eq?
              (input-state-name (view-current-input-state view))
              'application)
            (view-replace-input-states!
              view
              (list (make-input-state 'editing '() 'accept)))))))

  (define (detach-tui-view-state! value view)
    (let ([session (view-tui-session value view)])
      (and
        session
        (tui-session-remove-view-state! session (view-id view)))))
)
