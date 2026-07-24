(library (soda editor update)
  (export editor-update!)
  (import (rnrs)
          (soda editor buffer)
          (soda editor command)
          (soda editor commands basic)
          (soda editor event)
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
    (guard (condition
             [else
              (editor-set-status-message!
                editor
                (condition->string condition))
              '()])
      (editor-set-status-message! editor #f)
      (editor-execute-command! editor name event argument)))

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
               (view-keymap-layers view)
               (major-mode-keymaps
                 (editor-language-catalog editor)
                 (buffer-major-mode-name buffer))
               (list 'editor.default))])
      (map (lambda (layer) (catalog-keymap editor layer)) layers)))

  (define (handle-key-message! editor event)
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
                [else
                 (editor-set-pending-keys! editor '())
                 (if (and (null? pending)
                          (positive?
                            (bytevector-length (key-event-text event))))
                     (run-interactive-command
                       editor
                       'edit.self-insert
                       event
                       #f)
                     (begin
                       (when (pair? pending)
                         (editor-set-status-message!
                           editor
                           "Undefined key sequence"))
                       '()))]))))))

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
      [(key-message? message)
       (handle-key-message! editor (key-message-event message))]
      [(resize-message? message)
       (handle-resize-message! editor message)]
      [(command-message? message)
       (run-interactive-command
         editor
         (command-message-name message)
         #f
         (command-message-argument message))]
      [else
       (assertion-violation
         'editor-update!
         "expected an editor message"
         message)])))
