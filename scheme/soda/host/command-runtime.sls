(library (soda host command-runtime)
  (export make-command-runtime
          command-runtime?
          define-command
          command-runtime-register-command!
          command-runtime-command-definition
          command-runtime-command-names
          command-runtime-command-definitions
          command-runtime-command-available?
          command-runtime-available-command-names
          command-runtime-available-command-definitions
          command-runtime-command-interactive?
          command-runtime-start!
          command-runtime-start-interactive!
          command-runtime-resume!
          command-runtime-cancel!
          command-runtime-invocation
          command-runtime-set-interaction-handler!
          command-runtime-register-effect-handler!
          command-runtime-add-hook!
          command-runtime-add-advice!
          make-command-invoke-message
          command-invoke-message?
          command-invoke-message-name
          command-invoke-message-context
          command-invoke-message-arguments
          command-invoke-message-interactive?
          make-command-resume-message
          command-resume-message?
          command-resume-message-invocation-id
          command-resume-message-value
          make-command-cancel-message
          command-cancel-message?
          command-cancel-message-invocation-id
          command-runtime-enqueue!
          command-runtime-handle-message!)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host condition)
          (soda host dispatch)
          (soda host operation)
          (soda host runtime)
          (soda host value))

  ;; CommandRuntime is the impure half of the command protocol.  It owns
  ;; invocation liveness and applies declared outcomes, while command and
  ;; interaction packages remain ordinary clients of its public registrations.
  (define-record-type
    (command-runtime %make-command-runtime command-runtime?)
    (fields
      (immutable owner command-runtime-owner)
      (immutable registry command-runtime-registry)
      (immutable dispatcher command-runtime-dispatcher)
      (immutable queue command-runtime-queue)
      (immutable conditions command-runtime-conditions)
      (immutable invocations command-runtime-invocations)
      (immutable advice command-runtime-advice)
      (immutable hooks command-runtime-hooks)
      (immutable effects command-runtime-effects)
      (mutable interaction-handler command-runtime-interaction-handler
                                   command-runtime-interaction-handler-set!)
      (mutable interaction-registration command-runtime-interaction-registration
                                        command-runtime-interaction-registration-set!)
      (mutable next-order command-runtime-next-order command-runtime-next-order-set!)))

  (define (make-command-runtime owner registry dispatcher queue conditions)
    (owner-assert-active 'make-command-runtime owner)
    (unless (and (command-registry? registry) (dispatcher? dispatcher)
                 (runtime? queue) (condition-service? conditions))
      (assertion-violation 'make-command-runtime "invalid command runtime dependencies"))
    (%make-command-runtime
      owner registry dispatcher queue conditions
      (make-eqv-hashtable) (make-eq-hashtable) (make-eq-hashtable)
      (make-eq-hashtable) #f #f 0))

  ;; Command definitions are registered through their runtime, so a package
  ;; never needs access to the mutable CommandRegistry implementation.
  (define (command-runtime-register-command! service definition)
    (unless (and (command-runtime? service) (command-definition? definition))
      (assertion-violation 'command-runtime-register-command!
                           "expected a command runtime and definition"
                           service definition))
    (command-register! (command-runtime-registry service) definition))

  ;; Command declarations expand to an owner-scoped registry operation.  The
  ;; interactive clause is explicit so ordinary command bodies remain
  ;; unrestricted Scheme expressions.
  (define-syntax define-command
    (syntax-rules (interactive scope)
      [(_ runtime owner name (context . arguments) documentation class
          (scope command-scope) (interactive interaction-spec) body ...)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name (lambda (context . arguments) body ...) owner
           documentation class interaction-spec command-scope))]
      [(_ runtime owner name (context . arguments) documentation class
          (scope command-scope) body ...)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name (lambda (context . arguments) body ...) owner
           documentation class #f command-scope))]
      [(_ runtime owner name (context . arguments) documentation class
          (interactive interaction-spec) body ...)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name (lambda (context . arguments) body ...) owner
           documentation class interaction-spec))]
      [(_ runtime owner name (context . arguments) documentation class body ...)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name (lambda (context . arguments) body ...) owner
           documentation class #f))]))

  (define command-runtime-command-definition
    (case-lambda
      [(service name)
       (command-runtime-command-definition service name #f)]
      [(service name default)
       (unless (and (command-runtime? service) (symbol? name))
         (assertion-violation 'command-runtime-command-definition
                              "expected a command runtime and name" service name))
       (command-lookup (command-runtime-registry service) name default)]))

  (define (command-runtime-command-names service)
    (unless (command-runtime? service)
      (assertion-violation 'command-runtime-command-names
                           "expected a command runtime" service))
    (list-sort
      (lambda (left right)
        (string<? (symbol->string left) (symbol->string right)))
      (command-names (command-runtime-registry service))))

  (define (command-runtime-command-definitions service)
    (map (lambda (name) (command-runtime-command-definition service name))
         (command-runtime-command-names service)))

  (define (context-command-categories context)
    (let ([state (command-context-buffer-state context)])
      (if (not state)
          '()
          (let* ([configuration (buffer-state-configuration state)]
                 [major (configuration-facet configuration buffer-mode-facet 'buffer)]
                 [minor (configuration-facet
                          configuration buffer-minor-modes-facet 'buffer)])
            (fold-left
              append '()
              (map mode-spec-command-category-list
                   (append (if major (list major) '()) minor)))))))

  (define (command-runtime-command-available? service definition-or-name context)
    (unless (and (command-runtime? service) (command-context? context))
      (assertion-violation 'command-runtime-command-available?
                           "expected a command runtime and context" service context))
    (let ([definition
           (if (command-definition? definition-or-name)
               definition-or-name
               (command-runtime-command-definition service definition-or-name #f))])
      (and definition
           (or (eq? (command-definition-scope definition) 'global)
               (and (command-definition-class definition)
                    (memq (command-definition-class definition)
                          (context-command-categories context)))))))

  (define (command-runtime-available-command-definitions service context)
    (filter
      (lambda (definition)
        (command-runtime-command-available? service definition context))
      (command-runtime-command-definitions service)))

  (define (command-runtime-available-command-names service context)
    (map command-definition-name
         (command-runtime-available-command-definitions service context)))

  (define-record-type
    (runtime-advice %make-runtime-advice runtime-advice?)
    (fields
      (immutable name runtime-advice-name)
      (immutable owner runtime-advice-owner)
      (immutable where runtime-advice-where)
      (immutable procedure runtime-advice-procedure)
      (immutable depth runtime-advice-depth)
      (immutable order runtime-advice-order)))

  (define-record-type
    (runtime-hook %make-runtime-hook runtime-hook?)
    (fields
      (immutable name runtime-hook-name)
      (immutable owner runtime-hook-owner)
      (immutable procedure runtime-hook-procedure)
      (immutable order runtime-hook-order)))

  (define-record-type
    (effect-handler %make-effect-handler effect-handler?)
    (fields
      (immutable name effect-handler-name)
      (immutable owner effect-handler-owner)
      (immutable procedure effect-handler-procedure)
      (immutable order effect-handler-order)))

  (define (next-order! service)
    (let ([next (+ 1 (command-runtime-next-order service))])
      (command-runtime-next-order-set! service next)
      next))

  (define (exact-integer-value? value)
    (and (integer? value) (exact? value)))

  (define (sorted-by-order entries order)
    (list-sort (lambda (left right) (< (order left) (order right))) entries))

  (define (advice-for service name)
    (sorted-by-order
      (hashtable-ref (command-runtime-advice service) name '())
      (lambda (entry)
        ;; Depth gives the same primary ordering convention as Emacs advice;
        ;; registration order resolves equal depths deterministically.
        (+ (* 1000000 (runtime-advice-depth entry)) (runtime-advice-order entry)))))

  (define (hooks-for service phase)
    (sorted-by-order
      (hashtable-ref (command-runtime-hooks service) phase '())
      runtime-hook-order))

  (define (assert-active-registration who owner name procedure)
    (owner-assert-active who owner)
    (unless (and (symbol? name) (procedure? procedure))
      (assertion-violation who "invalid named registration" name procedure)))

  ;; Advice, hooks, and effect handlers differ in dispatch semantics, not in
  ;; ownership.  One registration path keeps duplicate detection, ordering,
  ;; and owner cleanup identical for all three lifecycle facets.
  (define (register-named-entry! who service table scope name owner procedure entry-name make-entry)
    (assert-active-registration who owner name procedure)
    (let ([existing (hashtable-ref table scope '())])
      (when (exists (lambda (entry) (eq? name (entry-name entry))) existing)
        (assertion-violation who "registration is already registered" scope name))
      (let ([entry (make-entry)])
        (hashtable-set! table scope (append existing (list entry)))
        (make-registration
          owner
          (lambda ()
            (hashtable-set!
              table scope
              (filter (lambda (item) (not (eq? item entry)))
                      (hashtable-ref table scope '()))))))))

  (define command-runtime-set-interaction-handler!
    (case-lambda
      [(service handler)
       (command-runtime-set-interaction-handler!
         service (command-runtime-owner service) handler)]
      [(service owner handler)
       (unless (and (command-runtime? service) (or (not handler) (procedure? handler)))
         (assertion-violation 'command-runtime-set-interaction-handler!
                              "expected a runtime and procedure or #f" service handler))
       (owner-assert-active 'command-runtime-set-interaction-handler! owner)
       (let ([current (command-runtime-interaction-registration service)])
         (when current (registration-close! current))
         (if (not handler)
             (begin
               (command-runtime-interaction-handler-set! service #f)
               (command-runtime-interaction-registration-set! service #f)
               #f)
             (let ([registration
                     (make-registration
                       owner
                       (lambda ()
                         (when (eq? (command-runtime-interaction-handler service) handler)
                           (command-runtime-interaction-handler-set! service #f)
                           (command-runtime-interaction-registration-set! service #f))))])
               (command-runtime-interaction-handler-set! service handler)
               (command-runtime-interaction-registration-set! service registration)
               registration)))]))

  (define (command-runtime-register-effect-handler! service kind owner name procedure)
    (unless (and (command-runtime? service) (symbol? kind))
      (assertion-violation 'command-runtime-register-effect-handler!
                           "invalid runtime or effect kind" service kind))
    (register-named-entry!
      'command-runtime-register-effect-handler! service (command-runtime-effects service)
      kind name owner procedure effect-handler-name
      (lambda () (%make-effect-handler name owner procedure (next-order! service)))))

  (define (command-runtime-add-hook! service phase owner name procedure)
    (unless (and (command-runtime? service)
                 (memq phase '(pre-command post-command command-error command-cancel)))
      (assertion-violation 'command-runtime-add-hook! "invalid runtime or hook phase" service phase))
    (register-named-entry!
      'command-runtime-add-hook! service (command-runtime-hooks service)
      phase name owner procedure runtime-hook-name
      (lambda () (%make-runtime-hook name owner procedure (next-order! service)))))

  (define command-advice-placements
    '(before after around filter-args filter-return))

  (define command-runtime-add-advice!
    (case-lambda
      [(service command owner name where procedure)
       (command-runtime-add-advice! service command owner name where procedure 0)]
      [(service command owner name where procedure depth)
       (unless (and (command-runtime? service) (symbol? command)
                    (memq where command-advice-placements)
                    (exact-integer-value? depth))
         (assertion-violation 'command-runtime-add-advice! "invalid advice declaration"
                              command name where depth))
       (unless (command-lookup (command-runtime-registry service) command #f)
         (assertion-violation 'command-runtime-add-advice! "unknown command" command))
       (register-named-entry!
         'command-runtime-add-advice! service (command-runtime-advice service)
         command name owner procedure runtime-advice-name
         (lambda ()
           (%make-runtime-advice
             name owner where procedure depth (next-order! service))))]))

  (define (normalize-command-result value)
    (cond
      [(command-result? value) value]
      [(or (command-handled? value)
           (command-effect? value)
           (transaction-spec? value)
           (view-transaction-spec? value)
           (host-operation? value))
       (make-command-result (list value))]
      [(list? value) (make-command-result value)]
      [else
       (assertion-violation 'command-runtime "command returned an invalid result" value)]))

  (define (invoke-with-advice service invocation definition context arguments)
    (let* ([advice (advice-for service (command-definition-name definition))]
           [filtered-arguments
             (fold-left
               (lambda (current entry)
                 (if (eq? (runtime-advice-where entry) 'filter-args)
                     (let ([next ((runtime-advice-procedure entry) context current)])
                       (unless (list? next)
                         (assertion-violation 'command-runtime "filter-args advice must return a list"
                                              (runtime-advice-name entry) next))
                       next)
                     current))
               arguments advice)]
           [base
             (lambda (call-context call-arguments)
               (command-invoke definition call-context call-arguments))]
           [invoke
             (fold-right
               (lambda (entry next)
                 (if (eq? (runtime-advice-where entry) 'around)
                     (lambda (call-context call-arguments)
                       ((runtime-advice-procedure entry) next call-context call-arguments))
                     next))
               base advice)])
      (for-each
        (lambda (entry)
          (when (eq? (runtime-advice-where entry) 'before)
            ((runtime-advice-procedure entry) context filtered-arguments)))
        advice)
      (let ([result
              (fold-left
                (lambda (current entry)
                  (if (eq? (runtime-advice-where entry) 'filter-return)
                      (normalize-command-result
                        ((runtime-advice-procedure entry) context filtered-arguments current))
                      current))
                (normalize-command-result (invoke context filtered-arguments))
                advice)])
        (for-each
          (lambda (entry)
            (when (eq? (runtime-advice-where entry) 'after)
              ((runtime-advice-procedure entry) context filtered-arguments result)))
          (reverse advice))
        result)))

  (define (apply-effect! service invocation effect)
    (let ([handlers
            (sorted-by-order
              (hashtable-ref (command-runtime-effects service)
                             (command-effect-kind effect) '())
              effect-handler-order)])
      (for-each
        (lambda (handler)
          ((effect-handler-procedure handler) service invocation effect))
        handlers)))

  (define (apply-outcome! service invocation outcome)
    (cond
      [(command-handled? outcome) #t]
      [(transaction-spec? outcome)
       (dispatcher-dispatch! (command-runtime-dispatcher service) outcome)]
      [(view-transaction-spec? outcome)
       (dispatcher-dispatch-view! (command-runtime-dispatcher service) outcome)]
      [(host-operation? outcome)
       (dispatcher-dispatch-host! (command-runtime-dispatcher service) outcome)]
      [(command-effect? outcome) (apply-effect! service invocation outcome)]
      [else
       (assertion-violation 'command-runtime "unknown command outcome" outcome)]))

  (define (apply-result! service invocation result)
    (let ([normalized (normalize-command-result result)])
      (for-each
        (lambda (outcome) (apply-outcome! service invocation outcome))
        (command-result-outcomes normalized))
      normalized))

  (define (run-hooks! service phase . arguments)
    (for-each
      (lambda (entry)
        (apply (runtime-hook-procedure entry) arguments))
      (hooks-for service phase)))

  (define (invoke-definition! service invocation definition context arguments)
    (run-hooks! service 'pre-command invocation)
    (let ([result (apply-result!
                    service invocation
                    (invoke-with-advice service invocation definition context arguments))])
      (run-hooks! service 'post-command invocation result)
      result))

  (define (retire-invocation! service invocation)
    (hashtable-delete! (command-runtime-invocations service)
                       (command-invocation-id invocation))
    invocation)

  (define (capture-command-condition! service invocation condition)
    (let* ([entry
            (condition-service-capture
              (command-runtime-conditions service)
              (command-runtime-owner service)
              (list 'command (command-definition-name (command-invocation-definition invocation))
                    condition)
              (lambda arguments #f)
              '(dismiss))])
      (command-invocation-record-condition! invocation entry)
      (command-invocation-cancel! invocation)
      ;; A hook failure is itself just a failed command lifecycle and must not
      ;; recursively create a second condition.
      (guard (ignored [else #f])
        (run-hooks! service 'command-error invocation entry))
      (retire-invocation! service invocation)))

  (define (advance-invocation! service invocation resume? value)
    (guard
      (condition
        [else (capture-command-condition! service invocation condition)])
      (let ([result
              (if resume?
                  (command-invocation-resume!
                    invocation value
                    (lambda (definition context arguments)
                      (invoke-definition! service invocation definition context arguments)))
                  (command-invocation-step!
                    invocation
                    (lambda (definition context arguments)
                      (invoke-definition! service invocation definition context arguments))))])
        (cond
          [(interactive-suspend? result)
           (let ([handler (command-runtime-interaction-handler service)])
             (when handler (handler service invocation (interactive-suspend-request result)))
             invocation)]
          [(eq? (command-invocation-phase invocation) 'completed)
           (retire-invocation! service invocation)]
          [else invocation]))))

  (define (lookup-definition service name)
    (unless (symbol? name)
      (assertion-violation 'command-runtime "command name must be a symbol" name))
    (or (command-lookup (command-runtime-registry service) name #f)
        (assertion-violation 'command-runtime "unknown command" name)))

  ;; The frontend owns input dispatch but not command declarations.  It asks
  ;; the runtime whether a named key binding has an InteractivePlan, then
  ;; preserves that declaration in its queued invocation message.
  (define (command-runtime-command-interactive? service name)
    (unless (command-runtime? service)
      (assertion-violation 'command-runtime-command-interactive?
                           "expected a command runtime" service))
    (command-definition-interactive? (lookup-definition service name)))

  (define (start! service name context interactive? arguments)
    (unless (and (command-runtime? service) (command-context? context) (list? arguments))
      (assertion-violation 'command-runtime-start! "invalid command start" name context arguments))
    (let* ([definition (lookup-definition service name)]
           [invocation
             (if (and interactive? (command-definition-interactive? definition))
                 (make-interactive-command-invocation definition context arguments)
                 (make-command-invocation definition context arguments))])
      (hashtable-set! (command-runtime-invocations service)
                      (command-invocation-id invocation) invocation)
      (advance-invocation! service invocation #f #f)))

  (define command-runtime-start!
    (case-lambda
      [(service name context) (start! service name context #f '())]
      [(service name context arguments) (start! service name context #f arguments)]))

  (define command-runtime-start-interactive!
    (case-lambda
      [(service name context) (start! service name context #t '())]
      [(service name context arguments) (start! service name context #t arguments)]))

  (define (command-runtime-invocation service id . default)
    (let ([value (hashtable-ref (command-runtime-invocations service) id #f)])
      (if value value (if (null? default) #f (car default)))))

  (define (command-runtime-resume! service id value)
    (unless (command-runtime? service)
      (assertion-violation 'command-runtime-resume! "expected a command runtime" service))
    (let ([invocation (command-runtime-invocation service id #f)])
      (and invocation (advance-invocation! service invocation #t value))))

  (define (command-runtime-cancel! service id)
    (unless (command-runtime? service)
      (assertion-violation 'command-runtime-cancel! "expected a command runtime" service))
    (let ([invocation (command-runtime-invocation service id #f)])
      (and invocation
           (let ([cancelled? (command-invocation-cancel! invocation)])
             (when cancelled?
               (guard (ignored [else #f])
                 (run-hooks! service 'command-cancel invocation))
               (retire-invocation! service invocation))
             cancelled?))))

  ;; Queue messages let terminal, RPC, and minibuffer packages resume work at
  ;; the command-loop boundary without retaining continuations across a UI or
  ;; FFI call.  They are plain immutable values so headless hosts use them too.
  (define-record-type
    (command-invoke-message %make-command-invoke-message command-invoke-message?)
    (fields
      (immutable name command-invoke-message-name)
      (immutable context command-invoke-message-context)
      (immutable arguments command-invoke-message-arguments)
      (immutable interactive? command-invoke-message-interactive?)))

  (define make-command-invoke-message
    (case-lambda
      [(name context) (make-command-invoke-message name context '() #f)]
      [(name context arguments) (make-command-invoke-message name context arguments #f)]
      [(name context arguments interactive?)
       (unless (and (symbol? name) (command-context? context) (list? arguments))
         (assertion-violation 'make-command-invoke-message "invalid command message"
                              name context arguments))
       (%make-command-invoke-message name context (list-copy arguments) (and interactive? #t))]))

  (define-record-type
    (command-resume-message %make-command-resume-message command-resume-message?)
    (fields
      (immutable invocation-id command-resume-message-invocation-id)
      (immutable value command-resume-message-value)))

  (define (make-command-resume-message invocation-id value)
    (unless (and (exact-integer-value? invocation-id) (>= invocation-id 0))
      (assertion-violation 'make-command-resume-message "invalid invocation id" invocation-id))
    (%make-command-resume-message invocation-id value))

  (define-record-type
    (command-cancel-message %make-command-cancel-message command-cancel-message?)
    (fields
      (immutable invocation-id command-cancel-message-invocation-id)))

  (define (make-command-cancel-message invocation-id)
    (unless (and (exact-integer-value? invocation-id) (>= invocation-id 0))
      (assertion-violation 'make-command-cancel-message "invalid invocation id" invocation-id))
    (%make-command-cancel-message invocation-id))

  (define (command-runtime-enqueue! service message)
    (unless (and (command-runtime? service)
                 (or (command-invoke-message? message)
                     (command-resume-message? message)
                     (command-cancel-message? message)))
      (assertion-violation 'command-runtime-enqueue! "invalid command message" message))
    (runtime-enqueue! (command-runtime-queue service) message))

  (define (capture-runtime-condition! service message condition)
    (condition-service-capture
      (command-runtime-conditions service)
      (command-runtime-owner service)
      (list 'command-runtime message condition)
      (lambda arguments #f)
      '(dismiss)))

  (define (command-runtime-handle-message! service message)
    (unless (command-runtime? service)
      (assertion-violation 'command-runtime-handle-message! "expected a command runtime" service))
    (guard
      (condition
        [else
         (capture-runtime-condition! service message condition)
         #t])
      (cond
        [(command-invoke-message? message)
         (if (command-invoke-message-interactive? message)
             (command-runtime-start-interactive!
               service (command-invoke-message-name message)
               (command-invoke-message-context message)
               (command-invoke-message-arguments message))
             (command-runtime-start!
               service (command-invoke-message-name message)
               (command-invoke-message-context message)
               (command-invoke-message-arguments message)))
         #t]
        [(command-resume-message? message)
         (command-runtime-resume!
           service (command-resume-message-invocation-id message)
           (command-resume-message-value message))
         #t]
        [(command-cancel-message? message)
         (command-runtime-cancel!
           service (command-cancel-message-invocation-id message))
         #t]
        [else #f])))
)
