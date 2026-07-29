(library (soda editor repl)
  (export install-interaction-commands!
          install-interaction-effect-handler!
          editor-open-repl!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor comint)
          (soda editor effect)
          (soda editor evaluator)
          (soda editor event)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor state))

  (define repl-resource "*scheme-repl*")
  (define repl-prompt "> ")
  (define repl-header "Soda Chez Scheme REPL\n> ")

  (define (buffer-size buffer)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (text-size text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (string-contains? value needle)
    (let ([limit (- (string-length value)
                    (string-length needle))])
      (let loop ([index 0])
        (and
          (<= index limit)
          (or
            (string=?
              (substring
                value
                index
                (+ index (string-length needle)))
              needle)
            (loop (+ index 1)))))))

  (define (incomplete-read-condition? condition)
    (and
      (irritants-condition? condition)
      (exists
        (lambda (value)
          (and
            (string? value)
            (string-contains?
              value
              "unexpected end-of-file")))
        (condition-irritants condition))))

  (define (source-complete? source)
    (guard (condition
             [else
              (not (incomplete-read-condition? condition))])
      (let ([port (open-string-input-port source)])
        (let loop ()
          (let ([form (read port)])
            (if (eof-object? form)
                #t
                (loop)))))))

  (define (repl-session editor)
    (find
      (lambda (session)
        (and (eq? (interaction-session-kind session) 'repl)
             (not (interaction-session-closed? session))))
      (editor-interactions editor)))

  (define (activate-session-view! editor session)
    (activate-interaction-view!
      editor
      session
      '(scheme.repl)))

  (define (editor-open-repl! editor)
    (require-open-editor 'editor-open-repl! editor)
    (let ([existing (repl-session editor)])
      (if existing
          (begin
            (activate-session-view! editor existing)
            existing)
          (let* ([buffer
                   (editor-create-buffer!
                     editor
                     repl-resource
                     'scheme-mode
                     repl-header)]
                 [input-start (buffer-size buffer)]
                 [session
                   (editor-register-interaction!
                     editor
                     'repl
                     "Chez Scheme"
                     (buffer-id buffer)
                     (make-chez-evaluator)
                     repl-prompt
                     input-start)])
            (buffer-set-local-setting!
              buffer
              'track-modified?
              #f)
            (buffer-set-local-setting!
              buffer
              'completion-providers
              '(scheme-repl))
            (document-set-editable-start!
              (buffer-document buffer)
              input-start)
            (activate-session-view! editor session)
            session))))

  (define (session-buffer editor session)
    (comint-session-buffer editor session))

  (define (buffer-origin buffer start end)
    (make-evaluation-origin
      (buffer-id buffer)
      (buffer-resource buffer)
      (buffer-revision buffer)
      start
      end))

  (define (session-submit-source! editor session source echo? origin)
    (when (eq? (interaction-session-state session) 'evaluating)
      (assertion-violation
        'scheme.repl-submit
        "REPL session is already evaluating"
        (interaction-session-id session)))
    (when echo?
      (comint-stash-current-input! editor session)
      (comint-replace-input! editor session source))
    (comint-commit-input! editor session)
    (list
      (make-command-effect
        'scheme.evaluate
        (interaction-session-begin! session source origin))))

  (define (open-repl-command context)
    (let* ([editor (command-context-editor context)]
           [session (repl-session editor)]
           [active-buffer
             (view-buffer (editor-active-view editor))])
      (if (and session
               (= (buffer-id active-buffer)
                  (interaction-session-buffer-id session)))
          (let ([other
                  (find
                    (lambda (view)
                      (not
                        (= (buffer-id (view-buffer view))
                           (interaction-session-buffer-id session))))
                    (reverse (editor-views editor)))])
            (when other
              (editor-set-active-view! editor (view-id other))))
          (editor-open-repl! editor)))
    '())

  (define (repl-submit-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)]
           [session
             (editor-interaction-for-buffer
               editor
               (buffer-id buffer))])
      (unless (and session
                   (eq? (interaction-session-kind session) 'repl))
        (assertion-violation
          'scheme.repl-submit
          "active buffer is not a REPL transcript"
          (buffer-id buffer)))
      (let* ([start (interaction-session-input-start session)]
             [end (buffer-size buffer)]
             [source (comint-current-input editor session)])
        (if (source-complete? source)
            (session-submit-source!
              editor
              session
              source
              #f
              (buffer-origin buffer start end))
            (begin
              (comint-insert-newline! view)
              '())))))

  (define (eval-expression-command context)
    (let* ([argument (command-context-argument context)]
           [source
             (cond
               [(string? argument) argument]
               [(bytevector? argument) (utf8->string argument)]
               [else
                (assertion-violation
                  'scheme.eval-expression
                  "expression must be a string or bytevector"
                  argument)])]
           [editor (command-context-editor context)]
           [source-buffer (view-buffer (command-context-view context))]
           [session (editor-open-repl! editor)])
      (session-submit-source!
        editor
        session
        source
        #t
        (buffer-origin source-buffer #f #f))))

  (define (matching-result-session editor result)
    (let* ([request (evaluation-result-request result)]
           [session
             (editor-interaction-ref
               editor
               (evaluation-request-session-id request))])
      (unless
        (and (= (evaluation-request-generation request)
                (interaction-session-generation session))
             (eq? (interaction-session-state session) 'evaluating))
        (assertion-violation
          'scheme.apply-evaluation-result
          "evaluation result is stale"
          request))
      session))

  (define (apply-evaluation-result-command context)
    (let ([result (command-context-argument context)]
          [editor (command-context-editor context)])
      (unless (evaluation-result? result)
        (assertion-violation
          'scheme.apply-evaluation-result
          "expected an evaluation result"
          result))
      (let ([session (matching-result-session editor result)])
        (comint-append-output!
          editor
          session
          (evaluation-result->transcript result))
        (interaction-session-complete! session result)
        (editor-set-status-message!
          editor
          (if (eq? (evaluation-result-status result) 'condition)
              "Evaluation failed; debugger actions: retry, dismiss"
              #f))
        '())))

  (define (debug-retry-command context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [session
             (editor-interaction-for-buffer
               editor
               (buffer-id buffer))]
           [result
             (and session
                  (interaction-session-last-result session))])
      (unless
        (and result
             (eq? (interaction-session-state session) 'failed))
        (assertion-violation
          'scheme.debug-retry
          "active interaction has no failed evaluation"))
      (comint-stash-current-input! editor session)
      (comint-replace-input! editor session ";; retry")
      (session-submit-source!
        editor
        session
        (evaluation-request-source
          (evaluation-result-request result))
        #f
        (evaluation-request-origin
          (evaluation-result-request result)))))

  (define (debug-dismiss-command context)
    (let* ([editor (command-context-editor context)]
           [buffer (view-buffer (command-context-view context))]
           [session
             (editor-interaction-for-buffer
               editor
               (buffer-id buffer))])
      (unless session
        (assertion-violation
          'scheme.debug-dismiss
          "active buffer has no interaction session"))
      (interaction-session-dismiss-failure! session)
      (editor-set-status-message! editor #f)
      '()))

  (define (install-interaction-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (car entry)
          (cadr entry)
          (caddr entry)))
      (list
        (list
          'scheme.open-repl
          open-repl-command
          "Toggle the editor-owned Chez Scheme REPL view.")
        (list
          'scheme.repl-submit
          repl-submit-command
          "Submit the editable input in the REPL transcript.")
        (list
          'scheme.repl-history-previous
          comint-history-previous-command
          "Replace REPL input with the previous history entry.")
        (list
          'scheme.repl-history-next
          comint-history-next-command
          "Replace REPL input with the next history entry.")
        (list
          'scheme.repl-clear-input
          comint-clear-input-command
          "Clear the editable input in the REPL transcript.")
        (list
          'scheme.eval-expression
          eval-expression-command
          "Evaluate a Scheme expression in the persistent REPL session.")
        (list
          'scheme.apply-evaluation-result
          apply-evaluation-result-command
          "Apply an evaluator result to its interaction session.")
        (list
          'scheme.debug-retry
          debug-retry-command
          "Retry the failed evaluation in the active interaction.")
        (list
          'scheme.debug-dismiss
          debug-dismiss-command
          "Dismiss the failed evaluation in the active interaction.")))
    (let ([keymap
            (or
              (keymap-catalog-find
                (editor-keymap-catalog editor)
                'scheme.repl)
              (let ([value (make-keymap)])
                (keymap-catalog-register!
                  (editor-keymap-catalog editor)
                  'scheme.repl
                  value)
                value))])
      (keymap-bind!
        keymap
        (list (make-key-stroke 'enter 13 0))
        'scheme.repl-submit)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\p)
            2))
        'interaction.history-previous)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\n)
            2))
        'interaction.history-next)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\c)
            4)
          (make-key-stroke
            'character
            (char->integer #\u)
            4))
        'interaction.clear-input))
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\c) 4)
        (make-key-stroke 'character (char->integer #\z) 4))
      'scheme.open-repl)
    editor)

  (define (install-interaction-effect-handler! executor editor)
    (register-effect-handler!
      executor
      'scheme.evaluate
      (lambda (request)
        (unless (evaluation-request? request)
          (assertion-violation
            'scheme.evaluate
            "expected an evaluation request"
            request))
        (let* ([session
                 (editor-interaction-ref
                   editor
                   (evaluation-request-session-id request))]
               [result
                 (chez-evaluator-evaluate
                   (interaction-session-evaluator session)
                   request
                   editor
                   session)])
          (make-effect-result
            #t
            (cons
              (make-internal-command-message
                'scheme.apply-evaluation-result
                result)
              (evaluation-result-messages result))))))
    executor))
