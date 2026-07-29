(library (soda editor debugger-commands)
  (export install-debugger-commands!
          interaction-attach-debugger-result!)
  (import (rnrs)
          (only (chezscheme) display-condition)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor comint)
          (soda editor debugger)
          (soda editor edit)
          (soda editor effect)
          (soda editor evaluator)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor language)
          (soda editor prompt)
          (soda editor state))

  (define debugger-resource "*scheme-debugger*")

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
              (view-set-caret! view 0)))
          (editor-views editor)))
      buffer))

  (define (close-session-debugger! editor session)
    (let ([debugger (interaction-session-debugger session)])
      (when debugger
        (let ([buffer (debugger-buffer editor debugger)])
          (when buffer
            (for-each
              (lambda (view)
                (when (= (buffer-id (view-buffer view))
                         (buffer-id buffer))
                  (editor-set-view-buffer!
                    editor
                    (view-id view)
                    (interaction-session-buffer-id session))))
              (editor-views editor))
            (editor-remove-buffer! editor (buffer-id buffer))))
        (debugger-session-close! debugger)
        (interaction-session-set-debugger! session #f))))

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

  (define (active-debug-session editor view)
    (let* ([buffer-id (buffer-id (view-buffer view))]
           [interaction
             (editor-interaction-for-buffer editor buffer-id)])
      (or
        interaction
        (find
          (lambda (session)
            (let ([debugger
                    (interaction-session-debugger session)])
              (and
                debugger
                (not (debugger-session-closed? debugger))
                (equal?
                  (debugger-session-buffer-id debugger)
                  buffer-id))))
          (editor-interactions editor)))))

  (define (require-failed-debug-session who context)
    (let* ([editor (command-context-editor context)]
           [session
             (active-debug-session
               editor
               (command-context-view context))])
      (unless
        (and
          session
          (eq? (interaction-session-state session) 'failed))
        (assertion-violation
          who
          "active buffer has no failed interaction"))
      session))

  (define (debug-open-command context)
    (let* ([editor (command-context-editor context)]
           [session
             (require-failed-debug-session
               'scheme.debug-open
               context)]
           [debugger (interaction-session-debugger session)])
      (unless debugger
        (assertion-violation
          'scheme.debug-open
          "failed interaction has no debugger"))
      (let ([buffer (debugger-buffer editor debugger)])
        (unless buffer
          (set! buffer
            (editor-create-buffer!
              editor
              debugger-resource
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
          (view-id (command-context-view context))
          (buffer-id buffer))
        (editor-set-status-message!
          editor
          "Debugger: n/p frame, e evaluate, r retry, q dismiss")
        '())))

  (define (move-debug-frame-command context delta)
    (let* ([editor (command-context-editor context)]
           [session
             (require-failed-debug-session
               'scheme.debug-frame
               context)]
           [debugger (interaction-session-debugger session)]
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

  (define (evaluate-debug-expression! editor session source)
    (let ([debugger (interaction-session-debugger session)])
      (unless debugger
        (assertion-violation
          'scheme.debug-eval-frame
          "failed interaction has no debugger"))
      (guard (condition
               [else
                (editor-set-status-message!
                  editor
                  (string-append
                    "Debugger evaluation failed: "
                    (condition->string condition)))])
        (let ([values
                (debugger-session-evaluate
                  debugger
                  source)])
          (editor-set-status-message!
            editor
            (string-append
              source
              " => "
              (values->string values)))))))

  (define (debug-eval-frame-command context)
    (let* ([editor (command-context-editor context)]
           [session
             (require-failed-debug-session
               'scheme.debug-eval-frame
               context)]
           [argument (command-context-argument context)])
      (cond
        [(string? argument)
         (evaluate-debug-expression!
           editor
           session
           argument)]
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
               (interaction-session-id session)
               (interaction-session-generation session))))]
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
      (when
        (and
          (pair? identity)
          (integer? (car identity))
          (integer? (cdr identity))
          source
          (positive? (string-length source)))
        (let ([session
                (editor-interaction-ref
                  editor
                  (car identity))])
          (when
            (and
              (= (interaction-session-generation session)
                 (cdr identity))
              (eq? (interaction-session-state session) 'failed))
            (evaluate-debug-expression!
              editor
              session
              source))))
      '()))

  (define (debug-retry-command context)
    (let* ([editor (command-context-editor context)]
           [session
             (require-failed-debug-session
               'scheme.debug-retry
               context)]
           [result
             (interaction-session-last-result session)])
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

  (define (debug-dismiss-command context)
    (let* ([editor (command-context-editor context)]
           [session
             (require-failed-debug-session
               'scheme.debug-dismiss
               context)])
      (close-session-debugger! editor session)
      (interaction-session-dismiss-failure! session)
      (editor-set-status-message! editor #f)
      '()))

  (define (register-debugger-command!
            editor
            name
            procedure
            documentation)
    (editor-register-command!
      editor
      name
      procedure
      documentation))

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
          'scheme.debug-eval-frame-accept
          debug-eval-frame-accept-command
          "Apply input from the debugger evaluation prompt.")
        (list
          'scheme.debug-retry
          debug-retry-command
          "Retry the failed evaluation in the active interaction.")
        (list
          'scheme.debug-dismiss
          debug-dismiss-command
          "Dismiss the failed evaluation in the active interaction.")))
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
          (#\q . scheme.debug-dismiss)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'debugger-mode-map
        keymap))))
