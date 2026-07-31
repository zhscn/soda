(library (soda editor repl)
  (export install-interaction-commands!
          install-interaction-effect-handler!
          editor-open-repl!)
  (import (rnrs)
          (only (chezscheme) port-position)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor comint)
          (soda editor condition)
          (soda editor debugger-commands)
          (soda editor effect)
          (soda editor evaluator)
          (soda editor event)
          (soda editor interaction)
          (soda editor keymap)
          (soda editor scheme-indentation)
          (soda editor scheme-repl-indentation)
          (soda editor state)
          (soda editor window-runtime))

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
                     (editor-evaluator editor)
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
            (buffer-set-local-setting!
              buffer
              'completion-auto-trigger?
              #f)
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

  (define (buffer-range-source buffer start end)
    (let ([snapshot (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (unless (and (integer? start)
                             (exact? start)
                             (integer? end)
                             (exact? end)
                             (<= 0 start end (text-size text)))
                  (assertion-violation
                    'buffer-range-source
                    "evaluation range is outside the buffer"
                    start
                    end))
                (utf8->string
                  (text-subbytevector text start end)))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

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
            (unless other
              (let ([other-buffer
                      (find
                        (lambda (candidate)
                          (not
                            (= (buffer-id candidate)
                               (interaction-session-buffer-id
                                 session))))
                        (editor-buffers editor))])
                (when other-buffer
                  (set! other
                    (editor-open-view!
                      editor
                      (buffer-id other-buffer))))))
            (when other
              (editor-display-view-other-window!
                editor
                (view-id other))))
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
              (comint-insert-newline-with-indent!
                view
                (scheme-continuation-indent
                  (buffer-range-source
                    buffer
                    start
                    (view-caret view))
                  (buffer-setting-ref
                    buffer
                    'indent-width
                    2)))
              '())))))

  (define (interrupt-evaluation-command context)
    (let* ([editor (command-context-editor context)]
           [active-buffer
             (view-buffer (command-context-view context))]
           [active-session
             (editor-interaction-for-buffer
               editor
               (buffer-id active-buffer))]
           [session
             (if
               (and
                 active-session
                 (eq? (interaction-session-state active-session)
                      'evaluating))
               active-session
               (find
                 (lambda (candidate)
                   (eq? (interaction-session-state candidate)
                        'evaluating))
                 (editor-interactions editor)))])
      (unless session
        (editor-user-error
          'scheme.interrupt-evaluation
          "No Scheme evaluation is running"))
      (list
        (make-command-effect
          'scheme.interrupt-evaluation
          (interaction-session-id session)))))

  (define (keyboard-quit-evaluation-advice
            next
            context
            arguments)
    (let ([editor (command-context-editor context)])
      (if
        (and
          (not (editor-active-prompt editor))
          (exists
            (lambda (session)
              (eq? (interaction-session-state session)
                   'evaluating))
            (editor-interactions editor)))
        (interrupt-evaluation-command context)
        (next context arguments))))

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

  (define (submit-buffer-target! context target)
    (let ([buffer
            (view-buffer
              (command-context-view context))])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'scheme.eval-range
          "The evaluation target is stale"))
      (when (command-target-empty? target)
        (editor-user-error
          'scheme.eval-range
          "The evaluation target is empty"))
      (let* ([start (command-target-start target)]
             [end (command-target-end target)]
             [editor (command-context-editor context)]
             [source (buffer-range-source buffer start end)]
             [origin (buffer-origin buffer start end)]
             [session (editor-open-repl! editor)])
        (session-submit-source!
          editor
          session
          source
          #t
          origin))))

  (define eval-region-target-reader
    (make-command-target-reader
      'scheme-eval-region-target
      (make-command-target-selector
        'require
        #t
        #f)))

  (define eval-buffer-target-reader
    (make-command-target-reader
      'scheme-eval-buffer-target
      (make-command-target-selector
        'ignore
        #f
        command-context-buffer-target)))

  (define-command (eval-region-command context target)
    "Evaluate the active Scheme region."
    (interactive eval-region-target-reader)
    (submit-buffer-target! context target))

  (define-command (eval-buffer-command context target)
    "Evaluate the complete Scheme buffer."
    (interactive eval-buffer-target-reader)
    (submit-buffer-target! context target))

  (define (last-datum-character-range source)
    (define (skip-whitespace start end)
      (let loop ([offset start])
        (if (and (< offset end)
                 (char-whitespace? (string-ref source offset)))
            (loop (+ offset 1))
            offset)))
    (let ([port (open-string-input-port source)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let loop ([last #f])
            (let* ([start (port-position port)]
                   [datum (read port)]
                   [end (port-position port)])
              (if (eof-object? datum)
                  last
                  (loop
                    (cons
                      (skip-whitespace start end)
                      end))))))
        (lambda () (close-port port)))))

  (define (character-offset->byte-offset source offset)
    (bytevector-length
      (string->utf8 (substring source 0 offset))))

  (define (last-sexp-target context)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [caret (view-caret view)]
           [source (buffer-range-source buffer 0 caret)]
           [range (last-datum-character-range source)])
      (unless range
        (editor-user-error
          'scheme.eval-last-sexp
          "No complete Scheme datum before point"))
      (command-context-range-target
        context
        'sexp
        (character-offset->byte-offset source (car range))
        (character-offset->byte-offset source (cdr range)))))

  (define eval-last-sexp-target-reader
    (make-command-target-reader
      'scheme-eval-last-sexp-target
      (make-command-target-selector
        'ignore
        #f
        last-sexp-target)))

  (define-command (eval-last-sexp-command context target)
    "Evaluate the complete Scheme datum before point."
    (interactive eval-last-sexp-target-reader)
    (submit-buffer-target! context target))

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
        (interaction-attach-debugger-result!
          editor
          session
          result)
        '())))

  (define (apply-evaluation-suspension-command context)
    (let ([result (command-context-argument context)]
          [editor (command-context-editor context)])
      (unless
        (and
          (evaluation-result? result)
          (eq? (evaluation-result-status result) 'suspended))
        (assertion-violation
          'scheme.apply-evaluation-suspension
          "expected a suspended evaluation result"
          result))
      (let ([session (matching-result-session editor result)])
        (interaction-session-suspend! session result)
        (interaction-attach-debugger-result!
          editor
          session
          result)
        '())))

  (define (install-interaction-commands! editor)
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
          'scheme.open-repl
          open-repl-command
          "Toggle the editor-owned Chez Scheme REPL view.")
        (list
          'scheme.repl-submit
          repl-submit-command
          "Submit the editable input in the REPL transcript.")
        (list
          'scheme.interrupt-evaluation
          interrupt-evaluation-command
          "Interrupt the active cooperative Scheme evaluation.")
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
          'scheme.eval-region
          eval-region-command
          "Evaluate the active region in the persistent REPL session.")
        (list
          'scheme.eval-buffer
          eval-buffer-command
          "Evaluate the active buffer in the persistent REPL session.")
        (list
          'scheme.eval-last-sexp
          eval-last-sexp-command
          "Evaluate the complete Scheme datum before point.")))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.apply-evaluation-result
        apply-evaluation-result-command
        "Apply an evaluator result to its interaction session."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.apply-evaluation-suspension
        apply-evaluation-suspension-command
        "Attach the debugger to a suspended evaluation."))
    (install-debugger-commands! editor)
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
      (install-scheme-repl-indentation! editor keymap)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\p)
            2))
        'interaction.history-previous-prefix)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\n)
            2))
        'interaction.history-next-prefix)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\P)
            2))
        'interaction.history-previous-contains)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\N)
            2))
        'interaction.history-next-contains)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'up #f 2))
        'interaction.history-previous)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'down #f 2))
        'interaction.history-next)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'up #f 0))
        'interaction.previous-line-or-history)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'down #f 0))
        'interaction.next-line-or-history)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\p)
            4))
        'interaction.previous-line-or-history)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\n)
            4))
        'interaction.next-line-or-history)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\<)
            2))
        'interaction.entry-start)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\>)
            2))
        'interaction.entry-end)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'home #f 0))
        'interaction.line-start)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\a)
            4))
        'interaction.line-start)
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
        'interaction.clear-input)
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character
            (char->integer #\c)
            4)
          (make-key-stroke
            'character
            (char->integer #\c)
            4))
        'scheme.interrupt-evaluation))
    (command-add-advice!
      (editor-command-registry editor)
      'keyboard.quit
      'scheme.interrupt-running-evaluation
      'around
      keyboard-quit-evaluation-advice
      -100)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\c) 4)
        (make-key-stroke 'character (char->integer #\z) 4))
      'scheme.open-repl)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\e) 4))
      'scheme.eval-last-sexp)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\x) 4)
        (make-key-stroke 'character (char->integer #\r) 4))
      'scheme.eval-region)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\:) 2))
      'scheme.eval-expression)
    (editor-bind-key!
      editor
      (list
        (make-key-stroke 'character (char->integer #\c) 4)
        (make-key-stroke 'character (char->integer #\b) 4))
      'scheme.eval-buffer)
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
    (register-effect-handler!
      executor
      'scheme.abort-evaluation
      (lambda (session-id)
        (make-effect-result #t '())))
    executor))
