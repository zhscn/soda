#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor core)
        (soda editor effect)
        (soda editor evaluation-runtime)
        (only (soda editor evaluator)
              evaluation-result-continuation)
        (soda editor interaction)
        (soda editor repl)
        (soda runtime))

  (define document (make-document "" 901))
  (define buffer
    (make-buffer 900 document "*evaluation-runtime-test*" 'scheme-mode))
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

  (interaction-session-resume! session)
  (execute!
    (list
      (make-command-effect
        'scheme.resume-evaluation
        (make-evaluation-resume-request
          (interaction-session-id session)
          (interaction-session-generation session)
          'use-values
          '(16)))))
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
