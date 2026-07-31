#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor command)
        (soda editor core)
        (soda editor effect)
        (soda editor evaluation-runtime)
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
      (eq? (interaction-session-state session) 'ready)
      (eq?
        (evaluation-result-status
          (interaction-session-last-result session))
        'interrupted)
      (not
        (evaluation-runtime-busy?
          adapter
          (interaction-session-id session))))
    (error 'evaluation-runtime-tests
           "interrupt did not complete the cooperative evaluation"))

  (editor-close! editor)
  (runtime-close! runtime)
