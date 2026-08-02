(library (soda editor update)
  (export editor-update!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor completion-commands)
          (soda editor condition)
          (soda editor debugger-commands)
          (soda editor event)
          (soda editor input-state)
          (soda editor keymap)
          (soda editor language)
          (soda editor minor-mode-runtime)
          (soda editor prompt)
          (soda editor state)
          (soda editor tui-application)
          (soda editor tui-state)
          (soda editor tui-application-runtime)
          (soda editor window)
          (soda editor window-runtime)
          (soda editor workbench))

  (define (condition->string condition)
    (if
      (message-condition? condition)
      (condition-message condition)
      (call-with-values
        open-string-output-port
        (lambda (port extract)
          (write condition port)
          (extract)))))

  (define (run-interactive-command editor name event argument message-prefix)
    (editor-set-status-message! editor #f)
    (if (eq?
          (command-class (editor-command-registry editor) name)
          'prefix)
        (editor-execute-command! editor name event argument #f)
        (let ([pending-prefix
                (editor-take-pending-prefix! editor)])
          (editor-execute-interactive-command!
            editor
            name
            event
            argument
            (or message-prefix pending-prefix)))))

  (define (run-internal-command editor name argument)
    (editor-execute-command! editor name #f argument))

  (define (catalog-keymap editor layer)
    (cond
      [(keymap? layer) layer]
      [(symbol? layer)
       (or (keymap-catalog-find (editor-keymap-catalog editor) layer)
           (assertion-violation
             'editor-update!
             "unknown keymap layer"
             layer))]
      [else
       (assertion-violation
         'editor-update!
         "invalid keymap layer"
         layer)]))

  (define (active-input-states view)
    (let* ([states (view-input-states view)]
           [durable
             (let loop ([remaining states])
               (if (null? (cdr remaining))
                   (car remaining)
                   (loop (cdr remaining))))])
      (if (eq? (car states) durable)
          (list durable)
          (list (car states) durable))))

  (define (effective-keymaps editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [active-states (active-input-states view)]
           [layers
             (append
               (if (editor-pending-prefix editor)
                   (list 'editor.prefix)
                   '())
               (apply append
                 (map input-state-keymap-layers active-states))
               (view-keymap-layers view)
               (editor-minor-mode-keymap-layers editor buffer)
               (major-mode-keymaps
                 (editor-language-catalog editor)
                 (buffer-major-mode-name buffer))
               (list 'editor.default))])
      (map (lambda (layer) (catalog-keymap editor layer)) layers)))

  (define (input-context-for editor view)
    (let* ([buffer (view-buffer view)]
           [session
             (editor-tui-session-for-buffer editor (buffer-id buffer))]
           [view-state
             (and session
                  (tui-session-view-state session (view-id view)))]
           [window (editor-window-for-view editor (view-id view))]
           [workbench (editor-workbench-for-view editor (view-id view))])
      (make-input-context
        0
        (and workbench (workbench-id workbench))
        (and window (window-leaf-id window))
        (view-id view)
        (buffer-id buffer)
        (buffer-presentation buffer)
        (view-input-states view)
        (editor-pending-keys editor)
        (editor-pending-prefix editor)
        (and session (tui-session-id session))
        (and view-state (tui-view-state-focused-node view-state)))))

  (define (require-input-disposition value)
    (unless (input-disposition? value)
      (assertion-violation
        'input-state.handler
        "handler must return an InputDisposition"
        value))
    value)

  (define (run-handler-chain editor view event)
    (let* ([context (input-context-for editor view)]
           [pending (view-input-handler-pending view)]
           [pending-result
             (and pending
                  (begin
                    (view-clear-input-handler-pending! view)
                    (require-input-disposition
                      ((input-disposition-continuation (cdr pending))
                       event
                       context))))])
      (if (and pending-result
               (not (eq? (input-disposition-kind pending-result) 'pass)))
          (cons (car pending) pending-result)
          (let loop ([states (active-input-states view)])
            (if (null? states)
                #f
                (let ([handler (input-state-handler (car states))])
                  (if (not handler)
                      (loop (cdr states))
                      (let ([result
                              (require-input-disposition
                                (handler event context))])
                        (if (eq? (input-disposition-kind result) 'pass)
                            (loop (cdr states))
                            (cons (car states) result))))))))))

  (define (dispatch-handler-result! editor view event handled)
    (let* ([state (car handled)]
           [result (cdr handled)]
           [kind (input-disposition-kind result)])
      (case kind
        [(consume)
         (editor-set-pending-keys! editor '())
         (values #t '())]
        [(dispatch-command)
         (view-clear-input-handler-pending! view)
         (editor-set-pending-keys! editor '())
         (values
           #t
           (run-interactive-command
             editor
             (input-disposition-command result)
             event
             (input-disposition-argument result)
             #f))]
        [(dispatch-application)
         (view-clear-input-handler-pending! view)
         (editor-set-pending-keys! editor '())
         (let ([session
                 (editor-tui-session-for-buffer
                   editor
                   (buffer-id (view-buffer view)))])
           (if session
               (begin
                 (tui-send!
                   editor
                   (tui-session-id session)
                   (input-disposition-payload result)
                   (view-id view)
                   (editor-take-pending-prefix! editor))
                 (values #t '()))
               (begin
                 (editor-clear-pending-prefix! editor)
                 (editor-set-status-message!
                   editor
                   "No active TUI application")
                 (values #t '()))))]
        [(pending)
         (editor-set-pending-keys! editor '())
         (view-set-input-handler-pending! view state result)
         (values #t '())]
        [else
         (assertion-violation
           'input-state.handler
           "unsupported InputDisposition"
           kind)])))

  (define (run-input-handlers! editor view event)
    (let ([handled (run-handler-chain editor view event)])
      (if handled
          (dispatch-handler-result! editor view event handled)
          (values #f '()))))

  (define (active-application-target editor)
    (let* ([view (editor-active-view editor)]
           [session
             (editor-tui-session-for-buffer
               editor
               (buffer-id (view-buffer view)))])
      (and session (cons session view))))

  (define (dispatch-application-input! editor kind value)
    (let ([target (active-application-target editor)])
      (if (not target)
          #f
          (let* ([session (car target)]
                 [view (cdr target)]
                 [view-state
                   (tui-session-ensure-view-state!
                     session
                     (view-id view))]
                 [prefix (editor-take-pending-prefix! editor)])
            (tui-send!
              editor
              (tui-session-id session)
              (make-tui-input-event
                kind
                value
                prefix
                (tui-view-state-focused-node view-state))
              (view-id view))
            #t))))

  (define (dispatch-text! editor event text)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [revision (buffer-revision buffer)]
           [state (view-current-input-state view)])
      (cond
        [(and (eq? (input-state-text-policy state) 'accept)
              (positive? (bytevector-length text)))
         (let ([effects
                  (run-interactive-command
                    editor
                    (input-state-text-command state)
                    event
                    text
                    #f)])
            (when
              (and
                (eq? buffer
                     (view-buffer (editor-active-view editor)))
                (not (= revision (buffer-revision buffer))))
              (editor-auto-trigger-completion!
                editor
                (utf8->string text)))
            (append
              effects
              (editor-take-completion-effects! editor)))]
        [(and (eq? (input-state-text-policy state) 'application)
              (positive? (bytevector-length text)))
         (dispatch-application-input!
           editor
           (if (and (text-input-event? event)
                    (eq? (text-input-event-kind event) 'paste))
               'paste
               'text)
           text)
         '()]
        [else '()])))

  (define (handle-keymap-resolution!
            editor event view state capture pending sequence status command)
    (cond
      [(and capture (eq? status 'prefix))
       (editor-set-pending-keys! editor sequence)
       '()]
      [capture
       (editor-set-pending-keys! editor '())
       (run-interactive-command
         editor capture event (list status command sequence) #f)]
      [else
       (case status
         [(prefix)
          (editor-set-pending-keys! editor sequence)
          '()]
         [(command)
          (view-clear-input-handler-pending! view)
          (editor-set-pending-keys! editor '())
          (run-interactive-command editor command event #f #f)]
         [(undefined)
          (view-clear-input-handler-pending! view)
          (editor-set-pending-keys! editor '())
          (editor-clear-pending-prefix! editor)
          (editor-set-last-command-class! editor #f)
          (editor-set-status-message! editor "Undefined key")
          '()]
         [else
          (editor-set-pending-keys! editor '())
          (if (and (null? pending)
                   (positive? (bytevector-length (key-event-text event))))
              (dispatch-text! editor event (key-event-text event))
              (if (and
                    (null? pending)
                    (eq? (input-state-text-policy state) 'application)
                    (dispatch-application-input!
                      editor
                      (if (eq? (key-event-type event) 'repeat)
                          'key-repeat
                          'key-press)
                      event))
                  '()
                  (begin
                    (editor-set-last-command-class! editor #f)
                    (editor-clear-pending-prefix! editor)
                    (when (pair? pending)
                      (editor-set-status-message!
                        editor
                        "Undefined key sequence"))
                    '())))])]))

  (define (handle-key-event! editor event)
    (unless (key-event? event)
      (assertion-violation
        'editor-update!
        "key message must contain a key event"
        event))
    (let* ([view (editor-active-view editor)]
           [state (view-current-input-state view)])
      (if (eq? (key-event-type event) 'release)
          (call-with-values
            (lambda () (run-input-handlers! editor view event))
            (lambda (handled? effects)
              (if handled?
                  effects
                  (begin
                    (when
                      (eq? (input-state-text-policy state) 'application)
                      (dispatch-application-input!
                        editor 'key-release event))
                    '()))))
          (let* ([capture (input-state-key-capture-command state)]
                 [pending (editor-pending-keys editor)]
                 [sequence
                   (append pending (list (key-event->key-stroke event)))])
            (call-with-values
              (lambda ()
                (keymaps-resolve
                  (list (catalog-keymap editor 'editor.override))
                  sequence))
              (lambda (override-status override-command)
                (if (not (eq? override-status 'none))
                    (handle-keymap-resolution!
                      editor event view state #f pending sequence
                      override-status override-command)
                    (call-with-values
                      (lambda () (run-input-handlers! editor view event))
                      (lambda (handled? effects)
                        (if handled?
                            effects
                            (call-with-values
                              (lambda ()
                                (keymaps-resolve
                                  (effective-keymaps editor)
                                  sequence))
                              (lambda (status command)
                                (handle-keymap-resolution!
                                  editor event view state capture pending
                                  sequence status command)))))))))))))

  (define (handle-input-event! editor event)
    (cond
      [(key-event? event) (handle-key-event! editor event)]
      [(text-input-event? event)
       (editor-set-pending-keys! editor '())
       (view-clear-input-handler-pending! (editor-active-view editor))
       (dispatch-text!
         editor
         event
         (text-input-event-text event))]
      [(pointer-event? event) '()]
      [else
       (assertion-violation
         'editor-update!
         "expected an input event"
         event)]))

  (define (handle-resize-message! editor message)
    (let ([rows (resize-message-rows message)]
          [columns (resize-message-columns message)])
      (editor-reconcile-viewports! editor rows columns)
      '()))

  (define (editor-update! editor message)
    (require-open-editor 'editor-update! editor)
    (let ([completion-response-accepted? #f]
          [lifecycle-before (tui-lifecycle-snapshot editor)])
      (let ([result
            (guard
              (condition
                [(editor-user-error-condition? condition)
                 (editor-clear-pending-prefix! editor)
                 (editor-set-pending-keys! editor '())
                 (editor-set-last-command-class! editor #f)
                 (editor-set-status-message!
                   editor
                   (condition->string condition))
                 '()]
                [else
                 (editor-clear-pending-prefix! editor)
                 (editor-set-pending-keys! editor '())
                 (editor-set-last-command-class! editor #f)
                 (editor-set-active-command-invocation! editor #f)
                 (editor-capture-condition!
                   editor
                   (cond
                     [(command-message? message)
                      (command-message-name message)]
                     [(internal-command-message? message)
                      (internal-command-message-name message)]
                     [(tui-message? message) 'tui.update]
                     [else 'editor-update])
                   condition)
                 '()])
              (cond
                [(input-message? message)
                 (handle-input-event!
                   editor
                   (input-message-event message))]
                [(key-message? message)
                 (handle-key-event! editor (key-message-event message))]
                [(resize-message? message)
                 (handle-resize-message! editor message)]
                [(command-message? message)
                 (run-interactive-command
                   editor
                   (command-message-name message)
                   #f
                   (command-message-argument message)
                   (command-message-prefix message))]
                [(internal-command-message? message)
                 (run-internal-command
                   editor
                   (internal-command-message-name message)
                   (internal-command-message-argument message))]
                [(completion-response-message? message)
                 (set!
                   completion-response-accepted?
                   (editor-apply-completion-response! editor message))
                 '()]
                [(tui-message? message)
                 (tui-send-message! editor message)
                 '()]
                [(tui-command-completion-message? message)
                 (tui-complete-command!
                   editor
                   (tui-command-completion-message-session-id message)
                   (tui-command-completion-message-command-id message)
                   (tui-command-completion-message-value message))
                 '()]
                [else
                 (assertion-violation
                   'editor-update!
                   "expected an editor message"
                   message)]))])
        (let ([reason
                (cond
                  [(resize-message? message) 'resize]
                  [(completion-response-message? message)
                   (and completion-response-accepted? 'overlay)]
                  [(or (input-message? message) (key-message? message))
                   'cursor]
                  [(tui-message? message) 'application]
                  [(tui-command-completion-message? message) 'application]
                  [else 'document])])
          (when reason
            (editor-invalidate! editor reason)))
        (tui-synchronize-view-lifecycle! editor lifecycle-before)
        (append result (editor-take-tui-effects! editor))))))
