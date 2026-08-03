(library (soda editor evaluator)
  (export make-chez-evaluator
          chez-evaluator?
          chez-evaluator-symbols
          chez-evaluator-bindings
          chez-evaluator-runtime-symbols
          chez-evaluator-runtime-bindings
          chez-evaluator-generation
          chez-evaluator-source-debugger
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
          evaluation-task-resume!
          evaluation-task-resume-source!
          evaluation-task-resume-condition!
          evaluation-task-resume-continuation!
          evaluation-task-abort!
          evaluation-result-continuation
          evaluation-result->transcript
          runtime-binding?
          runtime-binding-name
          runtime-binding-kind
          runtime-binding-detail
          runtime-binding-preview
          runtime-binding-signature-formals
          runtime-binding-signatures)
  (import (chezscheme)
          (soda editor event)
          (soda editor interaction)
          (soda editor source-debug))

  (define-record-type (chez-evaluator %make-chez-evaluator chez-evaluator?)
    (fields environment
            source-debugger
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
      signature-formals))

  (define-record-type evaluation-control
    (fields
      (mutable failure
               evaluation-control-failure
               evaluation-control-failure-set!)
      source-debugger
      engine-enabled?
      (mutable stop
               evaluation-control-stop
               evaluation-control-stop-set!)
      (mutable plan
               evaluation-control-plan
               evaluation-control-plan-set!)
      (mutable suppressed-breakpoint-id
               evaluation-control-suppressed-breakpoint-id
               evaluation-control-suppressed-breakpoint-id-set!)))

  (define-record-type
    (evaluation-task %make-evaluation-task evaluation-task?)
    (fields
      request
      evaluator
      control
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
          (make-source-debug-controller)
          baseline-symbols
          0
          -1
          '()
          -1
          '()))))

  (define current-evaluation-control
    (make-thread-parameter #f))

  (define (continuation-depth continuation)
    (guard (condition [else 0])
      (let ([depth
              ((inspect/object continuation) 'depth)])
        (if
          (and
            (integer? depth)
            (exact? depth)
            (not (negative? depth)))
          depth
          0))))

  (define (source-plan-stop-kind plan location depth)
    (and
      plan
      (not
        (source-location=?
          location
          (source-debug-plan-location plan)))
      (case (source-debug-plan-kind plan)
        [(step) 'step]
        [(next)
         (and
           (<= depth (source-debug-plan-depth plan))
           'next)]
        [(finish)
         (and
           (< depth (source-debug-plan-depth plan))
           'finish)])))

  (define (source-debug-probe resource start end)
    (let ([control (current-evaluation-control)])
      (when
        (and
          control
          (evaluation-control-engine-enabled? control))
        (let* ([location
                 (make-source-location resource start end)]
               [controller
                 (evaluation-control-source-debugger control)]
               [matched
                 (source-debug-controller-matching-breakpoint
                   controller
                   location)]
               [suppressed-id
                 (evaluation-control-suppressed-breakpoint-id
                   control)]
               [breakpoint
                 (and
                   matched
                   (not
                     (and
                       suppressed-id
                       (= suppressed-id
                          (source-breakpoint-id matched))))
                   matched)]
               [plan (evaluation-control-plan control)])
          (when
            (or breakpoint plan)
            (call/cc
              (lambda (continuation)
                (let* ([depth
                         (continuation-depth continuation)]
                       [kind
                         (or
                           (and breakpoint 'breakpoint)
                           (source-plan-stop-kind
                             plan
                             location
                             depth))])
                  (when kind
                    (evaluation-control-stop-set!
                      control
                      (make-source-debug-stop
                        kind
                        location
                        depth
                        continuation
                        breakpoint))
                    (evaluation-control-plan-set!
                      control
                      #f)
                    (when breakpoint
                      (evaluation-control-suppressed-breakpoint-id-set!
                        control
                        (source-breakpoint-id breakpoint)))
                    (engine-block))))))
          (unless matched
            (evaluation-control-suppressed-breakpoint-id-set!
              control
              #f))))))

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
                  '())))
          (make-runtime-binding
            name
            'syntax
            "Runtime syntax"
            "#<syntax>"
            '()))))

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

  (define (evaluate-annotated-port
            environment
            port
            resource
            initial-position)
    (let ([sfd (source-file-descriptor resource 0)])
      (let loop
        ([position initial-position]
         [last-values '()]
         [evaluated? #f])
        (call-with-values
          (lambda ()
            (get-datum/annotations port sfd position))
          (lambda (form next-position)
            (if (eof-object? form)
                (if evaluated? last-values '())
                (loop
                  next-position
                  (call-with-values
                    (lambda ()
                      (eval
                        (source-debug-instrument
                          form
                          resource
                          'soda-source-debug-probe)
                        environment))
                    list)
                  #t)))))))

  (define (evaluation-source-resource request)
    (let ([origin (evaluation-request-origin request)])
      (or
        (and origin
             (evaluation-origin-resource origin))
        (string-append
          "*evaluation:"
          (number->string
            (evaluation-request-session-id request))
          ":"
          (number->string
            (evaluation-request-generation request))
          "*"))))

  (define (evaluation-source-start request)
    (let ([origin (evaluation-request-origin request)])
      (or
        (and origin
             (evaluation-origin-start origin))
        0)))

  (define (evaluate-source environment request)
    (let* ([source (evaluation-request-source request)]
           [resource (evaluation-source-resource request)]
           [port (open-string-input-port source)])
      (evaluate-annotated-port
        environment
        port
        resource
        (evaluation-source-start request))))

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
      (set-top-level-value!
        'soda-source-debug-probe
        source-debug-probe
        environment)
      (let ([values
              (parameterize
                ([generate-inspector-information #t]
                 [run-cp0 (lambda (cp0 form) form)])
                (call-with-input-file
                  path
                  (lambda (port)
                    (evaluate-annotated-port
                      environment
                      port
                      path
                      0))))])
        (chez-evaluator-invalidate! evaluator)
        values)))

  (define (evaluate-with-control
            evaluator
            request
            editor
            session
            control)
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
              (set-top-level-value!
                'soda-source-debug-probe
                source-debug-probe
                environment)
              (guard (condition
                       [else
                        (evaluation-control-failure-set!
                          control
                          condition)])
                (parameterize
                  ([current-input-port input-port]
                   [current-output-port output-port]
                   [current-error-port error-port]
                   [generate-inspector-information #t]
                   [run-cp0 (lambda (cp0 form) form)])
                  (parameterize
                    ([current-evaluation-control control])
                    (set! result-values
                      (evaluate-source
                        environment
                        request)))))
              (let ([failure
                      (evaluation-control-failure control)]
                    [output (extract-output)]
                    [error-output (extract-error)]
                    [result-messages (reverse messages)])
                (set! messages '())
                (chez-evaluator-invalidate! evaluator)
                (make-evaluation-result
                  request
                  (if failure 'condition 'value)
                  (if failure '() result-values)
                  output
                  error-output
                  failure
                  result-messages))))))))

  (define (chez-evaluator-evaluate
            evaluator
            request
            editor
            session)
    (evaluate-with-control
      evaluator
      request
      editor
      session
      (make-evaluation-control
        #f
        (chez-evaluator-source-debugger evaluator)
        #f
        #f
        #f
        #f)))

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
    (let ([control
            (make-evaluation-control
              #f
              (chez-evaluator-source-debugger evaluator)
              #t
              #f
              #f
              #f)])
      (%make-evaluation-task
        request
        evaluator
        control
        (make-engine
          (lambda ()
            (evaluate-with-control
              evaluator
              request
              editor
              session
              control)))
        'ready
        #f
        #f)))

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
      (let* ([request (evaluation-task-request task)]
             [engine (evaluation-task-engine task)]
             [suspension
               (condition
                 (make-evaluation-suspension-condition
                   (evaluation-request-session-id request)
                   (evaluation-request-generation request)
                   engine)
                 (make-who-condition 'scheme.evaluate)
                 (make-message-condition
                   "evaluation interrupted by the user"))]
             [result
               (make-evaluation-result
                 request
                 'suspended
                 '()
                 ""
                 ""
                 suspension
                 '())])
        (evaluation-task-result-set! task result)
        (evaluation-task-state-set! task 'suspended)))
    (evaluation-task-result task))

  (define (evaluation-task-resume! task)
    (unless (evaluation-task? task)
      (assertion-violation
        'evaluation-task-resume!
        "expected an evaluation task"
        task))
    (unless (eq? (evaluation-task-state task) 'suspended)
      (assertion-violation
        'evaluation-task-resume!
        "evaluation task is not suspended"
        (evaluation-task-state task)))
    (evaluation-control-stop-set!
      (evaluation-task-control task)
      #f)
    (evaluation-control-plan-set!
      (evaluation-task-control task)
      #f)
    (evaluation-task-result-set! task #f)
    (evaluation-task-state-set! task 'running)
    task)

  (define (evaluation-task-resume-source! task kind)
    (unless (evaluation-task? task)
      (assertion-violation
        'evaluation-task-resume-source!
        "expected an evaluation task"
        task))
    (unless (memq kind '(step next finish))
      (assertion-violation
        'evaluation-task-resume-source!
        "source resume kind must be step, next, or finish"
        kind))
    (unless
      (and
        (eq? (evaluation-task-state task) 'suspended)
        (evaluation-task-result task)
        (source-debug-suspension-condition?
          (evaluation-result-condition
            (evaluation-task-result task))))
      (assertion-violation
        'evaluation-task-resume-source!
        "evaluation task is not stopped in source code"
        (evaluation-task-state task)))
    (let* ([control (evaluation-task-control task)]
           [stop
             (source-debug-suspension-stop
               (evaluation-result-condition
                 (evaluation-task-result task)))])
      (evaluation-control-stop-set! control #f)
      (evaluation-control-plan-set!
        control
        (make-source-debug-plan
          kind
          (source-debug-stop-location stop)
          (source-debug-stop-depth stop)))
      (evaluation-task-result-set! task #f)
      (evaluation-task-state-set! task 'running)
      task))

  (define (evaluation-task-resume-condition! task values)
    (unless (evaluation-task? task)
      (assertion-violation
        'evaluation-task-resume-condition!
        "expected an evaluation task"
        task))
    (unless (list? values)
      (assertion-violation
        'evaluation-task-resume-condition!
        "replacement values must be a list"
        values))
    (unless
      (and
        (eq? (evaluation-task-state task) 'failed)
        (evaluation-task-result task))
      (assertion-violation
        'evaluation-task-resume-condition!
        "evaluation task has no failed continuation"
        (evaluation-task-state task)))
    (let ([continuation
            (evaluation-result-continuation
              (evaluation-task-result task))])
      (unless continuation
        (assertion-violation
          'evaluation-task-resume-condition!
          "failed evaluation has no continuation"))
      (evaluation-control-failure-set!
        (evaluation-task-control task)
        #f)
      (evaluation-task-engine-set!
        task
        (make-engine
          (lambda ()
            (apply continuation values))))
      (evaluation-task-result-set! task #f)
      (evaluation-task-state-set! task 'running)
      task))

  (define (evaluation-task-resume-continuation!
            task
            procedure
            continuation)
    (unless (evaluation-task? task)
      (assertion-violation
        'evaluation-task-resume-continuation!
        "expected an evaluation task"
        task))
    (unless (procedure? procedure)
      (assertion-violation
        'evaluation-task-resume-continuation!
        "continuation transformer must be a procedure"
        procedure))
    (unless (procedure? continuation)
      (assertion-violation
        'evaluation-task-resume-continuation!
        "inspected continuation must be a procedure"
        continuation))
    (unless
      (and
        (eq? (evaluation-task-state task) 'failed)
        (evaluation-task-result task))
      (assertion-violation
        'evaluation-task-resume-continuation!
        "evaluation task has no failed continuation"
        (evaluation-task-state task)))
    (evaluation-control-failure-set!
      (evaluation-task-control task)
      #f)
    (evaluation-task-engine-set!
      task
      (make-engine
        (lambda ()
          (call-with-values
            (lambda ()
              (procedure continuation))
            (lambda values
              (apply continuation values))))))
    (evaluation-task-result-set! task #f)
    (evaluation-task-state-set! task 'running)
    task)

  (define (evaluation-task-abort! task)
    (unless (evaluation-task? task)
      (assertion-violation
        'evaluation-task-abort!
        "expected an evaluation task"
        task))
    (evaluation-task-engine-set! task #f)
    (evaluation-task-result-set! task #f)
    (evaluation-task-state-set! task 'aborted)
    task)

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
      [(completed suspended)
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
            (evaluation-task-state-set!
              task
              (if
                (eq?
                  (evaluation-result-status (cadr outcome))
                  'condition)
                'failed
                'completed))
            (evaluation-task-result task)]
           [(expired)
            (evaluation-task-engine-set! task (cadr outcome))
            (let ([stop
                    (evaluation-control-stop
                      (evaluation-task-control task))])
              (if stop
                  (let* ([kind
                           (source-debug-stop-kind stop)]
                         [condition
                           (condition
                             (make-source-debug-suspension-condition
                               stop)
                             (make-who-condition 'scheme.evaluate)
                             (make-message-condition
                               (string-append
                                 "evaluation stopped at a source "
                                 (symbol->string kind))))]
                         [result
                           (make-evaluation-result
                             (evaluation-task-request task)
                             'suspended
                             '()
                             ""
                             ""
                             condition
                             '())])
                    (evaluation-task-result-set! task result)
                    (evaluation-task-state-set! task 'suspended)
                    result)
                  #f))]
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
    (let ([condition (evaluation-result-condition result)])
      (cond
        [(and
           condition
           (source-debug-suspension-condition? condition))
         (source-debug-stop-continuation
           (source-debug-suspension-stop condition))]
        [(eq? (evaluation-result-status result) 'condition)
         (guard (condition [else #f])
           (condition-continuation condition))]
        [else #f])))

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
          [(suspended)
           (display "Interrupted" port)
           (newline port)])))))
