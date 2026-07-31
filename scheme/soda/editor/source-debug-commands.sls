(library (soda editor source-debug-commands)
  (export install-source-debug-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor edit)
          (soda editor evaluator)
          (soda editor keymap)
          (soda editor source-debug)
          (soda editor state))

  (define breakpoint-buffer-resource
    "*scheme-breakpoints*")

  (define (buffer-size buffer)
    (let ([snapshot
            (document-snapshot
              (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (view-line-location view)
    (let* ([buffer (view-buffer view)]
           [resource (buffer-resource buffer)])
      (unless resource
        (editor-user-error
          'scheme.debug-toggle-breakpoint
          "The current Buffer has no source resource"))
      (let ([snapshot
              (document-snapshot
                (buffer-document buffer))])
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (let ([text (snapshot-text snapshot)])
              (dynamic-wind
                (lambda () #f)
                (lambda ()
                  (let* ([position
                           (text-position
                             text
                             (view-caret view))]
                         [line (car position)]
                         [start (text-line-start text line)]
                         [end
                           (if
                             (< (+ line 1)
                                (text-line-count text))
                             (text-line-start text (+ line 1))
                             (text-size text))])
                    (when (= start end)
                      (editor-user-error
                        'scheme.debug-toggle-breakpoint
                        "Cannot place a breakpoint on an empty final line"))
                    (make-source-location
                      resource
                      start
                      end)))
                (lambda () (text-close! text)))))
          (lambda () (snapshot-close! snapshot))))))

  (define (editor-source-debugger editor)
    (chez-evaluator-source-debugger
      (editor-evaluator editor)))

  (define (toggle-breakpoint-command context)
    (let* ([editor (command-context-editor context)]
           [location
             (view-line-location
               (command-context-view context))]
           [breakpoint
             (source-debug-controller-toggle-breakpoint!
               (editor-source-debugger editor)
               location)])
      (editor-set-status-message!
        editor
        (if breakpoint
            (string-append
              "Breakpoint "
              (number->string
                (source-breakpoint-id breakpoint))
              " set")
            "Breakpoint removed"))
      '()))

  (define (breakpoint-list-text controller)
    (call-with-string-output-port
      (lambda (port)
        (display "Scheme source breakpoints\n\n" port)
        (let ([breakpoints
                (source-debug-controller-breakpoints
                  controller)])
          (if (null? breakpoints)
              (display "  <none>\n" port)
              (for-each
                (lambda (breakpoint)
                  (let ([location
                          (source-breakpoint-location
                            breakpoint)])
                    (display
                      (if
                        (source-breakpoint-enabled? breakpoint)
                        "[x] "
                        "[ ] ")
                      port)
                    (display
                      (number->string
                        (source-breakpoint-id breakpoint))
                      port)
                    (display "  " port)
                    (write
                      (source-location-resource location)
                      port)
                    (display ":" port)
                    (display
                      (number->string
                        (source-location-start location))
                      port)
                    (display "-" port)
                    (display
                      (number->string
                        (source-location-end location))
                      port)
                    (newline port)))
                breakpoints))))))

  (define (list-breakpoints-command context)
    (let* ([editor (command-context-editor context)]
           [text
             (breakpoint-list-text
               (editor-source-debugger editor))]
           [existing
             (editor-buffer-for-resource
               editor
               breakpoint-buffer-resource)]
           [buffer
             (or
               existing
               (editor-create-buffer!
                 editor
                 breakpoint-buffer-resource
                 'fundamental-mode
                 text
                 (editor-view-resource-context
                   editor
                   (view-id (command-context-view context)))))])
      (when existing
        (buffer-replace-range-internal!
          buffer
          0
          (buffer-size buffer)
          (string->utf8 text)))
      (buffer-set-local-setting!
        buffer
        'track-modified?
        #f)
      (buffer-set-local-setting!
        buffer
        'read-only?
        #t)
      (editor-set-view-buffer!
        editor
        (view-id (command-context-view context))
        (buffer-id buffer))
      '()))

  (define (install-source-debug-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'scheme.debug-toggle-breakpoint
          toggle-breakpoint-command
          "Toggle a Scheme source breakpoint on the current line.")
        (list
          'scheme.debug-list-breakpoints
          list-breakpoints-command
          "Display Scheme source breakpoints.")))
    (editor-bind-key!
      editor
      (list (make-key-stroke 'f9 #f 0))
      'scheme.debug-toggle-breakpoint)
    editor)
)
