(library (soda editor prompt)
  (export make-prompt-request
          make-completing-prompt-request
          prompt-request?
          prompt-request-prompt
          prompt-request-initial
          prompt-request-history-id
          prompt-request-default
          prompt-request-accept-policy
          prompt-request-validator
          prompt-request-accept-command
          prompt-request-abort-command
          prompt-request-completion-source
          prompt-request-data
          prompt-request-change-command
          minibuffer-completion-indicator-columns
          prompt-input-viewport-columns
          prompt-request-completion-selection-policy
          make-prompt-session
          prompt-session?
          prompt-session-id
          prompt-session-request
          prompt-session-buffer-id
          prompt-session-view-id
          prompt-session-origin-view-id
          prompt-session-state
          prompt-session-state-set!
          prompt-session-history-index
          prompt-session-history-index-set!
          prompt-session-history-draft
          prompt-session-history-draft-set!
          prompt-session-completion
          make-prompt-history
          prompt-history?
          prompt-history-id
          prompt-history-entries
          prompt-history-entries-set!
          make-prompt-result
          prompt-result?
          prompt-result-session-id
          prompt-result-status
          prompt-result-value
          prompt-result-origin-view-id
          prompt-result-candidate
          prompt-result-data
          make-prompt-reply
          prompt-reply?
          prompt-reply-command
          prompt-reply-result)
  (import (rnrs)
          (soda editor completion)
          (soda editor display))

  (define (decimal-digit-count value)
    (let loop ([remaining value] [count 1])
      (if (< remaining 10)
          count
          (loop (div remaining 10) (+ count 1)))))

  (define (minibuffer-completion-indicator-columns item-count)
    (unless
      (and
        (integer? item-count)
        (exact? item-count)
        (not (negative? item-count)))
      (assertion-violation
        'minibuffer-completion-indicator-columns
        "item count must be a non-negative exact integer"
        item-count))
    (max
      7
      (+ (* 2 (decimal-digit-count item-count)) 1)))

  (define-record-type
    (prompt-request %make-prompt-request prompt-request?)
    (fields prompt
            initial
            history-id
            default
            accept-policy
            validator
            accept-command
            abort-command
            completion-source
            data
            change-command))

  (define-record-type prompt-session
    (fields id
            request
            buffer-id
            view-id
            origin-view-id
            (mutable state)
            (mutable history-index)
            (mutable history-draft)
            completion))

  (define-record-type prompt-history
    (fields id (mutable entries)))

  (define-record-type
    (prompt-result %make-prompt-result prompt-result?)
    (fields session-id status value origin-view-id candidate data))

  (define-record-type prompt-reply
    (fields command result))

  (define prompt-input-viewport-columns
    (case-lambda
      [(request total-columns)
       (prompt-input-viewport-columns request total-columns 0)]
      [(request total-columns item-count)
       (unless (prompt-request? request)
         (assertion-violation
           'prompt-input-viewport-columns
           "expected a prompt request"
           request))
       (unless
         (and
           (integer? total-columns)
           (exact? total-columns)
           (positive? total-columns))
         (assertion-violation
           'prompt-input-viewport-columns
           "total columns must be a positive exact integer"
           total-columns))
       (max
         1
         (-
           total-columns
           (string-cell-width (prompt-request-prompt request) 8)
           (if (prompt-request-completion-source request)
               (minibuffer-completion-indicator-columns item-count)
               0)))]))

  (define (prompt-request-completion-selection-policy request)
    (unless (prompt-request? request)
      (assertion-violation
        'prompt-request-completion-selection-policy
        "expected a prompt request"
        request))
    (let ([source (prompt-request-completion-source request)])
      (and
        source
        (let ([input?
                (eq?
                  (prompt-request-accept-policy request)
                  'free)])
          (make-completion-selection-policy
            (if input?
                'input-and-candidates
                'candidates)
            (cond
              [(choice-source-preselect? source) 'first]
              [input? 'input]
              [else 'none])
            #f)))))

  (define make-prompt-request
    (case-lambda
      [(prompt accept-command)
       (make-prompt-request
         prompt
         ""
         #f
         #f
         'free
         #f
         accept-command
         #f
         #f
         #f)]
      [(prompt
         initial
         history-id
         default
         accept-policy
         validator
         accept-command
         abort-command)
       (make-prompt-request
         prompt
         initial
         history-id
         default
         accept-policy
         validator
         accept-command
         abort-command
         #f)]
      [(prompt
         initial
         history-id
         default
         accept-policy
         validator
         accept-command
         abort-command
         data)
       (make-prompt-request
         prompt
         initial
         history-id
         default
         accept-policy
         validator
         accept-command
         abort-command
         data
         #f)]
      [(prompt
         initial
         history-id
         default
         accept-policy
         validator
         accept-command
         abort-command
         data
         change-command)
       (unless (string? prompt)
         (assertion-violation
           'make-prompt-request
           "prompt must be a string"
           prompt))
       (unless (string? initial)
         (assertion-violation
           'make-prompt-request
           "initial input must be a string"
           initial))
       (unless (or (not history-id) (symbol? history-id))
         (assertion-violation
           'make-prompt-request
           "history id must be a symbol or #f"
           history-id))
       (unless (or (not default) (string? default))
         (assertion-violation
           'make-prompt-request
           "default must be a string or #f"
           default))
       (unless (memq accept-policy '(free must-match))
         (assertion-violation
           'make-prompt-request
           "accept policy must be free or must-match"
           accept-policy))
       (unless (or (not validator) (procedure? validator))
         (assertion-violation
           'make-prompt-request
           "validator must be a procedure or #f"
           validator))
       (when (and (eq? accept-policy 'must-match) (not validator))
         (assertion-violation
           'make-prompt-request
           "must-match input requires a validator"))
       (unless (symbol? accept-command)
         (assertion-violation
           'make-prompt-request
           "accept command must be a symbol"
           accept-command))
       (unless (or (not abort-command) (symbol? abort-command))
         (assertion-violation
           'make-prompt-request
           "abort command must be a symbol or #f"
           abort-command))
       (unless (or (not change-command) (symbol? change-command))
         (assertion-violation
           'make-prompt-request
           "change command must be a symbol or #f"
           change-command))
       (%make-prompt-request
         prompt
         initial
         history-id
         default
         accept-policy
         validator
         accept-command
         abort-command
         #f
         data
         change-command)]))

  (define make-completing-prompt-request
    (case-lambda
      [(prompt initial history-id default accept-policy source
               accept-command abort-command)
       (make-completing-prompt-request
         prompt initial history-id default accept-policy source
         accept-command abort-command #f)]
      [(prompt initial history-id default accept-policy source
               accept-command abort-command data)
       (make-completing-prompt-request
         prompt initial history-id default accept-policy source
         accept-command abort-command data #f)]
      [(prompt initial history-id default accept-policy source
               accept-command abort-command data change-command)
       (unless (choice-source? source)
         (assertion-violation
           'make-completing-prompt-request
           "expected a choice source"
           source))
       (let ([request
               (make-prompt-request
                 prompt
                 initial
                 history-id
                 default
                 accept-policy
                 (and
                   (eq? accept-policy 'must-match)
                   (lambda (value)
                     (choice-source-valid? source value)))
                 accept-command
                 abort-command
                 data
                 change-command)])
         (%make-prompt-request
           (prompt-request-prompt request)
           (prompt-request-initial request)
           (prompt-request-history-id request)
           (prompt-request-default request)
           (prompt-request-accept-policy request)
           (prompt-request-validator request)
           (prompt-request-accept-command request)
           (prompt-request-abort-command request)
           source
           (prompt-request-data request)
           (prompt-request-change-command request)))]))

  (define make-prompt-result
    (case-lambda
      [(session-id status value origin-view-id candidate)
       (%make-prompt-result
         session-id status value origin-view-id candidate #f)]
      [(session-id status value origin-view-id candidate data)
       (%make-prompt-result
         session-id status value origin-view-id candidate data)])))
