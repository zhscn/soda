(library (soda editor debugger-commands)
  (export install-debugger-commands!
          interaction-attach-debugger-result!
          editor-capture-condition!)
  (import (rnrs)
          (only (chezscheme) display-condition)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor comint)
          (soda editor debugger)
          (soda editor edit)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor language)
          (soda editor prompt)
          (soda editor state))

  (define (debugger-resource debugger)
    (string-append
      "*scheme-debugger:"
      (symbol->string (debugger-session-origin debugger))
      ":"
      (if (debugger-session-interaction-id debugger)
          (number->string
            (debugger-session-interaction-id debugger))
          "editor")
      "*"))

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

  (define (debugger-buffer editor debugger)
    (let ([id (debugger-session-buffer-id debugger)])
      (and
        id
        (find
          (lambda (buffer) (= (buffer-id buffer) id))
          (editor-buffers editor)))))

  (define (refresh-debugger-buffer! editor debugger)
    (let ([buffer (debugger-buffer editor debugger)])
      (when buffer
        (buffer-replace-range-internal!
          buffer
          0
          (buffer-size buffer)
          (string->utf8
            (debugger-session->string debugger)))
        (for-each
          (lambda (view)
            (when (= (buffer-id (view-buffer view))
                     (buffer-id buffer))
              (view-set-caret!
                view
                (debugger-session-selected-frame-byte-offset
                  debugger))))
          (editor-views editor)))
      buffer))

  (define (buffer-with-id editor id)
    (and
      id
      (find
        (lambda (buffer) (= (buffer-id buffer) id))
        (editor-buffers editor))))

  (define (remove-debugger-buffer! editor debugger)
    (let ([buffer (debugger-buffer editor debugger)]
          [return-buffer
            (buffer-with-id
              editor
              (debugger-session-return-buffer-id debugger))])
      (when buffer
        (for-each
          (lambda (view)
            (when (= (buffer-id (view-buffer view))
                     (buffer-id buffer))
              (when return-buffer
                (editor-set-view-buffer!
                  editor
                  (view-id view)
                  (buffer-id return-buffer))
                (when (debugger-session-return-caret debugger)
                  (view-set-caret!
                    view
                    (min
                      (debugger-session-return-caret debugger)
                      (buffer-size return-buffer)))))))
          (editor-views editor))
        (editor-remove-buffer! editor (buffer-id buffer))
        (debugger-session-set-buffer-id! debugger #f))))

  (define (discard-debugger! editor session debugger)
    (when debugger
      (remove-debugger-buffer! editor debugger)
      (debugger-session-close! debugger)
      (if session
          (interaction-session-set-debugger! session #f)
          (when (eq? (editor-debugger editor) debugger)
            (editor-set-debugger! editor #f)))))

  (define (close-session-debugger! editor session)
    (discard-debugger!
      editor
      session
      (interaction-session-debugger session)))

  (define (open-debugger! editor view debugger)
    (let ([buffer (debugger-buffer editor debugger)])
      (unless buffer
        (set! buffer
          (editor-create-buffer!
            editor
            (debugger-resource debugger)
            'debugger-mode
            (debugger-session->string debugger)))
        (buffer-set-local-setting!
          buffer
          'track-modified?
          #f)
        (debugger-session-set-buffer-id!
          debugger
          (buffer-id buffer)))
      (editor-set-view-buffer!
        editor
        (view-id view)
        (buffer-id buffer))
      (view-set-caret!
        view
        (debugger-session-selected-frame-byte-offset debugger))
      (editor-set-status-message!
        editor
        "Debugger: n/p frame, e evaluate, x exit, q discard")
      buffer))

  (define (editor-capture-condition! editor label condition)
    (guard
      (capture-condition
        [else
         (editor-set-status-message!
           editor
           "Editor command failed; debugger is unavailable")
         #f])
      (let ([current (editor-debugger editor)])
        (when current
          (discard-debugger! editor #f current)))
      (let* ([view (editor-active-view editor)]
             [buffer (view-buffer view)]
             [debugger
               (make-condition-debugger-session
                 'command
                 (cond
                   [(symbol? label) (symbol->string label)]
                   [(string? label) label]
                   [else "editor command"])
                 (buffer-id buffer)
                 (view-caret view)
                 condition)])
        (editor-set-debugger! editor debugger)
        (open-debugger! editor view debugger)
        debugger)))

  (define (interaction-attach-debugger-result!
            editor
            session
            result)
    (close-session-debugger! editor session)
    (if (eq? (evaluation-result-status result) 'condition)
        (guard (condition
                 [else
                  (editor-set-status-message!
                    editor
                    "Evaluation failed; debugger is unavailable")])
          (interaction-session-set-debugger!
            session
            (make-debugger-session session result))
          (editor-set-status-message!
            editor
            "Evaluation failed; M-x scheme.debug-open"))
        (editor-set-status-message! editor #f)))

  (define (debugger-matches-buffer? debugger buffer-id)
    (and
      debugger
      (not (debugger-session-closed? debugger))
      (or
        (equal? (debugger-session-buffer-id debugger) buffer-id)
        (equal?
          (debugger-session-return-buffer-id debugger)
          buffer-id))))

  (define (active-debug-target editor view)
    (let* ([buffer-id (buffer-id (view-buffer view))]
           [interaction
             (editor-interaction-for-buffer editor buffer-id)])
      (cond
        [(and
           interaction
           (interaction-session-debugger interaction))
         (list
           interaction
           (interaction-session-debugger interaction))]
        [(find
           (lambda (session)
             (debugger-matches-buffer?
               (interaction-session-debugger session)
               buffer-id))
           (editor-interactions editor))
         =>
         (lambda (session)
           (list
             session
             (interaction-session-debugger session)))]
        [(debugger-matches-buffer?
           (editor-debugger editor)
           buffer-id)
         (list #f (editor-debugger editor))]
        [(editor-debugger editor)
         (list #f (editor-debugger editor))]
        [else #f])))

  (define (require-debug-target who context)
    (let* ([editor (command-context-editor context)]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (unless target
        (assertion-violation
          who
          "active buffer has no saved debugger"))
      target))

  (define (debug-open-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-open
               context)]
           [debugger (cadr target)])
      (open-debugger!
        editor
        (command-context-view context)
        debugger)
      '()))

  (define (move-debug-frame-command context delta)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-frame
               context)]
           [debugger (cadr target)]
           [count (command-context-count context)])
      (unless debugger
        (assertion-violation
          'scheme.debug-frame
          "failed interaction has no debugger"))
      (if (positive? delta)
          (debugger-session-next-frame! debugger count)
          (debugger-session-previous-frame! debugger count))
      (refresh-debugger-buffer! editor debugger)
      '()))

  (define (debug-next-frame-command context)
    (move-debug-frame-command context 1))

  (define (debug-previous-frame-command context)
    (move-debug-frame-command context -1))

  (define (values->string values)
    (call-with-string-output-port
      (lambda (port)
        (cond
          [(null? values) (display "#<void>" port)]
          [else
           (let loop ([remaining values] [first? #t])
             (unless (null? remaining)
               (unless first? (display " " port))
               (write (car remaining) port)
               (loop (cdr remaining) #f)))]))))

  (define (condition->string condition)
    (call-with-string-output-port
      (lambda (port)
        (display-condition condition port))))

  (define (debug-eval-frame-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-eval-frame
               context)]
           [session (car target)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(string? argument)
         (guard
           (condition
             [else
              (editor-set-status-message!
                editor
                (string-append
                  "Debugger evaluation failed: "
                  (condition->string condition)))])
           (editor-set-status-message!
             editor
             (string-append
               argument
               " => "
               (values->string
                 (debugger-session-evaluate
                   debugger
                   argument)))))]
        [(not argument)
         (editor-open-prompt!
           editor
           (make-prompt-request
             "Evaluate in frame: "
             ""
             'scheme-debug-eval
             #f
             'free
             #f
             'scheme.debug-eval-frame-accept
             #f
             (cons
               (debugger-session-origin debugger)
               (debugger-session-generation debugger))))]
        [else
         (assertion-violation
           'scheme.debug-eval-frame
           "expression must be a string or #f"
           argument)])
      '()))

  (define (debug-eval-frame-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [identity
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [source
             (and
               (prompt-result? result)
               (prompt-result-value result))])
      (when (and source (positive? (string-length source)))
        (let ([target
                (active-debug-target
                  editor
                  (command-context-view context))])
          (when target
            (let ([debugger (cadr target)])
              (when
                (and
                  (pair? identity)
                  (eq? (car identity)
                       (debugger-session-origin debugger))
                  (= (cdr identity)
                     (debugger-session-generation debugger)))
                (guard
                  (condition
                    [else
                     (editor-set-status-message!
                       editor
                       (string-append
                         "Debugger evaluation failed: "
                         (condition->string condition)))])
                  (editor-set-status-message!
                    editor
                    (string-append
                      source
                      " => "
                      (values->string
                        (debugger-session-evaluate
                          debugger
                          source))))))))))
      '()))

  (define (debug-retry-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-retry
               context)]
           [session (car target)]
           [result
             (and session
                  (interaction-session-last-result session))])
      (unless result
        (assertion-violation
          'scheme.debug-retry
          "active interaction has no failed evaluation"))
      (comint-stash-current-input! editor session)
      (close-session-debugger! editor session)
      (comint-replace-input! editor session ";; retry")
      (comint-commit-input! editor session)
      (list
        (make-command-effect
          'scheme.evaluate
          (interaction-session-begin!
            session
            (evaluation-request-source
              (evaluation-result-request result))
            (evaluation-request-origin
              (evaluation-result-request result)))))))

  (define (debug-exit-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-exit
               context)])
      (remove-debugger-buffer! editor (cadr target))
      (editor-set-status-message!
        editor
        "Debugger exited; saved condition retained")
      '()))

  (define (debug-discard-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-discard
               context)]
           [session (car target)]
           [debugger (cadr target)])
      (discard-debugger! editor session debugger)
      (when session
        (interaction-session-dismiss-failure! session))
      (editor-set-status-message! editor #f)
      '()))

  (define (register-debugger-command!
            editor
            name
            procedure
            documentation)
    (editor-register-command!
      editor
      (make-interactive-context-command
        name
        procedure
        documentation)))

  (define (install-debugger-commands! editor)
    (for-each
      (lambda (entry)
        (register-debugger-command!
          editor
          (car entry)
          (cadr entry)
          (caddr entry)))
      (list
        (list
          'scheme.debug-open
          debug-open-command
          "Open the debugger for the failed Scheme evaluation.")
        (list
          'scheme.debug-next-frame
          debug-next-frame-command
          "Select the next Scheme debugger frame.")
        (list
          'scheme.debug-previous-frame
          debug-previous-frame-command
          "Select the previous Scheme debugger frame.")
        (list
          'scheme.debug-eval-frame
          debug-eval-frame-command
          "Evaluate an expression in the selected debugger frame.")
        (list
          'scheme.debug-retry
          debug-retry-command
          "Retry the failed evaluation in the active interaction.")
        (list
          'scheme.debug-exit
          debug-exit-command
          "Leave the debugger while retaining the saved condition.")
        (list
          'scheme.debug-discard
          debug-discard-command
          "Discard the saved condition and its continuation.")))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-eval-frame-accept
        debug-eval-frame-accept-command
        "Apply input from the debugger evaluation prompt."))
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'debugger-mode
        'fundamental-mode
        #f
        'interface
        'debugger-mode-map
        '((track-modified? . #f)
          (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (for-each
        (lambda (entry)
          (keymap-bind!
            keymap
            (list
              (make-key-stroke
                'character
                (char->integer (car entry))
                0))
            (cdr entry)))
        '((#\n . scheme.debug-next-frame)
          (#\p . scheme.debug-previous-frame)
          (#\e . scheme.debug-eval-frame)
          (#\r . scheme.debug-retry)
          (#\x . scheme.debug-exit)
          (#\q . scheme.debug-discard)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'debugger-mode-map
        keymap))))
