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
          (soda editor window))

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

  (define (effective-keymaps editor)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [layers
             (append
               (list 'editor.override)
               (if (editor-pending-prefix editor)
                   (list 'editor.prefix)
                   '())
               (fold-right
                 append
                 '()
                 (map
                   input-state-keymap-layers
                   (view-input-states view)))
               (view-keymap-layers view)
               (editor-minor-mode-keymap-layers editor buffer)
               (major-mode-keymaps
                 (editor-language-catalog editor)
                 (buffer-major-mode-name buffer))
               (list 'editor.default))])
      (map (lambda (layer) (catalog-keymap editor layer)) layers)))

  (define (dispatch-text! editor event text)
    (let* ([view (editor-active-view editor)]
           [buffer (view-buffer view)]
           [revision (buffer-revision buffer)]
           [state (view-current-input-state view)])
      (if (and (eq? (input-state-text-policy state) 'accept)
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
              (editor-take-completion-effects! editor)))
          '())))

  (define (handle-key-event! editor event)
    (unless (key-event? event)
      (assertion-violation
        'editor-update!
        "key message must contain a key event"
        event))
    (if (eq? (key-event-type event) 'release)
        '()
        (let* ([view (editor-active-view editor)]
               [state (view-current-input-state view)]
               [capture
                 (input-state-key-capture-command state)]
               [pending (editor-pending-keys editor)]
               [sequence
                 (append pending (list (key-event->key-stroke event)))])
          (call-with-values
            (lambda ()
              (keymaps-resolve (effective-keymaps editor) sequence))
            (lambda (status command)
              (cond
                [(and capture (eq? status 'prefix))
                 (editor-set-pending-keys! editor sequence)
                 '()]
                [capture
                 (editor-set-pending-keys! editor '())
                 (run-interactive-command
                   editor
                   capture
                   event
                   (list status command sequence)
                   #f)]
                [else
                 (case status
                   [(prefix)
                    (editor-set-pending-keys! editor sequence)
                    '()]
                   [(command)
                    (editor-set-pending-keys! editor '())
                    (run-interactive-command editor command event #f #f)]
                   [(undefined)
                    (editor-set-pending-keys! editor '())
                    (editor-clear-pending-prefix! editor)
                    (editor-set-last-command-class! editor #f)
                    (editor-set-status-message!
                      editor
                      "Undefined key")
                    '()]
                   [else
                    (editor-set-pending-keys! editor '())
                    (if (and (null? pending)
                             (positive?
                               (bytevector-length (key-event-text event))))
                        (dispatch-text!
                          editor
                          event
                          (key-event-text event))
                        (begin
                          (editor-set-last-command-class! editor #f)
                          (editor-clear-pending-prefix! editor)
                          (when (pair? pending)
                            (editor-set-status-message!
                              editor
                              "Undefined key sequence"))
                          '()))])]))))))

  (define (handle-input-event! editor event)
    (cond
      [(key-event? event) (handle-key-event! editor event)]
      [(text-input-event? event)
       (editor-set-pending-keys! editor '())
       (dispatch-text!
         editor
         event
         (text-input-event-text event))]
      [else
       (assertion-violation
         'editor-update!
         "expected an input event"
         event)]))

  (define (handle-resize-message! editor message)
    (let ([rows (resize-message-rows message)]
          [columns (resize-message-columns message)])
      (unless (and (integer? rows)
                   (exact? rows)
                   (>= rows 2)
                   (integer? columns)
                   (exact? columns)
                   (positive? columns))
        (assertion-violation
          'editor-update!
          "resize dimensions are invalid"
          rows
          columns))
      (let* ([session (editor-active-prompt editor)]
             [completion (editor-active-prompt-completion editor)]
             [completion-rows
               (if completion
                   (min
                     completion-window-max-rows
                     (max 0 (- rows 2)))
                   0)]
             [view (editor-base-view editor)]
             [body-rows
               (max
                 1
                 (- rows
                    (if session
                        (+ 1 completion-rows)
                        0)))])
        (when completion
          (completion-session-set-viewport-rows!
            completion
            completion-rows))
        (if (null?
              (cdr
                (window-node-leaves
                  (editor-window-root editor))))
            (begin
              (view-set-viewport!
                view
                (max 1 (- body-rows 1))
                columns)
              (ensure-view-visible! view))
            (let allocate
              ([node (editor-window-root editor)]
               [available-rows body-rows]
               [available-columns columns])
              (if (window-leaf? node)
                  (let ([leaf-view
                          (editor-view-ref
                            editor
                            (window-leaf-view-id node))])
                    (view-set-viewport!
                      leaf-view
                      (max 1 (- available-rows 1))
                      (max 1 available-columns))
                    (ensure-view-visible! leaf-view))
                  (let* ([children (window-split-children node)]
                         [count (length children)]
                         [vertical?
                           (eq?
                             (window-split-orientation node)
                             'vertical)]
                         [total
                           (if vertical?
                               available-rows
                               available-columns)]
                         [base (div total count)]
                         [extra (mod total count)])
                    (let loop
                      ([children children]
                       [index 0])
                      (unless (null? children)
                        (let ([amount
                                (+ base
                                   (if (< index extra) 1 0))])
                          (allocate
                            (car children)
                            (if vertical?
                                amount
                                available-rows)
                            (if vertical?
                                available-columns
                                amount))
                          (loop (cdr children) (+ index 1)))))))))
        (when session
          (let ([prompt-view
                  (editor-view-ref
                    editor
                    (prompt-session-view-id session))])
            (view-set-viewport!
              prompt-view
              1
              (prompt-input-viewport-columns
                (prompt-session-request session)
                (editor-root-viewport-columns editor)))
            (ensure-view-visible! prompt-view))))
      '()))

  (define (editor-update! editor message)
    (require-open-editor 'editor-update! editor)
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
                 (editor-apply-completion-response! editor message)
                 '()]
                [else
                 (assertion-violation
                   'editor-update!
                   "expected an editor message"
                   message)]))])
      (editor-invalidate!
        editor
        (cond
          [(resize-message? message) 'resize]
          [(completion-response-message? message) 'overlay]
          [(or (input-message? message) (key-message? message))
           'cursor]
          [else 'document]))
      result)))
