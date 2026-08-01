(library (soda editor tui-application-runtime)
  (export tui-open!
          tui-close!
          tui-active-session
          tui-send!
          tui-send-message!
          tui-complete-command!
          tui-take-effects!
          tui-retry!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor condition)
          (soda editor display-placement)
          (soda editor presentation)
          (soda editor state)
          (soda editor tui-application))

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
      [(overlay transient)
       (tui-view-state-set-transient-state!
         state
         (tui-view-action-payload action))]))

  (define (apply-view-actions! session message actions)
    (for-each
      (lambda (action)
        (for-each
          (lambda (state) (apply-view-action! state action))
          (target-view-states session message action)))
      actions))

  (define (application-resource name id)
    (string-append
      "*tui:"
      (symbol->string name)
      ":"
      (number->string id)
      "*"))

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
       (let* ([definition (definition-ref editor name)]
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
                      #f))])
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
             (apply-view-actions!
               session
               message
               (tui-update-result-view-actions result))
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
       (tui-send! editor session-id payload #f)]
      [(editor session-id payload origin-view-id)
       (let ([session (editor-tui-session-ref editor session-id)])
         (tui-send-message!
           editor
           (make-tui-message
             session-id
             (tui-session-generation session)
             origin-view-id
             payload)))]))

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
