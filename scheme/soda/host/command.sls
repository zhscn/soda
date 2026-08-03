(library (soda host command)
  (export make-command-definition
          command-definition?
          command-definition-name
          command-definition-invoke
          command-definition-interaction-spec
          command-definition-owner
          make-command-registry
          command-registry?
          command-register!
          command-unregister!
          command-lookup
          make-command-context
          command-context?
          command-context-view-id
          command-context-buffer-id
          command-context-invocation-id
          command-context-surface-id
          command-context-window-id
          command-context-buffer-state
          command-context-view-state
          command-context-event
          command-context-key-sequence
          command-context-prefix-argument
          command-context-target
          command-context-source
          make-command-invocation
          command-invocation?
          command-invocation-id
          command-invocation-definition
          command-invocation-context
          command-invocation-arguments
          command-invocation-phase
          command-invocation-result
          command-invocation-start!
          command-invocation-suspend!
          command-invocation-resume!
          command-invocation-cancel!
          command-invoke)
  (import (rnrs)
          (soda host value)
          (soda kernel value))

  (define-record-type
    (command-definition %make-command-definition command-definition?)
    (fields
      (immutable name command-definition-name)
      (immutable invoke command-definition-invoke)
      (immutable interaction-spec command-definition-interaction-spec)
      (immutable owner command-definition-owner)))

  (define (make-command-definition name invoke owner . interaction-spec)
    (owner-assert-active 'make-command-definition owner)
    (unless (and (symbol? name) (procedure? invoke))
      (assertion-violation 'make-command-definition "invalid command definition" name))
    (%make-command-definition
      name invoke (if (null? interaction-spec) #f (car interaction-spec)) owner))

  (define-record-type
    (command-registry %make-command-registry command-registry?)
    (fields (immutable table command-registry-table)))

  (define (make-command-registry)
    (%make-command-registry (make-eq-hashtable)))

  (define (command-register! registry definition)
    (unless (and (command-registry? registry) (command-definition? definition))
      (assertion-violation 'command-register! "invalid command registration" definition))
    (let ([name (command-definition-name definition)])
      (when (hashtable-contains? (command-registry-table registry) name)
        (assertion-violation 'command-register! "command is already registered" name))
      (hashtable-set! (command-registry-table registry) name definition)
      (make-registration
        (command-definition-owner definition)
        (lambda () (command-unregister! registry name)))))

  (define (command-unregister! registry name)
    (if (hashtable-contains? (command-registry-table registry) name)
        (begin (hashtable-delete! (command-registry-table registry) name) #t)
        #f))

  (define (command-lookup registry name . default)
    (if (hashtable-contains? (command-registry-table registry) name)
        (hashtable-ref (command-registry-table registry) name #f)
        (if (null? default) #f (car default))))

  (define-record-type
    (command-context %make-command-context command-context?)
    (fields
      (immutable view-id command-context-view-id)
      (immutable buffer-id command-context-buffer-id)
      (immutable invocation-id command-context-invocation-id)
      (immutable surface-id command-context-surface-id)
      (immutable window-id command-context-window-id)
      (immutable buffer-state command-context-buffer-state)
      (immutable view-state command-context-view-state)
      (immutable event command-context-event)
      (immutable key-sequence command-context-key-sequence)
      (immutable prefix-argument command-context-prefix-argument)
      (immutable target command-context-target)
      (immutable source command-context-source)))

  (define make-command-context
    (case-lambda
      [(view-id buffer-id source)
       (%make-command-context
         view-id buffer-id #f #f #f #f #f #f '() #f #f source)]
      [(invocation-id surface-id window-id view-id buffer-id buffer-state view-state event
                      key-sequence prefix-argument target source)
       (%make-command-context
         view-id buffer-id invocation-id surface-id window-id buffer-state view-state event
         (if (list? key-sequence) key-sequence '()) prefix-argument target source)]))

  (define invocation-identities (make-identity-source))

  (define-record-type
    (command-invocation %make-command-invocation command-invocation?)
    (fields
      (immutable id command-invocation-id)
      (immutable definition command-invocation-definition)
      (immutable context command-invocation-context)
      (immutable arguments command-invocation-arguments)
      (mutable phase command-invocation-phase command-invocation-phase-set!)
      (mutable result command-invocation-result command-invocation-result-set!)))

  (define (make-command-invocation definition context arguments)
    (unless (and (command-definition? definition) (command-context? context))
      (assertion-violation
        'make-command-invocation "invalid command definition or context"))
    (%make-command-invocation
      (identity-source-next! invocation-identities)
      definition context (if (list? arguments) arguments (list arguments))
      'resolving #f))

  (define (command-invocation-start! invocation)
    (unless (command-invocation? invocation)
      (assertion-violation 'command-invocation-start! "expected an invocation" invocation))
    (unless (eq? (command-invocation-phase invocation) 'resolving)
      (assertion-violation 'command-invocation-start! "invocation is not pending" invocation))
    (command-invocation-phase-set! invocation 'executing)
    (guard
      (condition
        [else
         (command-invocation-phase-set! invocation 'cancelled)
         (raise condition)])
      (let ([result
              (command-invoke
                (command-invocation-definition invocation)
                (command-invocation-context invocation)
                (command-invocation-arguments invocation))])
        (command-invocation-result-set! invocation result)
        (command-invocation-phase-set! invocation 'completed)
        result)))

  (define (command-invocation-resume! invocation result)
    (unless (command-invocation? invocation)
      (assertion-violation 'command-invocation-resume! "expected an invocation" invocation))
    (unless (memq (command-invocation-phase invocation) '(reading suspended))
      (assertion-violation 'command-invocation-resume! "invocation is not suspended" invocation))
    (command-invocation-result-set! invocation result)
    (command-invocation-phase-set! invocation 'completed)
    result)

  (define (command-invocation-suspend! invocation)
    (unless (command-invocation? invocation)
      (assertion-violation 'command-invocation-suspend! "expected an invocation" invocation))
    (unless (eq? (command-invocation-phase invocation) 'executing)
      (assertion-violation 'command-invocation-suspend! "invocation is not executing" invocation))
    (command-invocation-phase-set! invocation 'suspended)
    invocation)

  (define (command-invocation-cancel! invocation)
    (unless (command-invocation? invocation)
      (assertion-violation 'command-invocation-cancel! "expected an invocation" invocation))
    (command-invocation-phase-set! invocation 'cancelled)
    #t)

  (define (command-invoke definition context arguments)
    (unless (and (command-definition? definition) (command-context? context))
      (assertion-violation 'command-invoke "invalid command invocation" definition context))
    (apply (command-definition-invoke definition) context arguments))
)
