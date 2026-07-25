(library (soda editor interaction)
  (export make-interaction-session
          interaction-session?
          interaction-session-id
          interaction-session-kind
          interaction-session-name
          interaction-session-buffer-id
          interaction-session-evaluator
          interaction-session-prompt
          interaction-session-state
          interaction-session-generation
          interaction-session-input-start
          interaction-session-history
          interaction-session-last-result
          interaction-session-begin!
          interaction-session-complete!
          interaction-session-dismiss-failure!
          interaction-session-debug-actions
          interaction-session-close!
          interaction-session-closed?
          make-evaluation-origin
          evaluation-origin?
          evaluation-origin-buffer-id
          evaluation-origin-resource
          evaluation-origin-revision
          evaluation-origin-start
          evaluation-origin-end
          make-evaluation-request
          evaluation-request?
          evaluation-request-session-id
          evaluation-request-generation
          evaluation-request-source
          evaluation-request-origin
          make-evaluation-result
          evaluation-result?
          evaluation-result-request
          evaluation-result-status
          evaluation-result-values
          evaluation-result-stdout
          evaluation-result-stderr
          evaluation-result-condition
          evaluation-result-messages)
  (import (rnrs))

  (define-record-type
    (interaction-session %make-interaction-session interaction-session?)
    (fields
      (immutable id interaction-session-id)
      (immutable kind interaction-session-kind)
      (immutable name interaction-session-name)
      (immutable buffer-id interaction-session-buffer-id)
      (immutable evaluator interaction-session-evaluator)
      (immutable prompt interaction-session-prompt)
      (mutable state
               interaction-session-state
               interaction-session-state-set!)
      (mutable generation
               interaction-session-generation
               interaction-session-generation-set!)
      (mutable input-start
               interaction-session-input-start
               interaction-session-input-start-set!)
      (mutable history
               interaction-session-history
               interaction-session-history-set!)
      (mutable last-result
               interaction-session-last-result
               interaction-session-last-result-set!)
      (mutable closed?
               interaction-session-closed?
               interaction-session-closed?-set!)))

  (define-record-type
    (evaluation-origin %make-evaluation-origin evaluation-origin?)
    (fields buffer-id resource revision start end))

  (define-record-type evaluation-request
    (fields session-id generation source origin))

  (define-record-type
    (evaluation-result %make-evaluation-result evaluation-result?)
    (fields request status values stdout stderr condition messages))

  (define (exact-non-negative-integer? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (make-evaluation-origin buffer-id resource revision start end)
    (unless (exact-non-negative-integer? buffer-id)
      (assertion-violation
        'make-evaluation-origin
        "buffer id must be a non-negative exact integer"
        buffer-id))
    (unless (exact-non-negative-integer? revision)
      (assertion-violation
        'make-evaluation-origin
        "revision must be a non-negative exact integer"
        revision))
    (unless
      (or
        (and (not start) (not end))
        (and (exact-non-negative-integer? start)
             (exact-non-negative-integer? end)
             (<= start end)))
      (assertion-violation
        'make-evaluation-origin
        "source range must be absent or an ordered byte range"
        start
        end))
    (%make-evaluation-origin buffer-id resource revision start end))

  (define (make-interaction-session
            id
            kind
            name
            buffer-id
            evaluator
            prompt
            input-start)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'make-interaction-session
        "id must be a non-negative exact integer"
        id))
    (unless (symbol? kind)
      (assertion-violation
        'make-interaction-session
        "kind must be a symbol"
        kind))
    (unless (string? name)
      (assertion-violation
        'make-interaction-session
        "name must be a string"
        name))
    (unless (exact-non-negative-integer? buffer-id)
      (assertion-violation
        'make-interaction-session
        "buffer id must be a non-negative exact integer"
        buffer-id))
    (unless (string? prompt)
      (assertion-violation
        'make-interaction-session
        "prompt must be a string"
        prompt))
    (unless (exact-non-negative-integer? input-start)
      (assertion-violation
        'make-interaction-session
        "input start must be a non-negative exact integer"
        input-start))
    (%make-interaction-session
      id
      kind
      name
      buffer-id
      evaluator
      prompt
      'ready
      0
      input-start
      '()
      #f
      #f))

  (define (require-open-session who session)
    (unless (interaction-session? session)
      (assertion-violation who "expected an interaction session" session))
    (when (interaction-session-closed? session)
      (assertion-violation who "interaction session is closed" session)))

  (define interaction-session-begin!
    (case-lambda
      [(session source)
       (interaction-session-begin! session source #f)]
      [(session source origin)
       (require-open-session 'interaction-session-begin! session)
       (unless (string? source)
         (assertion-violation
           'interaction-session-begin!
           "source must be a string"
           source))
       (unless (or (not origin) (evaluation-origin? origin))
         (assertion-violation
           'interaction-session-begin!
           "origin must be an evaluation origin or #f"
           origin))
       (when (eq? (interaction-session-state session) 'evaluating)
         (assertion-violation
           'interaction-session-begin!
           "interaction session is already evaluating"
           (interaction-session-id session)))
       (let ([generation (+ (interaction-session-generation session) 1)])
         (interaction-session-generation-set! session generation)
         (interaction-session-state-set! session 'evaluating)
         (interaction-session-history-set!
           session
           (append (interaction-session-history session) (list source)))
         (make-evaluation-request
           (interaction-session-id session)
           generation
           source
           origin))]))

  (define (interaction-session-complete!
            session
            result
            next-input-start)
    (require-open-session 'interaction-session-complete! session)
    (unless (evaluation-result? result)
      (assertion-violation
        'interaction-session-complete!
        "expected an evaluation result"
        result))
    (let ([request (evaluation-result-request result)])
      (unless
        (and (= (evaluation-request-session-id request)
                (interaction-session-id session))
             (= (evaluation-request-generation request)
                (interaction-session-generation session))
             (eq? (interaction-session-state session) 'evaluating))
        (assertion-violation
          'interaction-session-complete!
          "evaluation result is stale"
          request)))
    (unless (exact-non-negative-integer? next-input-start)
      (assertion-violation
        'interaction-session-complete!
        "input start must be a non-negative exact integer"
        next-input-start))
    (interaction-session-input-start-set! session next-input-start)
    (interaction-session-last-result-set! session result)
    (interaction-session-state-set!
      session
      (if (eq? (evaluation-result-status result) 'condition)
          'failed
          'ready))
    result)

  (define (interaction-session-dismiss-failure! session)
    (require-open-session 'interaction-session-dismiss-failure! session)
    (when (eq? (interaction-session-state session) 'failed)
      (interaction-session-state-set! session 'ready))
    session)

  (define (interaction-session-debug-actions session)
    (require-open-session 'interaction-session-debug-actions session)
    (if (eq? (interaction-session-state session) 'failed)
        '(retry dismiss)
        '()))

  (define (interaction-session-close! session)
    (when (and (interaction-session? session)
               (not (interaction-session-closed? session)))
      (interaction-session-state-set! session 'closed)
      (interaction-session-closed?-set! session #t)))

  (define (make-evaluation-result
            request
            status
            values
            stdout
            stderr
            condition
            messages)
    (unless (evaluation-request? request)
      (assertion-violation
        'make-evaluation-result
        "expected an evaluation request"
        request))
    (unless (memq status '(value condition))
      (assertion-violation
        'make-evaluation-result
        "status must be value or condition"
        status))
    (unless (list? values)
      (assertion-violation
        'make-evaluation-result
        "values must be a list"
        values))
    (unless (and (string? stdout) (string? stderr))
      (assertion-violation
        'make-evaluation-result
        "stdout and stderr must be strings"
        stdout
        stderr))
    (unless
      (if (eq? status 'condition)
          (condition? condition)
          (not condition))
      (assertion-violation
        'make-evaluation-result
        "condition must match the result status"
        condition))
    (unless (list? messages)
      (assertion-violation
        'make-evaluation-result
        "messages must be a list"
        messages))
    (%make-evaluation-result
      request
      status
      values
      stdout
      stderr
      condition
      messages)))
