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
          (soda editor completion)
          (soda editor condition)
          (soda editor debugger)
          (soda editor edit)
          (soda editor file)
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
        (if
          (and
            (debugger-session-interaction-id debugger)
            (evaluation-suspension-condition?
              (debugger-session-condition debugger)))
          "Debugger: c continue, r restart, q abort, k continuation"
          "Debugger: n/p frame, e eval, i condition, l local, d/u inspect"))
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
    (if
      (memq
        (evaluation-result-status result)
        '(condition suspended))
        (guard (condition
                 [else
                  (editor-set-status-message!
                    editor
                    "Evaluation failed; debugger is unavailable")])
          (let ([debugger
                  (make-debugger-session session result)])
            (interaction-session-set-debugger!
              session
              debugger)
            (if
              (eq? (evaluation-result-status result) 'suspended)
              (begin
                (open-debugger!
                  editor
                  (editor-active-view editor)
                  debugger)
                (editor-set-status-message!
                  editor
                  "Evaluation suspended; c continue, r restart, q abort"))
              (editor-set-status-message!
                editor
                "Evaluation failed; M-x scheme.debug-open"))))
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

  (define (debug-visit-source-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-visit-source
               context)]
           [frame
             (debugger-session-selected-frame
               (cadr target))])
      (unless
        (and
          frame
          (string? (debugger-frame-source-path frame))
          (integer? (debugger-frame-source-line frame))
          (exact? (debugger-frame-source-line frame))
          (not (negative? (debugger-frame-source-line frame))))
        (editor-user-error
          'scheme.debug-visit-source
          "selected frame has no source location"))
      (editor-set-status-message!
        editor
        (string-append
          "Reading "
          (debugger-frame-source-path frame)))
      (list
        (make-command-effect
          'file.read
          (make-open-request
            (view-id (command-context-view context))
            (debugger-frame-source-path frame)
            (make-file-source-position
              (debugger-frame-source-line frame)
              (or
                (debugger-frame-source-character frame)
                0)))))))

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
              (refresh-debugger-buffer! editor debugger)
              (editor-set-status-message!
                editor
                (string-append
                  "Debugger evaluation failed: "
                  (condition->string condition)))])
           (let ([values
                   (debugger-session-evaluate
                     debugger
                     argument)])
             (refresh-debugger-buffer! editor debugger)
             (editor-set-status-message!
               editor
               (string-append
                 argument
                 " => "
                 (values->string values)))))]
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
                     (refresh-debugger-buffer! editor debugger)
                     (editor-set-status-message!
                       editor
                       (string-append
                         "Debugger evaluation failed: "
                         (condition->string condition)))])
                  (let ([values
                          (debugger-session-evaluate
                            debugger
                            source)])
                    (refresh-debugger-buffer! editor debugger)
                    (editor-set-status-message!
                      editor
                      (string-append
                        source
                        " => "
                        (values->string values))))))))))
      '()))

  (define (debug-inspect-ref-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-ref
               context)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(and (integer? argument)
              (exact? argument)
              (not (negative? argument)))
         (debugger-session-inspection-down! debugger argument)
         (refresh-debugger-buffer! editor debugger)]
        [(not argument)
         (unless (debugger-session-inspection-active? debugger)
           (editor-user-error
             'scheme.debug-inspect-ref
             "evaluate an expression before inspecting a child"))
         (editor-open-prompt!
           editor
           (make-prompt-request
             "Inspect child index: "
             ""
             'scheme-debug-inspect-ref
             #f
             'free
             #f
             'scheme.debug-inspect-ref-accept
             #f
             (cons
               (debugger-session-origin debugger)
               (debugger-session-generation debugger))))]
        [else
         (assertion-violation
           'scheme.debug-inspect-ref
           "child index must be a non-negative exact integer or #f"
           argument)])
      '()))

  (define (debug-inspect-local-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-local
               context)]
           [debugger (cadr target)]
           [argument (command-context-argument context)])
      (cond
        [(and (integer? argument)
              (exact? argument)
              (not (negative? argument)))
         (debugger-session-inspect-local! debugger argument)
         (refresh-debugger-buffer! editor debugger)]
        [(not argument)
         (editor-open-prompt!
           editor
           (make-prompt-request
             "Inspect local index: "
             ""
             'scheme-debug-inspect-local
             #f
             'free
             #f
             'scheme.debug-inspect-local-accept
             #f
             (cons
               (debugger-session-origin debugger)
               (debugger-session-generation debugger))))]
        [else
         (assertion-violation
           'scheme.debug-inspect-local
           "local index must be a non-negative exact integer or #f"
           argument)])
      '()))

  (define (debug-inspect-condition-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-condition
               context)]
           [debugger (cadr target)])
      (debugger-session-inspect-condition! debugger)
      (refresh-debugger-buffer! editor debugger)
      '()))

  (define (debug-inspect-continuation-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-continuation
               context)]
           [debugger (cadr target)])
      (guard
        (condition
          [else
           (editor-user-error
             'scheme.debug-inspect-continuation
             "The raise continuation is unavailable")])
        (debugger-session-inspect-continuation! debugger)
        (refresh-debugger-buffer! editor debugger))
      '()))

  (define (apply-inspect-local-result! editor view result)
    (let* ([identity
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [source
             (and
               (prompt-result? result)
               (prompt-result-value result))]
           [target (active-debug-target editor view)])
      (when
        (and target source (positive? (string-length source)))
        (let ([debugger (cadr target)])
          (when
            (and
              (pair? identity)
              (eq? (car identity)
                   (debugger-session-origin debugger))
              (= (cdr identity)
                 (debugger-session-generation debugger)))
            (let ([index (string->number source)])
              (unless
                (and index
                     (integer? index)
                     (exact? index)
                     (not (negative? index)))
                (editor-user-error
                  'scheme.debug-inspect-local
                  "local index must be a non-negative integer"))
              (debugger-session-inspect-local! debugger index)
              (refresh-debugger-buffer! editor debugger)))))))

  (define (debug-inspect-local-accept-command context)
    (apply-inspect-local-result!
      (command-context-editor context)
      (command-context-view context)
      (command-context-argument context))
    '())

  (define (debug-inspect-ref-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [identity
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [source
             (and
               (prompt-result? result)
               (prompt-result-value result))]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (when
        (and target
             source
             (positive? (string-length source)))
        (let ([debugger (cadr target)])
          (when
            (and
              (pair? identity)
              (eq? (car identity)
                   (debugger-session-origin debugger))
              (= (cdr identity)
                 (debugger-session-generation debugger)))
            (let ([index (string->number source)])
              (unless
                (and index
                     (integer? index)
                     (exact? index)
                     (not (negative? index)))
                (editor-user-error
                  'scheme.debug-inspect-ref
                  "child index must be a non-negative integer"))
              (debugger-session-inspection-down!
                debugger
                index)
              (refresh-debugger-buffer! editor debugger)))))
      '()))

  (define (debug-inspect-up-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-inspect-up
               context)]
           [debugger (cadr target)])
      (debugger-session-inspection-up! debugger)
      (refresh-debugger-buffer! editor debugger)
      '()))

  (define (restart-evaluation!
            editor
            session
            source
            origin)
    (let ([suspended?
            (eq? (interaction-session-state session) 'suspended)])
      (comint-stash-current-input! editor session)
      (when suspended?
        (interaction-session-abort-suspension! session))
      (close-session-debugger! editor session)
      (comint-replace-input! editor session ";; retry")
      (comint-commit-input! editor session)
      (let ([evaluate-effect
              (make-command-effect
                'scheme.evaluate
                (interaction-session-begin!
                  session
                  source
                  origin))])
        (if suspended?
            (list
              (make-command-effect
                'scheme.abort-evaluation
                (interaction-session-id session))
              evaluate-effect)
            (list evaluate-effect)))))

  (define (debug-continue-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-continue
               context)]
           [session (car target)])
      (unless
        (and
          session
          (eq? (interaction-session-state session) 'suspended))
        (editor-user-error
          'scheme.debug-continue
          "The debugger has no suspended evaluation"))
      (close-session-debugger! editor session)
      (interaction-session-resume! session)
      (list
        (make-command-effect
          'scheme.resume-evaluation
          (make-evaluation-resume-request
            (interaction-session-id session)
            (interaction-session-generation session)
            'continue
            '())))))

  (define (debug-use-value-command context)
    (let* ([target
             (require-debug-target
               'scheme.debug-use-value
               context)]
           [debugger (cadr target)])
      (unless
        (debugger-session-continuation debugger)
        (editor-user-error
          'scheme.debug-use-value
          "The condition has no resumable continuation"))
      (editor-open-prompt!
        (command-context-editor context)
        (make-prompt-request
          "Replacement expression: "
          ""
          'scheme-debug-replacement
          #f
          'free
          #f
          'scheme.debug-use-value-accept
          #f
          (cons
            (debugger-session-origin debugger)
            (debugger-session-generation debugger))))
      '()))

  (define (debug-use-value-accept-command context)
    (let* ([editor (command-context-editor context)]
           [prompt-result (command-context-argument context)]
           [source
             (and
               (prompt-result? prompt-result)
               (eq? (prompt-result-status prompt-result) 'accepted)
               (prompt-result-value prompt-result))]
           [identity
             (and
               (prompt-result? prompt-result)
               (prompt-result-data prompt-result))]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (if
        (and
          target
          source
          (positive? (string-length source))
          (pair? identity)
          (eq? (car identity)
               (debugger-session-origin (cadr target)))
          (= (cdr identity)
             (debugger-session-generation (cadr target))))
        (guard
          (condition
            [else
             (editor-set-status-message!
               editor
               (string-append
                 "Replacement evaluation failed: "
                 (condition->string condition)))
             '()])
          (let* ([session (car target)]
                 [debugger (cadr target)]
                 [values
                   (debugger-session-evaluate
                     debugger
                     source)])
            (unless session
              (editor-user-error
                'scheme.debug-use-value
                "The debugger is not attached to an evaluation"))
            (close-session-debugger! editor session)
            (interaction-session-resume! session)
            (list
              (make-command-effect
                'scheme.resume-evaluation
                (make-evaluation-resume-request
                  (interaction-session-id session)
                  (interaction-session-generation session)
                  'use-values
                  values)))))
        '())))

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
      (let ([request (evaluation-result-request result)])
        (restart-evaluation!
          editor
          session
          (evaluation-request-source request)
          (evaluation-request-origin request)))))

  (define (debug-edit-and-retry-command context)
    (let* ([editor (command-context-editor context)]
           [target
             (require-debug-target
               'scheme.debug-edit-and-retry
               context)]
           [session (car target)]
           [debugger (cadr target)]
           [result
             (and session
                  (interaction-session-last-result session))])
      (unless result
        (editor-user-error
          'scheme.debug-edit-and-retry
          "The debugger is not attached to an evaluation"))
      (editor-open-prompt!
        editor
        (make-prompt-request
          "Restart source: "
          (evaluation-request-source
            (evaluation-result-request result))
          'scheme-debug-restart-source
          #f
          'free
          #f
          'scheme.debug-edit-and-retry-accept
          #f
          (cons
            (debugger-session-origin debugger)
            (debugger-session-generation debugger))))
      '()))

  (define (debug-edit-and-retry-accept-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [source
             (and
               (prompt-result? result)
               (eq? (prompt-result-status result) 'accepted)
               (prompt-result-value result))]
           [identity
             (and
               (prompt-result? result)
               (prompt-result-data result))]
           [target
             (active-debug-target
               editor
               (command-context-view context))])
      (if
        (and
          target
          source
          (positive? (string-length source))
          (pair? identity)
          (eq? (car identity)
               (debugger-session-origin (cadr target)))
          (= (cdr identity)
             (debugger-session-generation (cadr target))))
        (let* ([session (car target)]
               [debugger (cadr target)]
               [failed
                 (and session
                      (interaction-session-last-result session))])
          (unless failed
            (editor-user-error
              'scheme.debug-edit-and-retry
              "The failed evaluation is unavailable"))
          (restart-evaluation!
            editor
            session
            source
            (evaluation-request-origin
              (evaluation-result-request failed))))
        '())))

  (define (restart-options session debugger)
    (if
      (and
        session
        (eq? (interaction-session-state session) 'suspended))
      '(("continue" continue "Continue the suspended evaluation")
        ("retry" retry "Retry the original evaluation")
        ("edit-and-retry" edit-and-retry "Edit source before retrying")
        ("abort" abort "Abort the suspended evaluation"))
      (append
        '(("retry" retry "Retry the original evaluation"))
        (if (debugger-session-continuation debugger)
            '(("use-value" use-value "Resume with replacement values"))
            '())
        '(("edit-and-retry" edit-and-retry "Edit source before retrying")
          ("abort" abort "Discard the failed evaluation")))))

  (define (restart-choice-source options)
    (let ([items
            (map
              (lambda (entry)
                (make-completion-item
                  (cadr entry)
                  'scheme-debugger
                  (car entry)
                  (car entry)
                  (car entry)
                  (caddr entry)
                  #f
                  (cadr entry)))
              options)])
      (make-choice-source
        'scheme-debug-restart
        '((styles . (fzf))
          (preselect . #t))
        (lambda (input point)
          (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (entry)
              (string=? value (car entry)))
            options))
        (lambda (generation) #f))))

  (define (debug-restart-command context)
    (let* ([target
             (require-debug-target
               'scheme.debug-restart
               context)]
           [session (car target)]
           [debugger (cadr target)]
           [options (restart-options session debugger)])
      (editor-open-prompt!
        (command-context-editor context)
        (make-completing-prompt-request
          "Restart: "
          ""
          'scheme-debug-restart
          (if
            (and
              session
              (eq? (interaction-session-state session) 'suspended))
            "continue"
            "retry")
          'must-match
          (restart-choice-source options)
          'scheme.debug-restart-accept
          #f
          (cons
            (debugger-session-origin debugger)
            (debugger-session-generation debugger))))
      '()))

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
      (let* ([suspended?
              (and
                session
                (eq? (interaction-session-state session)
                     'suspended))]
             [evaluation?
               (and
                 session
                 (memq
                   (interaction-session-state session)
                   '(failed suspended)))])
        (discard-debugger! editor session debugger)
        (when session
          (if suspended?
              (begin
                (interaction-session-abort-suspension! session)
                (comint-append-output!
                  editor
                  session
                  "Interrupted\n"))
              (interaction-session-dismiss-failure! session)))
        (editor-set-status-message! editor #f)
        (if evaluation?
            (list
              (make-command-effect
                'scheme.abort-evaluation
                (interaction-session-id session)))
            '()))))

  (define (debug-restart-accept-command context)
    (let* ([result (command-context-argument context)]
           [candidate
             (and
               (prompt-result? result)
               (prompt-result-candidate result))]
           [choice
             (and
               candidate
               (completion-item-payload candidate))])
      (case choice
        [(continue) (debug-continue-command context)]
        [(use-value) (debug-use-value-command context)]
        [(retry) (debug-retry-command context)]
        [(edit-and-retry)
         (debug-edit-and-retry-command context)]
        [(abort) (debug-discard-command context)]
        [else '()])))

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
          'scheme.debug-continue
          debug-continue-command
          "Continue a suspended Scheme evaluation.")
        (list
          'scheme.debug-use-value
          debug-use-value-command
          "Resume a failed continuation with replacement values.")
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
          'scheme.debug-inspect-ref
          debug-inspect-ref-command
          "Inspect a child of the last debugger evaluation result.")
        (list
          'scheme.debug-inspect-local
          debug-inspect-local-command
          "Inspect a local value in the selected debugger frame.")
        (list
          'scheme.debug-inspect-condition
          debug-inspect-condition-command
          "Inspect the original Scheme condition object.")
        (list
          'scheme.debug-inspect-continuation
          debug-inspect-continuation-command
          "Inspect the saved raise continuation.")
        (list
          'scheme.debug-inspect-up
          debug-inspect-up-command
          "Return to the parent debugger inspection object.")
        (list
          'scheme.debug-visit-source
          debug-visit-source-command
          "Visit the source location of the selected debugger frame.")
        (list
          'scheme.debug-retry
          debug-retry-command
          "Retry the failed evaluation in the active interaction.")
        (list
          'scheme.debug-edit-and-retry
          debug-edit-and-retry-command
          "Edit and retry the failed evaluation.")
        (list
          'scheme.debug-restart
          debug-restart-command
          "Select a restart for the failed evaluation.")
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
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-inspect-ref-accept
        debug-inspect-ref-accept-command
        "Apply a child index from the debugger inspector prompt."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-inspect-local-accept
        debug-inspect-local-accept-command
        "Apply a local index from the debugger inspector prompt."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-edit-and-retry-accept
        debug-edit-and-retry-accept-command
        "Restart a failed evaluation with edited source."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-restart-accept
        debug-restart-accept-command
        "Apply the debugger restart selected by the minibuffer."))
    (editor-register-internal-command!
      editor
      (make-internal-context-command
        'scheme.debug-use-value-accept
        debug-use-value-accept-command
        "Resume a failed continuation with replacement values."))
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
          (#\c . scheme.debug-continue)
          (#\i . scheme.debug-inspect-condition)
          (#\k . scheme.debug-inspect-continuation)
          (#\= . scheme.debug-use-value)
          (#\l . scheme.debug-inspect-local)
          (#\d . scheme.debug-inspect-ref)
          (#\u . scheme.debug-inspect-up)
          (#\v . scheme.debug-visit-source)
          (#\r . scheme.debug-restart)
          (#\x . scheme.debug-exit)
          (#\q . scheme.debug-discard)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'debugger-mode-map
        keymap))))
