(library (soda editor evaluator)
  (export make-chez-evaluator
          chez-evaluator?
          chez-evaluator-symbols
          chez-evaluator-ref
          chez-evaluator-evaluate
          chez-evaluator-evaluate-file!
          evaluation-result-continuation
          evaluation-result->transcript)
  (import (chezscheme)
          (soda editor event)
          (soda editor interaction))

  (define-record-type (chez-evaluator %make-chez-evaluator chez-evaluator?)
    (fields environment))

  (define (make-chez-evaluator)
    (%make-chez-evaluator
      (copy-environment (scheme-environment))))

  (define (chez-evaluator-symbols evaluator)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'chez-evaluator-symbols
        "expected a Chez evaluator"
        evaluator))
    (environment-symbols
      (chez-evaluator-environment evaluator)))

  (define chez-evaluator-ref
    (case-lambda
      [(evaluator name)
       (chez-evaluator-ref evaluator name #f)]
      [(evaluator name fallback)
       (unless (chez-evaluator? evaluator)
         (assertion-violation
           'chez-evaluator-ref
           "expected a Chez evaluator"
           evaluator))
       (unless (symbol? name)
         (assertion-violation
           'chez-evaluator-ref
           "name must be a symbol"
           name))
       (let ([environment (chez-evaluator-environment evaluator)])
         (if (top-level-bound? name environment)
             (top-level-value name environment)
             fallback))]))

  (define (evaluate-port environment port)
    (let loop ([last-values '()] [evaluated? #f])
      (let ([form (read port)])
        (if (eof-object? form)
            (if evaluated? last-values '())
            (loop
              (call-with-values
                (lambda () (eval form environment))
                list)
              #t)))))

  (define (evaluate-source environment source)
    (evaluate-port environment (open-string-input-port source)))

  (define (chez-evaluator-evaluate-file! evaluator path editor)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'chez-evaluator-evaluate-file!
        "expected a Chez evaluator"
        evaluator))
    (unless (and (string? path) (positive? (string-length path)))
      (assertion-violation
        'chez-evaluator-evaluate-file!
        "path must be a non-empty string"
        path))
    (let ([environment (chez-evaluator-environment evaluator)])
      (set-top-level-value! '*editor* editor environment)
      (set-top-level-value! '*interaction-session* #f environment)
      (call-with-input-file
        path
        (lambda (port)
          (evaluate-port environment port)))))

  (define (chez-evaluator-evaluate
            evaluator
            request
            editor
            session)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'chez-evaluator-evaluate
        "expected a Chez evaluator"
        evaluator))
    (unless (evaluation-request? request)
      (assertion-violation
        'chez-evaluator-evaluate
        "expected an evaluation request"
        request))
    (unless (interaction-session? session)
      (assertion-violation
        'chez-evaluator-evaluate
        "expected an interaction session"
        session))
    (call-with-values
      open-string-output-port
      (lambda (output-port extract-output)
        (call-with-values
          open-string-output-port
          (lambda (error-port extract-error)
            (let ([environment (chez-evaluator-environment evaluator)]
                  [input-port (open-string-input-port "")]
                  [result-values '()]
                  [failure #f]
                  [messages '()])
              (define emit-command!
                (case-lambda
                  [(name)
                   (emit-command! name #f)]
                  [(name argument)
                   (unless (symbol? name)
                     (assertion-violation
                       'editor-command!
                       "command name must be a symbol"
                       name))
                   (set! messages
                     (cons
                       (make-internal-command-message name argument)
                       messages))
                   (void)]))
              (set-top-level-value! '*editor* editor environment)
              (set-top-level-value!
                '*interaction-session*
                session
                environment)
              (set-top-level-value!
                'editor-command!
                emit-command!
                environment)
              (guard (condition
                       [else (set! failure condition)])
                (parameterize
                  ([current-input-port input-port]
                   [current-output-port output-port]
                   [current-error-port error-port]
                   [generate-inspector-information #t])
                  (set! result-values
                    (evaluate-source
                      environment
                      (evaluation-request-source request)))))
              (close-port input-port)
              (make-evaluation-result
                request
                (if failure 'condition 'value)
                (if failure '() result-values)
                (extract-output)
                (extract-error)
                failure
                (reverse messages))))))))

  (define (string-ends-in-newline? value)
    (and (positive? (string-length value))
         (char=? (string-ref value (- (string-length value) 1))
                 #\newline)))

  (define (display-fragment value port)
    (unless (zero? (string-length value))
      (display value port)
      (unless (string-ends-in-newline? value)
        (newline port))))

  (define (evaluation-result-continuation result)
    (unless (evaluation-result? result)
      (assertion-violation
        'evaluation-result-continuation
        "expected an evaluation result"
        result))
    (and
      (eq? (evaluation-result-status result) 'condition)
      (guard (condition [else #f])
        (condition-continuation
          (evaluation-result-condition result)))))

  (define (evaluation-result->transcript result)
    (unless (evaluation-result? result)
      (assertion-violation
        'evaluation-result->transcript
        "expected an evaluation result"
        result))
    (call-with-string-output-port
      (lambda (port)
        (display-fragment (evaluation-result-stdout result) port)
        (display-fragment (evaluation-result-stderr result) port)
        (case (evaluation-result-status result)
          [(value)
           (for-each
             (lambda (value)
               (unless (eq? value (void))
                 (write value port)
                 (newline port)))
             (evaluation-result-values result))]
          [(condition)
           (display "Exception: " port)
           (display-condition
             (evaluation-result-condition result)
             port)
           (newline port)])))))
