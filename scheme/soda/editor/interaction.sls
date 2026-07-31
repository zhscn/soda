(library (soda editor interaction)
  (export make-interaction-session
          interaction-session?
          interaction-session-id
          interaction-session-kind
          interaction-session-name
          interaction-session-set-evaluator!
          interaction-session-transcript
          interaction-session-buffer-id
          interaction-session-evaluator
          interaction-session-prompt
          interaction-session-state
          interaction-session-generation
          interaction-session-output-mark
          interaction-session-input-start
          interaction-session-history
          interaction-session-history-index
          interaction-session-history-draft
          interaction-session-history-previous!
          interaction-session-history-next!
          interaction-session-history-search-previous!
          interaction-session-history-search-next!
          interaction-session-reset-history-navigation!
          interaction-session-record-input!
          interaction-session-prompt-start
          interaction-session-prompt-end
          interaction-session-last-input-start
          interaction-session-last-input-end
          interaction-session-last-output-start
          interaction-session-last-output-end
          interaction-session-last-result
          interaction-session-debugger
          interaction-session-set-debugger!
          interaction-session-begin!
          interaction-session-complete!
          interaction-session-suspend!
          interaction-session-resume!
          interaction-session-abort-suspension!
          interaction-session-dismiss-failure!
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
          make-evaluation-resume-request
          evaluation-resume-request?
          evaluation-resume-request-session-id
          evaluation-resume-request-generation
          evaluation-resume-request-kind
          evaluation-resume-request-values
          make-evaluation-result
          evaluation-result?
          evaluation-result-request
          evaluation-result-status
          evaluation-result-values
          evaluation-result-stdout
          evaluation-result-stderr
          evaluation-result-condition
          evaluation-result-messages
          make-evaluation-suspension-condition
          evaluation-suspension-condition?
          evaluation-suspension-session-id
          evaluation-suspension-generation
          evaluation-suspension-engine
          interaction-transcript?
          interaction-transcript-closed?)
  (import (rnrs)
          (soda editor interaction-history)
          (soda editor interaction-transcript))

  (define-record-type
    (interaction-session %make-interaction-session interaction-session?)
    (fields
      (immutable id interaction-session-id)
      (immutable kind interaction-session-kind)
      (immutable name interaction-session-name)
      (immutable transcript interaction-session-transcript)
      (mutable evaluator
               interaction-session-evaluator
               interaction-session-evaluator-set!)
      (mutable state
               interaction-session-state
               interaction-session-state-set!)
      (mutable generation
               interaction-session-generation
               interaction-session-generation-set!)
      (immutable history interaction-session-history-state)
      (mutable last-result
               interaction-session-last-result
               interaction-session-last-result-set!)
      (mutable debugger
               interaction-session-debugger
               interaction-session-debugger-set!)
      (mutable closed?
               interaction-session-closed?
               interaction-session-closed?-set!)))

  (define-record-type
    (evaluation-origin %make-evaluation-origin evaluation-origin?)
    (fields buffer-id resource revision start end))

  (define-record-type evaluation-request
    (fields session-id generation source origin))

  (define-record-type
    (evaluation-resume-request
      %make-evaluation-resume-request
      evaluation-resume-request?)
    (fields session-id generation kind values))

  (define-record-type
    (evaluation-result %make-evaluation-result evaluation-result?)
    (fields request status values stdout stderr condition messages))

  (define-condition-type
    &evaluation-suspension
    &condition
    make-evaluation-suspension-condition
    evaluation-suspension-condition?
    (session-id evaluation-suspension-session-id)
    (generation evaluation-suspension-generation)
    (engine evaluation-suspension-engine))

  (define (interaction-session-buffer-id session)
    (interaction-transcript-buffer-id
      (interaction-session-transcript session)))

  (define (interaction-session-prompt session)
    (interaction-transcript-prompt
      (interaction-session-transcript session)))

  (define (interaction-session-input-start session)
    (interaction-transcript-input-start
      (interaction-session-transcript session)))

  (define (interaction-session-output-mark session)
    (interaction-transcript-output-mark
      (interaction-session-transcript session)))

  (define (interaction-session-prompt-start session)
    (interaction-transcript-prompt-start
      (interaction-session-transcript session)))

  (define (interaction-session-prompt-end session)
    (interaction-transcript-prompt-end
      (interaction-session-transcript session)))

  (define (interaction-session-last-input-start session)
    (interaction-transcript-last-input-start
      (interaction-session-transcript session)))

  (define (interaction-session-last-input-end session)
    (interaction-transcript-last-input-end
      (interaction-session-transcript session)))

  (define (interaction-session-last-output-start session)
    (interaction-transcript-last-output-start
      (interaction-session-transcript session)))

  (define (interaction-session-last-output-end session)
    (interaction-transcript-last-output-end
      (interaction-session-transcript session)))

  (define (interaction-session-history session)
    (interaction-history-entries
      (interaction-session-history-state session)))

  (define (interaction-session-history-index session)
    (interaction-history-index
      (interaction-session-history-state session)))

  (define (interaction-session-history-draft session)
    (interaction-history-draft
      (interaction-session-history-state session)))

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
            buffer
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
      (make-interaction-transcript buffer prompt input-start)
      evaluator
      'ready
      0
      (make-interaction-history 200)
      #f
      #f
      #f))

  (define (make-evaluation-resume-request
            session-id
            generation
            kind
            values)
    (unless
      (and
        (exact-non-negative-integer? session-id)
        (exact-non-negative-integer? generation))
      (assertion-violation
        'make-evaluation-resume-request
        "session id and generation must be non-negative exact integers"
        session-id
        generation))
    (unless (memq kind '(continue use-values apply-continuation))
      (assertion-violation
        'make-evaluation-resume-request
        "resume kind must be continue, use-values, or apply-continuation"
        kind))
    (unless (list? values)
      (assertion-violation
        'make-evaluation-resume-request
        "resume values must be a list"
        values))
    (%make-evaluation-resume-request
      session-id
      generation
      kind
      values))

  (define (require-open-session who session)
    (unless (interaction-session? session)
      (assertion-violation who "expected an interaction session" session))
    (when (interaction-session-closed? session)
      (assertion-violation who "interaction session is closed" session)))

  (define (interaction-session-set-evaluator! session evaluator)
    (require-open-session 'interaction-session-set-evaluator! session)
    (interaction-session-evaluator-set! session evaluator)
    evaluator)

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
         (interaction-history-record!
           (interaction-session-history-state session)
           source)
         (make-evaluation-request
           (interaction-session-id session)
           generation
           source
           origin))]))

  (define (interaction-session-reset-history-navigation! session)
    (require-open-session
      'interaction-session-reset-history-navigation!
      session)
    (interaction-history-reset!
      (interaction-session-history-state session))
    session)

  (define (interaction-session-record-input! session input)
    (require-open-session
      'interaction-session-record-input!
      session)
    (unless (string? input)
      (assertion-violation
        'interaction-session-record-input!
        "input must be a string"
        input))
    (interaction-history-record!
      (interaction-session-history-state session)
      input)
    session)

  (define (interaction-session-history-previous!
            session
            current-input)
    (require-open-session
      'interaction-session-history-previous!
      session)
    (unless (string? current-input)
      (assertion-violation
        'interaction-session-history-previous!
        "current input must be a string"
        current-input))
    (interaction-history-previous!
      (interaction-session-history-state session)
      current-input))

  (define (interaction-session-history-next! session)
    (require-open-session
      'interaction-session-history-next!
      session)
    (interaction-history-next!
      (interaction-session-history-state session)))

  (define (interaction-session-history-search-previous!
            session
            current-input
            kind)
    (require-open-session
      'interaction-session-history-search-previous!
      session)
    (interaction-history-search-previous!
      (interaction-session-history-state session)
      current-input
      kind))

  (define (interaction-session-history-search-next!
            session
            current-input
            kind)
    (require-open-session
      'interaction-session-history-search-next!
      session)
    (interaction-history-search-next!
      (interaction-session-history-state session)
      current-input
      kind))

  (define (interaction-session-complete! session result)
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
    (interaction-session-last-result-set! session result)
    (interaction-session-state-set!
      session
      (if (eq? (evaluation-result-status result) 'condition)
          'failed
          'ready))
    result)

  (define (require-current-result who session result expected-state)
    (unless (evaluation-result? result)
      (assertion-violation
        who
        "expected an evaluation result"
        result))
    (let ([request (evaluation-result-request result)])
      (unless
        (and
          (= (evaluation-request-session-id request)
             (interaction-session-id session))
          (= (evaluation-request-generation request)
             (interaction-session-generation session))
          (eq? (interaction-session-state session) expected-state))
        (assertion-violation
          who
          "evaluation result is stale"
          request))))

  (define (interaction-session-suspend! session result)
    (require-open-session 'interaction-session-suspend! session)
    (require-current-result
      'interaction-session-suspend!
      session
      result
      'evaluating)
    (unless (eq? (evaluation-result-status result) 'suspended)
      (assertion-violation
        'interaction-session-suspend!
        "expected a suspended evaluation result"
        result))
    (interaction-session-last-result-set! session result)
    (interaction-session-state-set! session 'suspended)
    result)

  (define (interaction-session-resume! session)
    (require-open-session 'interaction-session-resume! session)
    (unless
      (memq
        (interaction-session-state session)
        '(failed suspended))
      (assertion-violation
        'interaction-session-resume!
        "interaction session is not failed or suspended"
        (interaction-session-id session)))
    (interaction-session-state-set! session 'evaluating)
    session)

  (define (interaction-session-abort-suspension! session)
    (require-open-session
      'interaction-session-abort-suspension!
      session)
    (unless (eq? (interaction-session-state session) 'suspended)
      (assertion-violation
        'interaction-session-abort-suspension!
        "interaction session is not suspended"
        (interaction-session-id session)))
    (interaction-session-state-set! session 'ready)
    session)

  (define (interaction-session-set-debugger! session debugger)
    (require-open-session
      'interaction-session-set-debugger!
      session)
    (interaction-session-debugger-set! session debugger)
    debugger)

  (define (interaction-session-dismiss-failure! session)
    (require-open-session 'interaction-session-dismiss-failure! session)
    (when (eq? (interaction-session-state session) 'failed)
      (interaction-session-state-set! session 'ready))
    session)

  (define (interaction-session-close! session)
    (when (and (interaction-session? session)
               (not (interaction-session-closed? session)))
      (interaction-transcript-close!
        (interaction-session-transcript session))
      (interaction-session-last-result-set! session #f)
      (interaction-session-debugger-set! session #f)
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
    (unless (memq status '(value condition suspended))
      (assertion-violation
        'make-evaluation-result
        "status must be value, condition, or suspended"
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
      (if (memq status '(condition suspended))
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
