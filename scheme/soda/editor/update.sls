(library (soda editor update)
  (export editor-update!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor commands basic)
          (soda editor event)
          (soda editor input-state)
          (soda editor keymap)
          (soda editor language)
          (soda editor state))

  (define (condition->string condition)
    (call-with-values
      open-string-output-port
      (lambda (port extract)
        (write condition port)
        (extract))))

  (define (run-interactive-command editor name event argument)
    (unless (eq? name 'editor.quit)
      (editor-disarm-quit! editor))
    (guard (condition
             [else
              (editor-set-status-message!
                editor
                (condition->string condition))
              '()])
      (editor-set-status-message! editor #f)
      (editor-execute-command! editor name event argument)))

  (define (run-internal-command editor name argument)
    (unless (eq? name 'editor.quit)
      (editor-disarm-quit! editor))
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
               (fold-right
                 append
                 '()
                 (map
                   input-state-keymap-layers
                   (view-input-states view)))
               (view-keymap-layers view)
               (major-mode-keymaps
                 (editor-language-catalog editor)
                 (buffer-major-mode-name buffer))
               (list 'editor.default))])
      (map (lambda (layer) (catalog-keymap editor layer)) layers)))

  (define (dispatch-text! editor event text)
    (let ([state
            (view-current-input-state
              (editor-active-view editor))])
      (if (and (eq? (input-state-text-policy state) 'accept)
               (positive? (bytevector-length text)))
          (run-interactive-command
            editor
            (input-state-text-command state)
            event
            text)
          '())))

  (define (handle-key-event! editor event)
    (unless (key-event? event)
      (assertion-violation
        'editor-update!
        "key message must contain a key event"
        event))
    (if (eq? (key-event-type event) 'release)
        '()
        (let* ([pending (editor-pending-keys editor)]
               [sequence
                 (append pending (list (key-event->key-stroke event)))])
          (call-with-values
            (lambda ()
              (keymaps-resolve (effective-keymaps editor) sequence))
            (lambda (status command)
              (case status
                [(prefix)
                 (editor-set-pending-keys! editor sequence)
                 '()]
                [(command)
                 (editor-set-pending-keys! editor '())
                 (run-interactive-command editor command event #f)]
                [(undefined)
                 (editor-set-pending-keys! editor '())
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
                       (when (pair? pending)
                         (editor-set-status-message!
                           editor
                           "Undefined key sequence"))
                       '()))]))))))

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
          [columns (resize-message-columns message)]
          [view (editor-active-view editor)])
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
      (view-set-viewport! view (- rows 1) columns)
      (ensure-view-visible! view)
      '()))

  (define (editor-update! editor message)
    (require-open-editor 'editor-update! editor)
    (cond
      [(input-message? message)
       (handle-input-event! editor (input-message-event message))]
      [(key-message? message)
       (handle-key-event! editor (key-message-event message))]
      [(resize-message? message)
       (handle-resize-message! editor message)]
      [(command-message? message)
       (run-interactive-command
         editor
         (command-message-name message)
         #f
         (command-message-argument message))]
      [(internal-command-message? message)
       (run-internal-command
         editor
         (internal-command-message-name message)
         (internal-command-message-argument message))]
      [else
       (assertion-violation
         'editor-update!
         "expected an editor message"
         message)])))
