#!r6rs
(import (rnrs)
        (soda editor command)
        (soda editor effect)
        (soda editor event)
        (soda editor managed-process)
        (soda runtime))

  (define runtime (make-runtime))
  (define executor (make-effect-executor))
  (define adapter
    (install-managed-process-runtime! executor runtime))
  (define owner (list 'language-server-owner))
  (define process
    (make-managed-process
      "language-server"
      '("/bin/cat")
      ""
      owner
      'lsp.process-output
      'lsp.process-exit))

  (define (execute! effect)
    (let ([result
            (execute-effects! executor (list effect))])
      (unless (effect-result-continue? result)
        (error 'managed-process-tests
               "effect executor stopped unexpectedly"))))

  (define (next-message)
    (let loop ()
      (let find ([events (runtime-poll! runtime)])
        (cond
          [(null? events) (loop)]
          [else
           (let ([message
                   (managed-process-runtime-handle-event
                     adapter
                     (car events))])
             (if message
                 message
                 (find (cdr events))))]))))

  (execute!
    (make-command-effect
      'managed-process.start
      process))
  (define first-source (managed-process-source process))

  (unless
    (and
      (eq? (managed-process-state process) 'running)
      (= (managed-process-generation process) 1)
      (managed-process-input-open? process)
      first-source)
    (error 'managed-process-tests
           "managed process did not enter its running state"))

  (define first-payload
    (string->utf8
      "Content-Length: 2\r\n\r\n{}"))
  (execute!
    (make-command-effect
      'managed-process.write
      (make-managed-process-write-request
        process
        first-payload)))
  (let* ([message (next-message)]
         [event (internal-command-message-argument message)])
    (unless
      (and
        (eq? (internal-command-message-name message)
             'lsp.process-output)
        (eq? (managed-process-event-process event) process)
        (eq? (managed-process-owner process) owner)
        (= (managed-process-event-generation event) 1)
        (= (managed-process-event-flags event) process-stdout)
        (equal? (managed-process-event-data event) first-payload))
      (error 'managed-process-tests
             "managed process output was not routed to its owner command")))

  (execute!
    (make-command-effect
      'managed-process.restart
      process))
  (let* ([message (next-message)]
         [event (internal-command-message-argument message)])
    (unless
      (and
        (eq? (internal-command-message-name message)
             'lsp.process-exit)
        (= (managed-process-event-generation event) 1)
        (managed-process-event-restarted? event)
        (eq? (managed-process-state process) 'running)
        (= (managed-process-generation process) 2)
        (managed-process-input-open? process)
        (not (= first-source
                (managed-process-source process))))
      (error 'managed-process-tests
             "managed process did not restart as one logical process")))

  (define second-payload (string->utf8 "after restart\n"))
  (execute!
    (make-command-effect
      'managed-process.write
      (make-managed-process-write-request
        process
        second-payload)))
  (let* ([message (next-message)]
         [event (internal-command-message-argument message)])
    (unless
      (and
        (eq? (internal-command-message-name message)
             'lsp.process-output)
        (= (managed-process-event-generation event) 2)
        (equal? (managed-process-event-data event) second-payload))
      (error 'managed-process-tests
             "restarted process did not route output")))

  (execute!
    (make-command-effect
      'managed-process.close-input
      process))
  (let* ([message (next-message)]
         [event (internal-command-message-argument message)])
    (unless
      (and
        (eq? (internal-command-message-name message)
             'lsp.process-exit)
        (= (managed-process-event-generation event) 2)
        (not (managed-process-event-restarted? event))
        (eq? (managed-process-state process) 'exited)
        (not (managed-process-source process))
        (not (managed-process-input-open? process))
        (zero? (managed-process-event-status event)))
      (error 'managed-process-tests
             "managed process exit lifecycle differs")))

  (runtime-close! runtime)
