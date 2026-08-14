(library (soda host command-runtime internal)
  (export make-command-runtime
          command-runtime?
          command-runtime-register-command!
          command-runtime-command-definition
          command-runtime-command-names
          command-runtime-command-definitions
          command-runtime-command-available?
          command-runtime-available-command-names
          command-runtime-available-command-definitions
          command-runtime-available-user-command-definitions
          command-runtime-command-interactive?
          command-runtime-start!
          command-runtime-start-interactive!
          command-runtime-resume!
          command-runtime-cancel!
          command-runtime-invocation
          command-runtime-loop-state
          command-runtime-execution-history
          command-runtime-repeat-last!
          command-runtime-take-transient-state!
          command-runtime-forget-surface!
          command-runtime-set-repeat-state!
          command-runtime-set-interaction-handler!
          command-runtime-register-effect-handler!
          command-runtime-add-hook!
          command-runtime-add-advice!
          command-runtime-enqueue!
          command-runtime-enqueue-background!
          command-runtime-handle-message!)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host command-message)
          (soda host input)
          (soda host condition)
          (soda host dispatch-transaction)
          (soda host dispatch-core)
          (soda host dispatch-operation)
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
      (immutable loop-states command-runtime-loop-states)
      (immutable pending-transients command-runtime-pending-transients)
      (mutable repeat-state command-runtime-repeat-state
               command-runtime-repeat-state-set!)
      (mutable repeat-registration command-runtime-repeat-registration
               command-runtime-repeat-registration-set!)
      (mutable execution-history command-runtime-execution-history-table
               command-runtime-execution-history-table-set!)
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
      (make-eq-hashtable) (make-hashtable equal-hash equal?)
      (make-hashtable equal-hash equal?) #f #f '()
      #f #f 0))

  ;; Command definitions are registered through their runtime, so a package
  ;; never needs access to the mutable CommandRegistry implementation.
  (define (command-runtime-register-command! service definition)
    (unless (and (command-runtime? service) (command-definition? definition))
      (assertion-violation 'command-runtime-register-command!
                           "expected a command runtime and definition"
                           service definition))
    (command-register! (command-runtime-registry service) definition))

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

  (define (context-major-mode context)
    (let ([state (command-context-buffer-state context)])
      (and state
           (configuration-facet
             (buffer-state-configuration state) buffer-mode-facet 'buffer))))

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

  ;; The command registry also contains effect continuations and frontend
  ;; adapters. They are executable runtime entries, but not user commands.
  ;; Command palettes and describe readers must use this projection rather
  ;; than exposing argument-only implementation commands through M-x.
  (define (command-runtime-available-user-command-definitions service context)
    (filter command-definition-user-visible?
            (command-runtime-available-command-definitions service context)))

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
                 (memq phase '(pre-command before-outcomes post-command execution-record
                               command-error command-cancel)))
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

  (define (normalize-prefix-argument value)
    (if (prefix-argument? value) value (make-prefix-argument value)))

  (define (loop-key context)
    (or (command-context-surface-id context)
        (list 'source (command-context-source context))))

  (define (command-runtime-loop-state service context)
    (unless (and (command-runtime? service) (command-context? context))
      (assertion-violation 'command-runtime-loop-state
                           "expected a runtime and command context"))
    (hashtable-ref (command-runtime-loop-states service) (loop-key context)
                   (make-command-loop-state)))

  (define (command-runtime-execution-history service)
    (unless (command-runtime? service)
      (assertion-violation 'command-runtime-execution-history
                           "expected a command runtime" service))
    (list-copy (command-runtime-execution-history-table service)))

  (define (command-runtime-take-transient-state! service surface-id)
    (unless (and (command-runtime? service)
                 (or (not surface-id)
                     (and (integer? surface-id) (exact? surface-id)
                          (>= surface-id 0))))
      (assertion-violation 'command-runtime-take-transient-state!
                           "expected a runtime and Surface id or #f"))
    (let* ([key (or surface-id '(source #f))]
           [value (hashtable-ref (command-runtime-pending-transients service) key #f)])
      (when value
        (hashtable-delete! (command-runtime-pending-transients service) key))
      value))

  (define (command-runtime-forget-surface! service surface-id)
    (unless (and (command-runtime? service)
                 (integer? surface-id) (exact? surface-id) (>= surface-id 0))
      (assertion-violation 'command-runtime-forget-surface!
                           "expected a runtime and Surface id"))
    (hashtable-delete! (command-runtime-loop-states service) surface-id)
    (hashtable-delete! (command-runtime-pending-transients service) surface-id)
    #t)

  (define (command-runtime-set-repeat-state! service owner state)
    (unless (and (command-runtime? service) (owner? owner) (input-state? state))
      (assertion-violation 'command-runtime-set-repeat-state!
                           "expected a runtime, Owner, and InputState"))
    (owner-assert-active 'command-runtime-set-repeat-state! owner)
    (let ([current (command-runtime-repeat-registration service)])
      (when current (registration-close! current)))
    (let ([registration
           (make-registration
             owner
             (lambda ()
               (when (eq? (command-runtime-repeat-state service) state)
                 (command-runtime-repeat-state-set! service #f)
                 (command-runtime-repeat-registration-set! service #f))))])
      (command-runtime-repeat-state-set! service state)
      (command-runtime-repeat-registration-set! service registration)
      registration))

  (define (take-records items count)
    (if (or (zero? count) (null? items))
        '()
        (cons (car items) (take-records (cdr items) (- count 1)))))

  (define (transaction-with-command-metadata spec invocation transition)
    (let* ([identity (command-invocation-identity invocation)]
           [metadata
            (list
              (make-annotation 'command.invocation-id
                               (command-invocation-id invocation))
              (make-annotation 'command.semantic
                               (or (command-loop-transition-semantic-command transition)
                                   (command-identity-semantic identity)))
              (make-annotation 'command.undo-policy
                               (command-loop-transition-undo-policy transition)))])
      (make-transaction-spec
        (transaction-spec-buffer-id spec)
        (transaction-spec-origin-view-id spec)
        (transaction-spec-start-generation spec)
        (transaction-spec-changes spec)
        (transaction-spec-selection spec)
        (transaction-spec-effects spec)
        (append (transaction-spec-annotations spec) metadata)
        (transaction-spec-scroll-request spec)
        (transaction-spec-sequential? spec))))

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
      (let* ([result
              (fold-left
                (lambda (current entry)
                  (if (eq? (runtime-advice-where entry) 'filter-return)
                      (normalize-command-result
                        ((runtime-advice-procedure entry) context filtered-arguments current))
                      current))
                (normalize-command-result (invoke context filtered-arguments))
                advice)]
             [resolved
              (make-command-result
                (command-result-outcomes result)
                (command-loop-transition-resolve
                  (command-result-transition result)
                  (command-definition-policy definition)
                  (command-definition-name definition)))])
        (for-each
          (lambda (entry)
            (when (eq? (runtime-advice-where entry) 'after)
              ((runtime-advice-procedure entry) context filtered-arguments resolved)))
          (reverse advice))
        resolved)))

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

  (define (apply-outcome! service invocation transition outcome)
    (cond
      [(command-handled? outcome) #t]
      [(transaction-spec? outcome)
       (dispatcher-dispatch!
         (command-runtime-dispatcher service)
         (transaction-with-command-metadata outcome invocation transition))]
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
        (lambda (outcome)
          (apply-outcome! service invocation
                          (command-result-transition normalized) outcome))
        (command-result-outcomes normalized))
      normalized))

  (define (run-hooks! service phase . arguments)
    (for-each
      (lambda (entry)
        (apply (runtime-hook-procedure entry) arguments))
      (hooks-for service phase)))

  (define (record-terminal-invocation! service invocation outcome result transition)
    (let* ([context (command-invocation-context invocation)]
           [key (loop-key context)]
           [previous (command-runtime-loop-state service context)]
           [prefix (normalize-prefix-argument
                     (command-context-prefix-argument context))]
           [identity (command-invocation-identity invocation)]
           [semantic (or (command-loop-transition-semantic-command transition)
                         (command-identity-effective identity))]
           [final-identity
            (make-command-identity
              (command-identity-requested identity)
              (command-identity-effective identity)
              semantic)]
           [record
            (make-command-execution-record
              (command-invocation-id invocation) final-identity context
              (command-invocation-arguments invocation) prefix
              (command-context-source context) (command-context-key-sequence context)
              outcome result transition)]
           [completed? (eq? outcome 'completed)]
           [repeat-record
            (if (and completed? (command-loop-transition-repeatable? transition))
                record (command-loop-state-repeat-record previous))]
           [next-prefix
            (if (and completed?
                     (command-loop-transition-preserve-prefix? transition))
                prefix (make-prefix-argument))])
      (let ([transient
             (or (command-loop-transition-transient-state transition)
                 (and (command-loop-transition-repeatable? transition)
                      (command-runtime-repeat-state service)))])
        (when (and completed? transient)
          (unless (input-state? transient)
            (assertion-violation 'command-runtime
                                 "command transient state must be an InputState"
                                 transient))
          (hashtable-set!
            (command-runtime-pending-transients service) key transient)))
      (command-invocation-set-identity! invocation final-identity)
      (hashtable-set!
        (command-runtime-loop-states service) key
        (make-command-loop-state
          #f
          (if completed? final-identity (command-loop-state-last previous))
          next-prefix
          (if completed? prefix (command-loop-state-last-prefix previous))
          (if completed? record (command-loop-state-last-record previous))
          repeat-record))
      (command-runtime-execution-history-table-set!
        service
        (let ([items (cons record
                          (command-runtime-execution-history-table service))])
          (if (> (length items) 256) (take-records items 256) items)))
      ;; Execution records are committed observations.  A diagnostic or
      ;; recorder must not retroactively turn a completed command into an
      ;; error, nor recurse while an error record is being published.
      (guard (ignored [else #f])
        (run-hooks! service 'execution-record record))
      record))

  (define (invoke-definition! service invocation definition context arguments)
    (let* ([key (loop-key context)]
           [previous (command-runtime-loop-state service context)]
           [prefix (normalize-prefix-argument
                     (command-context-prefix-argument context))]
           [identity (command-invocation-identity invocation)])
      (hashtable-set!
        (command-runtime-loop-states service) key
        (make-command-loop-state identity
                                 (command-loop-state-last previous)
                                 prefix
                                 (command-loop-state-last-prefix previous)
                                 (command-loop-state-last-record previous)
                                 (command-loop-state-repeat-record previous)))
    (run-hooks! service 'pre-command invocation)
    (let ([result
           (invoke-with-advice service invocation definition context arguments)])
      ;; A resumed interactive command still owns its temporary prompt while
      ;; its procedure runs.  Give lifecycle owners a boundary to retire that
      ;; presentation before command outcomes publish feedback or effects to
      ;; the initiating editing context.
      (run-hooks! service 'before-outcomes invocation result)
      (let ([applied-result (apply-result! service invocation result)])
        (run-hooks! service 'post-command invocation applied-result)
        (record-terminal-invocation!
          service invocation 'completed applied-result
          (command-result-transition applied-result))
        applied-result))))

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
      (record-terminal-invocation!
        service invocation 'error entry (make-command-loop-transition #f #f 'ignore))
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

  (define (start! service name context interactive? arguments . requested-names)
    (unless (and (command-runtime? service) (command-context? context) (list? arguments))
      (assertion-violation 'command-runtime-start! "invalid command start" name context arguments))
    (let* ([definition (lookup-definition service name)]
           [_available
            (when (and (eq? (command-definition-scope definition) 'mode)
                       (not (command-runtime-command-available?
                              service definition context)))
              (assertion-violation 'command-runtime-start!
                                   "command is unavailable in the active context"
                                   name
                                   (let ([mode (context-major-mode context)])
                                     (and mode (mode-spec-id mode)))))]
           [invocation
             (if (and interactive? (command-definition-interactive? definition))
                 (make-interactive-command-invocation definition context arguments)
                 (make-command-invocation definition context arguments))])
      (command-invocation-set-identity!
        invocation
        (make-command-identity
          (if (null? requested-names) name (car requested-names)) name name))
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

  (define (context-with-prefix context prefix source)
    (make-command-context
      (command-context-invocation-id context)
      (command-context-surface-id context)
      (command-context-window-id context)
      (command-context-view-id context)
      (command-context-buffer-id context)
      (command-context-buffer-state context)
      (command-context-view-state context)
      (command-context-event context)
      (command-context-key-sequence context)
      prefix (command-context-target context) source
      (command-context-layout context)
      (command-context-input-layers context)))

  (define (command-runtime-repeat-last! service context)
    (unless (and (command-runtime? service) (command-context? context))
      (assertion-violation 'command-runtime-repeat-last!
                           "expected a runtime and current command context"))
    (let ([record
           (command-loop-state-repeat-record
             (command-runtime-loop-state service context))])
      (and record
           (let* ([identity (command-execution-record-identity record)]
                  [repeat-context
                   (context-with-prefix
                     context (command-execution-record-prefix-argument record)
                     'repeat)])
             (command-runtime-enqueue!
               service
               (make-command-invoke-message
                 (command-identity-effective identity)
                 repeat-context
                 (command-execution-record-arguments record)
                 #f
                 (command-identity-requested identity)))))))

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
               (record-terminal-invocation!
                 service invocation 'cancelled #f
                 (make-command-loop-transition #f #f 'ignore))
               (guard (ignored [else #f])
                 (run-hooks! service 'command-cancel invocation))
               (retire-invocation! service invocation))
             cancelled?))))

  (define (command-runtime-enqueue! service message)
    (unless (and (command-runtime? service)
                 (or (command-invoke-message? message)
                     (command-resume-message? message)
                     (command-cancel-message? message)))
      (assertion-violation 'command-runtime-enqueue! "invalid command message" message))
    (runtime-enqueue-priority! (command-runtime-queue service) message))

  ;; Native completion callbacks run outside the active input action.  Their
  ;; commands remain FIFO behind already queued editor work, preserving stream
  ;; order for output and preventing completion from preempting a key event.
  (define (command-runtime-enqueue-background! service message)
    (unless (and (command-runtime? service)
                 (or (command-invoke-message? message)
                     (command-resume-message? message)
                     (command-cancel-message? message)))
      (assertion-violation 'command-runtime-enqueue-background!
                           "invalid command message" message))
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
             (start!
               service (command-invoke-message-name message)
               (command-invoke-message-context message)
               #t (command-invoke-message-arguments message)
               (command-invoke-message-requested-name message))
             (start!
               service (command-invoke-message-name message)
               (command-invoke-message-context message)
               #f (command-invoke-message-arguments message)
               (command-invoke-message-requested-name message)))
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
