(library (soda editor effect)
  (export make-effect-executor
          effect-executor?
          register-effect-handler!
          make-effect-result
          effect-result-continue?
          effect-result-messages
          execute-effects!)
  (import (rnrs)
          (soda editor command))

  (define-record-type
    (effect-executor %make-effect-executor effect-executor?)
    (fields handlers))

  (define-record-type effect-result
    (fields continue? messages))

  (define (make-effect-executor)
    (%make-effect-executor (make-eq-hashtable)))

  (define (register-effect-handler! executor kind handler)
    (unless (effect-executor? executor)
      (assertion-violation
        'register-effect-handler!
        "expected an effect executor"
        executor))
    (unless (symbol? kind)
      (assertion-violation
        'register-effect-handler!
        "effect kind must be a symbol"
        kind))
    (unless (procedure? handler)
      (assertion-violation
        'register-effect-handler!
        "effect handler must be a procedure"
        handler))
    (hashtable-set! (effect-executor-handlers executor) kind handler)
    kind)

  (define (execute-one! executor effect)
    (unless (command-effect? effect)
      (assertion-violation
        'execute-effects!
        "expected a command effect"
        effect))
    (let* ([kind (command-effect-kind effect)]
           [handler
             (hashtable-ref
               (effect-executor-handlers executor)
               kind
               #f)])
      (unless handler
        (assertion-violation
          'execute-effects!
          "unhandled command effect"
          kind))
      (let ([result (handler (command-effect-payload effect))])
        (unless (effect-result? result)
          (assertion-violation
            'execute-effects!
            "effect handler must return an effect result"
            kind
            result))
        (unless (and (list? (effect-result-messages result)))
          (assertion-violation
            'execute-effects!
            "effect result messages must be a list"
            kind
            (effect-result-messages result)))
        result)))

  (define (execute-effects! executor effects)
    (unless (effect-executor? executor)
      (assertion-violation
        'execute-effects!
        "expected an effect executor"
        executor))
    (unless (and (list? effects) (for-all command-effect? effects))
      (assertion-violation
        'execute-effects!
        "expected a list of command effects"
        effects))
    (let loop ([remaining effects] [messages '()])
      (if (null? remaining)
          (make-effect-result #t (reverse messages))
          (let ([result (execute-one! executor (car remaining))])
            (let ([next-messages
                    (append
                      (reverse (effect-result-messages result))
                      messages)])
              (if (effect-result-continue? result)
                  (loop (cdr remaining) next-messages)
                  (make-effect-result #f (reverse next-messages)))))))))
