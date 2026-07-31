(library (soda editor evaluator)
  (export make-chez-evaluator
          chez-evaluator?
          chez-evaluator-symbols
          chez-evaluator-bindings
          chez-evaluator-runtime-symbols
          chez-evaluator-runtime-bindings
          chez-evaluator-generation
          chez-evaluator-binding-metadata
          chez-evaluator-ref
          chez-evaluator-evaluate
          chez-evaluator-evaluate-file!
          chez-evaluator-invalidate!
          make-evaluation-task
          evaluation-task?
          evaluation-task-request
          evaluation-task-state
          evaluation-task-step!
          evaluation-task-interrupt!
          evaluation-result-continuation
          evaluation-result->transcript
          runtime-binding?
          runtime-binding-name
          runtime-binding-kind
          runtime-binding-detail
          runtime-binding-preview
          runtime-binding-signature-formals
          runtime-binding-signatures
          runtime-binding-generation)
  (import (chezscheme)
          (soda editor event)
          (soda editor interaction))

  (define-record-type (chez-evaluator %make-chez-evaluator chez-evaluator?)
    (fields environment
            baseline-symbols
            (mutable generation
                     chez-evaluator-generation
                     chez-evaluator-generation-set!)
            (mutable catalog-generation
                     chez-evaluator-catalog-generation
                     chez-evaluator-catalog-generation-set!)
            (mutable catalog
                     chez-evaluator-catalog
                     chez-evaluator-catalog-set!)
            (mutable runtime-catalog-generation
                     chez-evaluator-runtime-catalog-generation
                     chez-evaluator-runtime-catalog-generation-set!)
            (mutable runtime-catalog
                     chez-evaluator-runtime-catalog
                     chez-evaluator-runtime-catalog-set!)))

  (define-record-type runtime-binding
    (fields
      name
      kind
      detail
      preview
      signature-formals
      generation))

  (define-record-type
    (evaluation-task %make-evaluation-task evaluation-task?)
    (fields
      request
      evaluator
      (mutable engine
               evaluation-task-engine
               evaluation-task-engine-set!)
      (mutable state
               evaluation-task-state
               evaluation-task-state-set!)
      (mutable started?
               evaluation-task-started?
               evaluation-task-started?-set!)
      (mutable result
               evaluation-task-result
               evaluation-task-result-set!)))

  (define (make-chez-evaluator)
    (let ([environment
            (copy-environment (scheme-environment))])
      (let ([baseline-symbols (make-eq-hashtable)])
        (for-each
          (lambda (name)
            (hashtable-set! baseline-symbols name #t))
          (environment-symbols environment))
        (%make-chez-evaluator
          environment
          baseline-symbols
          0
          -1
          '()
          -1
          '()))))

  (define (chez-evaluator-invalidate! evaluator)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'chez-evaluator-invalidate!
        "expected a Chez evaluator"
        evaluator))
    (chez-evaluator-generation-set!
      evaluator
      (+ 1 (chez-evaluator-generation evaluator)))
    evaluator)

  (define (chez-evaluator-symbols evaluator)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'chez-evaluator-symbols
        "expected a Chez evaluator"
        evaluator))
    (environment-symbols
      (chez-evaluator-environment evaluator)))

  (define (bounded-write value)
    (guard (condition [else "#<unavailable>"])
      (let ([text
              (call-with-string-output-port
                (lambda (port)
                  (parameterize
                    ([print-level 4]
                     [print-length 8])
                    (write value port))))])
        (if (> (string-length text) 160)
            (string-append (substring text 0 157) "...")
            text))))

  (define (arity-argument index)
    (string->symbol
      (string-append
        "arg"
        (number->string index))))

  (define (fixed-arity-formals count)
    (let loop ([index 1] [result '()])
      (if (> index count)
          (reverse result)
          (loop
            (+ index 1)
            (cons
              (arity-argument index)
              result)))))

  (define (rest-arity-formals minimum)
    (let loop ([index minimum] [result 'args])
      (if (zero? index)
          result
          (loop
            (- index 1)
            (cons
              (arity-argument index)
              result)))))

  (define (procedure-signature-formals value)
    (guard (condition [else '()])
      (let loop
        ([mask (procedure-arity-mask value)]
         [arity 0]
         [result '()])
        (cond
          [(zero? mask) (reverse result)]
          [(= mask -1)
           (reverse
             (cons
               (rest-arity-formals arity)
               result))]
          [else
           (loop
             (bitwise-arithmetic-shift-right mask 1)
             (+ arity 1)
             (if (odd? mask)
                 (cons
                   (fixed-arity-formals arity)
                   result)
                 result))]))))

  (define (runtime-binding-signatures binding)
    (unless (runtime-binding? binding)
      (assertion-violation
        'runtime-binding-signatures
        "expected a runtime binding"
        binding))
    (map
      (lambda (formals)
        (call-with-string-output-port
          (lambda (port)
            (write
              (cons
                (runtime-binding-name binding)
                formals)
              port))))
      (runtime-binding-signature-formals binding)))

  (define (make-binding-metadata evaluator name)
    (let ([environment (chez-evaluator-environment evaluator)])
      (if (top-level-bound? name environment)
          (let* ([value (top-level-value name environment)]
                 [kind
                   (if (procedure? value)
                       'procedure
                       'variable)])
            (make-runtime-binding
              name
              kind
              (if (eq? kind 'procedure)
                  "Runtime procedure"
                  "Runtime value")
              (bounded-write value)
              (if (eq? kind 'procedure)
                  (procedure-signature-formals value)
                  '())
              (chez-evaluator-generation evaluator)))
          (make-runtime-binding
            name
            'syntax
            "Runtime syntax"
            "#<syntax>"
            '()
            (chez-evaluator-generation evaluator)))))

  (define (chez-evaluator-bindings evaluator)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'chez-evaluator-bindings
        "expected a Chez evaluator"
        evaluator))
    (unless
      (= (chez-evaluator-catalog-generation evaluator)
         (chez-evaluator-generation evaluator))
      (chez-evaluator-catalog-set!
        evaluator
        (map
          (lambda (name)
            (make-binding-metadata evaluator name))
          (chez-evaluator-symbols evaluator)))
      (chez-evaluator-catalog-generation-set!
        evaluator
        (chez-evaluator-generation evaluator)))
    (chez-evaluator-catalog evaluator))

  (define (chez-evaluator-runtime-bindings evaluator)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'chez-evaluator-runtime-bindings
        "expected a Chez evaluator"
        evaluator))
    (unless
      (= (chez-evaluator-runtime-catalog-generation evaluator)
         (chez-evaluator-generation evaluator))
      (chez-evaluator-runtime-catalog-set!
        evaluator
        (map
          (lambda (name)
            (make-binding-metadata evaluator name))
          (filter
            (lambda (name)
              (not
                (hashtable-contains?
                  (chez-evaluator-baseline-symbols evaluator)
                  name)))
            (chez-evaluator-symbols evaluator))))
      (chez-evaluator-runtime-catalog-generation-set!
        evaluator
        (chez-evaluator-generation evaluator)))
    (chez-evaluator-runtime-catalog evaluator))

  (define (chez-evaluator-runtime-symbols evaluator)
    (map
      runtime-binding-name
      (chez-evaluator-runtime-bindings evaluator)))

  (define (chez-evaluator-binding-metadata evaluator name)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'chez-evaluator-binding-metadata
        "expected a Chez evaluator"
        evaluator))
    (unless (symbol? name)
      (assertion-violation
        'chez-evaluator-binding-metadata
        "name must be a symbol"
        name))
    (or
      (find
        (lambda (binding)
          (eq? name (runtime-binding-name binding)))
        (chez-evaluator-runtime-bindings evaluator))
      (and
        (hashtable-contains?
          (chez-evaluator-baseline-symbols evaluator)
          name)
        (find
          (lambda (binding)
            (eq? name (runtime-binding-name binding)))
          (chez-evaluator-bindings evaluator)))))

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
      (let ([values
              (call-with-input-file
                path
                (lambda (port)
                  (evaluate-port environment port)))])
        (chez-evaluator-invalidate! evaluator)
        values)))

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
              (chez-evaluator-invalidate! evaluator)
              (make-evaluation-result
                request
                (if failure 'condition 'value)
                (if failure '() result-values)
                (extract-output)
                (extract-error)
                failure
                (reverse messages))))))))

  (define (make-evaluation-task evaluator request editor session)
    (unless (chez-evaluator? evaluator)
      (assertion-violation
        'make-evaluation-task
        "expected a Chez evaluator"
        evaluator))
    (unless (evaluation-request? request)
      (assertion-violation
        'make-evaluation-task
        "expected an evaluation request"
        request))
    (unless (interaction-session? session)
      (assertion-violation
        'make-evaluation-task
        "expected an interaction session"
        session))
    (%make-evaluation-task
      request
      evaluator
      (make-engine
        (lambda ()
          (chez-evaluator-evaluate
            evaluator
            request
            editor
            session)))
      'ready
      #f
      #f))

  (define (evaluation-task-interrupt! task)
    (unless (evaluation-task? task)
      (assertion-violation
        'evaluation-task-interrupt!
        "expected an evaluation task"
        task))
    (when (memq (evaluation-task-state task) '(ready running))
      (when (evaluation-task-started? task)
        (chez-evaluator-invalidate!
          (evaluation-task-evaluator task)))
      (let ([result
              (make-evaluation-result
                (evaluation-task-request task)
                'interrupted
                '()
                ""
                ""
                #f
                '())])
        (evaluation-task-engine-set! task #f)
        (evaluation-task-result-set! task result)
        (evaluation-task-state-set! task 'interrupted)))
    (evaluation-task-result task))

  (define (evaluation-task-step! task ticks)
    (unless (evaluation-task? task)
      (assertion-violation
        'evaluation-task-step!
        "expected an evaluation task"
        task))
    (unless
      (and
        (integer? ticks)
        (exact? ticks)
        (positive? ticks)
        (fixnum? ticks))
      (assertion-violation
        'evaluation-task-step!
        "ticks must be a positive fixnum"
        ticks))
    (case (evaluation-task-state task)
      [(completed interrupted)
       (evaluation-task-result task)]
      [(ready running)
       (evaluation-task-started?-set! task #t)
       (evaluation-task-state-set! task 'running)
       (let ([outcome
               ((evaluation-task-engine task)
                ticks
                (lambda (remaining result)
                  (list 'completed result))
                (lambda (engine)
                  (list 'expired engine)))])
         (case (car outcome)
           [(completed)
            (evaluation-task-engine-set! task #f)
            (evaluation-task-result-set! task (cadr outcome))
            (evaluation-task-state-set! task 'completed)
            (evaluation-task-result task)]
           [(expired)
            (evaluation-task-engine-set! task (cadr outcome))
            #f]
           [else
            (assertion-violation
              'evaluation-task-step!
              "engine returned an unknown outcome"
              outcome)]))]
      [else
       (assertion-violation
         'evaluation-task-step!
         "evaluation task has an invalid state"
         (evaluation-task-state task))]))

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
           (newline port)]
          [(interrupted)
           (display "Interrupted" port)
           (newline port)])))))
