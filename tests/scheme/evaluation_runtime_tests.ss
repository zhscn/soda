#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor core)
        (soda editor effect)
        (soda editor evaluation-runtime)
        (only (soda editor evaluator)
              chez-evaluator-evaluate-file!
              evaluation-result-continuation)
        (soda editor interaction)
        (soda editor repl)
        (soda runtime))

  (define debug-call-source
    "(let ([x 1])\n  (soda-debug-inner x)\n  (* x 3))")
  (define document
    (make-document debug-call-source 901))
  (define buffer
    (make-buffer 900 document "debug-call.ss" 'scheme-mode))
  (define editor (make-editor buffer))
  (define runtime (make-runtime))
  (define executor (make-effect-executor))
  (define adapter
    (install-evaluation-runtime! executor runtime editor 100))
  (define session (editor-open-repl! editor))

  (define (execute! effects)
    (let ([result (execute-effects! executor effects)])
      (unless (effect-result-continue? result)
        (error 'evaluation-runtime-tests
               "effect executor stopped unexpectedly"))
      (effect-result-messages result)))

  (define (next-evaluation-event)
    (let loop ()
      (let find ([events (runtime-poll! runtime)])
        (cond
          [(null? events) (loop)]
          [(evaluation-runtime-event? adapter (car events))
           (car events)]
          [else (find (cdr events))]))))

  (define (apply-messages! messages)
    (for-each
      (lambda (message)
        (execute! (editor-update! editor message)))
      messages))

  (define (run-until-evaluation-message!)
    (let loop ()
      (let ([messages
              (evaluation-runtime-handle-event
                adapter
                (next-evaluation-event))])
        (if (null? messages)
            (loop)
            (begin
              (apply-messages! messages)
              messages)))))

  (define finite-request
    (interaction-session-begin!
      session
      "(let loop ([n 3000] [sum 0]) (if (zero? n) sum (loop (- n 1) (+ sum n))))"))
  (execute!
    (list
      (make-command-effect 'scheme.evaluate finite-request)))

  (define finite-expirations 0)
  (let loop ()
    (let ([messages
            (evaluation-runtime-handle-event
              adapter
              (next-evaluation-event))])
      (if (null? messages)
          (begin
            (set! finite-expirations (+ finite-expirations 1))
            (loop))
          (apply-messages! messages))))

  (unless
    (and
      (positive? finite-expirations)
      (eq? (interaction-session-state session) 'ready)
      (equal?
        (evaluation-result-values
          (interaction-session-last-result session))
        '(4501500)))
    (error 'evaluation-runtime-tests
           "finite evaluation did not advance through engine slices"
           finite-expirations
           (interaction-session-state session)))

  (define source-debugger
    (chez-evaluator-source-debugger
      (interaction-session-evaluator session)))
  (define loaded-source-path
    (getenv "SODA_SOURCE_DEBUG_LOADED_FILE"))
  (chez-evaluator-evaluate-file!
    (interaction-session-evaluator session)
    loaded-source-path
    editor)
  (define loaded-breakpoint
    (source-debug-controller-add-breakpoint!
      source-debugger
      (make-source-location loaded-source-path 0 4096)))
  (define loaded-call-request
    (interaction-session-begin!
      session
      "(soda-debug-loaded 4)"))
  (execute!
    (list
      (make-command-effect
        'scheme.evaluate
        loaded-call-request)))
  (run-until-evaluation-message!)
  (define loaded-stop
    (source-debug-suspension-stop
      (evaluation-result-condition
        (interaction-session-last-result session))))
  (unless
    (and
      (eq? (source-debug-stop-kind loaded-stop) 'breakpoint)
      (string=?
        (source-location-resource
          (source-debug-stop-location loaded-stop))
        loaded-source-path))
    (error 'evaluation-runtime-tests
           "file-loaded Scheme code was not source instrumented"))
  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-continue #f)))
  (run-until-evaluation-message!)
  (unless
    (equal?
      (evaluation-result-values
        (interaction-session-last-result session))
      '(6))
    (error 'evaluation-runtime-tests
           "continued file-loaded evaluation did not complete"))
  (source-debug-controller-remove-breakpoint!
    source-debugger
    (source-breakpoint-id loaded-breakpoint))

  (define breakpoint-command-document
    (make-document "(define command-breakpoint 1)\n" 902))
  (define breakpoint-command-buffer
    (make-buffer
      902
      breakpoint-command-document
      "breakpoint-command.ss"
      'scheme-mode))
  (define breakpoint-command-editor
    (make-editor breakpoint-command-buffer))
  (define breakpoint-command-controller
    (chez-evaluator-source-debugger
      (editor-evaluator breakpoint-command-editor)))
  (editor-execute-command!
    breakpoint-command-editor
    'scheme.debug-toggle-breakpoint)
  (unless
    (= 1
       (length
         (source-debug-controller-breakpoints
           breakpoint-command-controller)))
    (error 'evaluation-runtime-tests
           "toggle breakpoint command did not create a line breakpoint"))
  (editor-execute-command!
    breakpoint-command-editor
    'scheme.debug-toggle-breakpoint)
  (unless
    (null?
      (source-debug-controller-breakpoints
        breakpoint-command-controller))
    (error 'evaluation-runtime-tests
           "toggle breakpoint command did not remove its line breakpoint"))
  (editor-execute-command!
    breakpoint-command-editor
    'scheme.debug-toggle-breakpoint)
  (editor-execute-command!
    breakpoint-command-editor
    'scheme.debug-list-breakpoints)
  (unless
    (string=?
      (buffer-resource
        (view-buffer
          (editor-active-view breakpoint-command-editor)))
      "*scheme-breakpoints*")
    (error 'evaluation-runtime-tests
           "list breakpoints command did not open its projection Buffer"))
  (editor-close! breakpoint-command-editor)

  (define debug-definition
    "(define (soda-debug-inner x)\n  (+ x 1))")
  (define debug-definition-request
    (interaction-session-begin!
      session
      debug-definition
      (make-evaluation-origin
        (buffer-id buffer)
        "debug-definition.ss"
        0
        0
        (string-length debug-definition))))
  (execute!
    (list
      (make-command-effect
        'scheme.evaluate
        debug-definition-request)))
  (run-until-evaluation-message!)

  (define call-breakpoint
    (source-debug-controller-add-breakpoint!
      source-debugger
      (make-source-location "debug-call.ss" 13 36)))

  (define (begin-debug-call!)
    (let ([request
            (interaction-session-begin!
              session
              debug-call-source
              (make-evaluation-origin
                (buffer-id buffer)
                "debug-call.ss"
                0
                0
                (string-length debug-call-source)))])
      (execute!
        (list
          (make-command-effect 'scheme.evaluate request)))
      (run-until-evaluation-message!)))

  (begin-debug-call!)
  (define breakpoint-result
    (interaction-session-last-result session))
  (define breakpoint-stop
    (and
      (source-debug-suspension-condition?
        (evaluation-result-condition breakpoint-result))
      (source-debug-suspension-stop
        (evaluation-result-condition breakpoint-result))))
  (unless
    (and
      breakpoint-stop
      (eq? (source-debug-stop-kind breakpoint-stop) 'breakpoint)
      (eq?
        (source-debug-stop-breakpoint breakpoint-stop)
        call-breakpoint)
      (equal?
        (map
          debugger-action-id
          (debugger-session-actions
            (interaction-session-debugger session)))
        '(continue step next finish retry edit-and-retry abort)))
    (error 'evaluation-runtime-tests
           "source breakpoint did not suspend with stepping actions"))

  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-visit-source #f)))
  (unless
    (and
      (eq?
        (view-buffer (editor-active-view editor))
        buffer)
      (=
        (view-caret (editor-active-view editor))
        (source-location-start
          (source-debug-stop-location breakpoint-stop)))
      (exists
        (lambda (visible)
          (eq?
            (buffer-major-mode-name
              (view-buffer visible))
            'debugger-mode))
        (editor-visible-views editor)))
    (error 'evaluation-runtime-tests
           "source visit did not preserve the debugger window"
           (buffer-resource
             (view-buffer (editor-active-view editor)))
           (view-caret (editor-active-view editor))
           (map
             (lambda (visible)
               (list
                 (buffer-resource (view-buffer visible))
                 (buffer-major-mode-name
                   (view-buffer visible))))
             (editor-visible-views editor))))
  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-open #f)))
  (unless
    (eq?
      (buffer-major-mode-name
        (view-buffer (editor-active-view editor)))
      'debugger-mode)
    (error 'evaluation-runtime-tests
           "debug open did not return focus to the visible debugger"))

  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-step #f)))
  (run-until-evaluation-message!)
  (define step-stop
    (source-debug-suspension-stop
      (evaluation-result-condition
        (interaction-session-last-result session))))
  (unless
    (and
      (eq? (source-debug-stop-kind step-stop) 'step)
      (string=?
        (source-location-resource
          (source-debug-stop-location step-stop))
        "debug-definition.ss"))
    (error 'evaluation-runtime-tests
           "source step did not enter the called procedure"))

  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-finish #f)))
  (run-until-evaluation-message!)
  (define finish-stop
    (source-debug-suspension-stop
      (evaluation-result-condition
        (interaction-session-last-result session))))
  (unless
    (and
      (eq? (source-debug-stop-kind finish-stop) 'finish)
      (string=?
        (source-location-resource
          (source-debug-stop-location finish-stop))
        "debug-call.ss")
      (= (source-location-start
           (source-debug-stop-location finish-stop))
         38))
    (error 'evaluation-runtime-tests
           "source finish did not return to the caller"))
  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-continue #f)))
  (run-until-evaluation-message!)
  (unless
    (and
      (eq? (interaction-session-state session) 'ready)
      (equal?
        (evaluation-result-values
          (interaction-session-last-result session))
        '(3)))
    (error 'evaluation-runtime-tests
           "continued source-debug evaluation did not complete"))

  (begin-debug-call!)
  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-next #f)))
  (run-until-evaluation-message!)
  (define next-stop
    (source-debug-suspension-stop
      (evaluation-result-condition
        (interaction-session-last-result session))))
  (unless
    (and
      (eq? (source-debug-stop-kind next-stop) 'next)
      (string=?
        (source-location-resource
          (source-debug-stop-location next-stop))
        "debug-call.ss")
      (= (source-location-start
           (source-debug-stop-location next-stop))
         38))
    (error 'evaluation-runtime-tests
           "source next did not step over the called procedure"))
  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-continue #f)))
  (run-until-evaluation-message!)
  (source-debug-controller-remove-breakpoint!
    source-debugger
    (source-breakpoint-id call-breakpoint))

  (define infinite-request
    (interaction-session-begin!
      session
      "(let loop () (loop))"))
  (execute!
    (list
      (make-command-effect 'scheme.evaluate infinite-request)))

  (let ([messages
          (evaluation-runtime-handle-event
            adapter
            (next-evaluation-event))])
    (unless
      (and
        (null? messages)
        (evaluation-runtime-busy?
          adapter
          (interaction-session-id session))
        (eq? (interaction-session-state session) 'evaluating))
      (error 'evaluation-runtime-tests
             "infinite evaluation did not yield to the command loop")))

  (execute!
    (list
      (make-command-effect
        'scheme.interrupt-evaluation
        (interaction-session-id session))))
  (apply-messages!
    (evaluation-runtime-handle-event
      adapter
      (next-evaluation-event)))

  (unless
    (and
      (eq? (interaction-session-state session) 'suspended)
      (eq?
        (evaluation-result-status
          (interaction-session-last-result session))
        'suspended)
      (interaction-session-debugger session)
      (equal?
        (map
          debugger-action-id
          (debugger-session-actions
            (interaction-session-debugger session)))
        '(continue retry edit-and-retry abort))
      (eq?
        (debugger-action-id
          (debugger-actions-default
            (debugger-session-actions
              (interaction-session-debugger session))))
        'continue)
      (evaluation-suspension-condition?
        (evaluation-result-condition
          (interaction-session-last-result session)))
      (evaluation-runtime-busy?
        adapter
        (interaction-session-id session)))
    (error 'evaluation-runtime-tests
           "interrupt did not capture a resumable evaluation"))

  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-continue #f)))
  (unless
    (and
      (eq? (interaction-session-state session) 'evaluating)
      (not (interaction-session-debugger session)))
    (error 'evaluation-runtime-tests
           "debugger continue did not resume the evaluation"))

  (unless
    (null?
      (evaluation-runtime-handle-event
        adapter
        (next-evaluation-event)))
    (error 'evaluation-runtime-tests
           "resumed infinite evaluation unexpectedly completed"))

  (execute!
    (list
      (make-command-effect
        'scheme.interrupt-evaluation
        (interaction-session-id session))))
  (apply-messages!
    (evaluation-runtime-handle-event
      adapter
      (next-evaluation-event)))
  (execute!
    (editor-update!
      editor
      (make-command-message 'scheme.debug-discard #f)))

  (unless
    (and
      (eq? (interaction-session-state session) 'ready)
      (not (interaction-session-debugger session))
      (not
        (evaluation-runtime-busy?
          adapter
          (interaction-session-id session))))
    (error 'evaluation-runtime-tests
           "aborting a suspended evaluation did not release its engine"))

  (define helper-request
    (interaction-session-begin!
      session
      "(define (soda-test-half value) (/ value 2))"))
  (execute!
    (list
      (make-command-effect 'scheme.evaluate helper-request)))
  (let loop ()
    (let ([messages
            (evaluation-runtime-handle-event
              adapter
              (next-evaluation-event))])
      (if (null? messages)
          (loop)
          (apply-messages! messages))))

  (define failed-request
    (interaction-session-begin!
      session
      "(let ([bad '()]) (soda-test-half (+ 12 bad)))"))
  (execute!
    (list
      (make-command-effect 'scheme.evaluate failed-request)))
  (let loop ()
    (let ([messages
            (evaluation-runtime-handle-event
              adapter
              (next-evaluation-event))])
      (if (null? messages)
          (loop)
          (apply-messages! messages))))

  (unless
    (and
      (eq? (interaction-session-state session) 'failed)
      (evaluation-result-continuation
        (interaction-session-last-result session))
      (evaluation-runtime-busy?
        adapter
        (interaction-session-id session)))
    (error 'evaluation-runtime-tests
           "failed evaluation did not retain its condition continuation"))

  (define failed-debugger
    (interaction-session-debugger session))
  (define use-value-context
    (make-debugger-action-context
      editor
      session
      failed-debugger
      (debugger-session-selected-frame failed-debugger)
      (debugger-session-condition failed-debugger)
      (evaluation-result-continuation
        (interaction-session-last-result session))
      (debugger-session-action
        failed-debugger
        'use-value)
      "16"))
  (execute!
    (editor-update!
      editor
      (make-command-message
        'scheme.debug-use-value
        use-value-context)))
  (let loop ()
    (let ([messages
            (evaluation-runtime-handle-event
              adapter
              (next-evaluation-event))])
      (if (null? messages)
          (loop)
          (apply-messages! messages))))

  (unless
    (and
      (eq? (interaction-session-state session) 'ready)
      (equal?
        (evaluation-result-values
          (interaction-session-last-result session))
        '(8))
      (not
        (evaluation-runtime-busy?
          adapter
          (interaction-session-id session))))
    (error 'evaluation-runtime-tests
           "replacement value did not resume the failed continuation"
           (interaction-session-state session)
           (evaluation-result-values
             (interaction-session-last-result session))))

  (define transformed-request
    (interaction-session-begin!
      session
      "(let ([bad '()]) (soda-test-half (+ 12 bad)))"))
  (execute!
    (list
      (make-command-effect
        'scheme.evaluate
        transformed-request)))
  (let loop ()
    (let ([messages
            (evaluation-runtime-handle-event
              adapter
              (next-evaluation-event))])
      (if (null? messages)
          (loop)
          (apply-messages! messages))))
  (execute!
    (editor-update!
      editor
      (make-command-message
        'scheme.debug-open
        #f)))
  (execute!
    (editor-update!
      editor
      (make-command-message
        'scheme.debug-inspect-continuation
        #f)))
  (execute!
    (editor-update!
      editor
      (make-command-message
        'scheme.debug-apply
        "(lambda (continuation) (continuation 20))")))
  (let loop ()
    (let ([messages
            (evaluation-runtime-handle-event
              adapter
              (next-evaluation-event))])
      (if (null? messages)
          (loop)
          (apply-messages! messages))))

  (unless
    (and
      (eq? (interaction-session-state session) 'ready)
      (equal?
        (evaluation-result-values
          (interaction-session-last-result session))
        '(10))
      (not
        (evaluation-runtime-busy?
          adapter
          (interaction-session-id session))))
    (error 'evaluation-runtime-tests
           "continuation transformer did not resume the failed computation"))

  (editor-close! editor)
  (runtime-close! runtime)
