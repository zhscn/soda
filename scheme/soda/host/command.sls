(library (soda host command)
  (export make-command-definition
          command-definition?
          command-definition-name
          command-definition-invoke
          command-definition-documentation
          command-definition-class
          command-definition-scope
          command-definition-interaction-spec
          command-definition-policy
          command-definition-interactive?
          command-definition-user-visible?
          command-definition-owner
          make-command-registry
          command-registry?
          command-register!
          command-unregister!
          command-lookup
          command-names
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
          command-context-layout
          make-command-policy
          command-policy?
          command-policy-semantic-command
          command-policy-repeatable?
          command-policy-undo-policy
          command-policy-preserve-prefix?
          command-policy-transient-state
          make-prefix-argument
          prefix-argument?
          prefix-argument-raw-value
          prefix-argument-numeric-value
          prefix-argument-present?
          make-command-identity
          command-identity?
          command-identity-requested
          command-identity-effective
          command-identity-semantic
          make-command-loop-state
          command-loop-state?
          command-loop-state-current
          command-loop-state-last
          command-loop-state-current-prefix
          command-loop-state-last-prefix
          command-loop-state-last-record
          command-loop-state-repeat-record
          make-command-loop-transition
          command-loop-transition?
          command-loop-transition-semantic-command
          command-loop-transition-repeatable?
          command-loop-transition-undo-policy
          command-loop-transition-preserve-prefix?
          command-loop-transition-transient-state
          command-loop-transition-resolve
          make-command-execution-record
          command-execution-record?
          command-execution-record-invocation-id
          command-execution-record-identity
          command-execution-record-context
          command-execution-record-arguments
          command-execution-record-prefix-argument
          command-execution-record-source
          command-execution-record-key-sequence
          command-execution-record-outcome
          command-execution-record-result
          command-execution-record-transition
          make-interactive-reader
          interactive-reader?
          interactive-reader-name
          interactive-reader-resolver
          make-interactive-plan
          interactive-plan?
          interactive-plan-readers
          make-interactive-ready
          interactive-ready?
          interactive-ready-values
          make-interactive-suspend
          interactive-suspend?
          interactive-suspend-request
          interactive-suspend-decoder
          make-command-result
          command-result?
          command-result-outcomes
          command-result-transition
          command-result-with-transition
          command-handled
          command-handled?
          make-command-effect
          command-effect?
          command-effect-kind
          command-effect-payload
          make-command-invocation
          make-interactive-command-invocation
          command-invocation?
          command-invocation-id
          command-invocation-definition
          command-invocation-identity
          command-invocation-set-identity!
          command-invocation-context
          command-invocation-remaining-readers
          command-invocation-arguments
          command-invocation-phase
          command-invocation-suspension
          command-invocation-result
          command-invocation-condition
          command-invocation-step!
          command-invocation-start!
          command-invocation-resume!
          command-invocation-cancel!
          command-invocation-record-condition!
          command-invoke)
  (import (rnrs)
          (soda host value)
          (soda kernel value))

  ;; Command declarations are package data.  They intentionally do not know
  ;; about a terminal, a minibuffer, or a Dispatcher: a command implementation
  ;; receives a stable context and explicit arguments, then returns a result
  ;; value for CommandRuntime to realize.
  (define-record-type
    (command-definition %make-command-definition command-definition?)
    (fields
      (immutable name command-definition-name)
      (immutable invoke command-definition-invoke)
      (immutable documentation command-definition-documentation)
      (immutable class command-definition-class)
      (immutable scope command-definition-scope)
      (immutable interaction-spec command-definition-interaction-spec)
      (immutable policy command-definition-policy)
      (immutable user-visible? command-definition-user-visible?)
      (immutable owner command-definition-owner)))

  ;; The short forms preserve the original public constructor.  The complete
  ;; form gives user packages metadata without making the registry depend on a
  ;; particular command or minibuffer package.
  (define make-command-definition
    (case-lambda
      [(name invoke owner)
       (make-command-definition name invoke owner #f #f #f)]
      [(name invoke owner interaction-spec)
       (make-command-definition name invoke owner #f #f interaction-spec)]
      [(name invoke owner documentation class interaction-spec)
       (make-command-definition
         name invoke owner documentation class interaction-spec 'global)]
      [(name invoke owner documentation class interaction-spec scope)
       (make-command-definition
         name invoke owner documentation class interaction-spec scope
         (make-command-policy) #t)]
      [(name invoke owner documentation class interaction-spec scope policy)
       (make-command-definition
         name invoke owner documentation class interaction-spec scope policy #t)]
      [(name invoke owner documentation class interaction-spec scope policy user-visible?)
       (owner-assert-active 'make-command-definition owner)
       (unless (and (symbol? name) (procedure? invoke)
                    (or (not documentation) (string? documentation))
                    (or (not class) (symbol? class))
                    (memq scope '(global mode))
                    (command-policy? policy)
                    (boolean? user-visible?))
         (assertion-violation 'make-command-definition "invalid command definition"
                              name invoke documentation class scope))
       (%make-command-definition
         name invoke documentation class scope interaction-spec policy user-visible? owner)]))

  (define (command-definition-interactive? definition)
    (unless (command-definition? definition)
      (assertion-violation 'command-definition-interactive?
                           "expected a command definition" definition))
    (interactive-plan? (command-definition-interaction-spec definition)))

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

  (define (command-names registry)
    (unless (command-registry? registry)
      (assertion-violation 'command-names "expected a command registry" registry))
    (vector->list (hashtable-keys (command-registry-table registry))))

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
      (immutable source command-context-source)
      ;; A frontend may attach the immutable TextLayout that it last
      ;; presented for this View.  Command packages treat it as an optional
      ;; read-only measurement; headless callers use #f and retain logical
      ;; motion semantics.
      (immutable layout command-context-layout)))

  (define make-command-context
    (case-lambda
      [(view-id buffer-id source)
       (%make-command-context
         view-id buffer-id #f #f #f #f #f #f '() #f #f source #f)]
      [(invocation-id surface-id window-id view-id buffer-id buffer-state view-state event
                      key-sequence prefix-argument target source)
       (%make-command-context
         view-id buffer-id invocation-id surface-id window-id buffer-state view-state event
         (if (list? key-sequence) (list-copy key-sequence) '())
         prefix-argument target source #f)]
      [(invocation-id surface-id window-id view-id buffer-id buffer-state view-state event
                      key-sequence prefix-argument target source layout)
       (%make-command-context
         view-id buffer-id invocation-id surface-id window-id buffer-state view-state event
         (if (list? key-sequence) (list-copy key-sequence) '())
         prefix-argument target source layout)]))

  ;; PrefixArgument retains the raw input form while giving commands one
  ;; stable numeric interpretation.  #f at old API boundaries is normalized
  ;; by the runtime to prefix-argument-absent.
  (define-record-type
    (prefix-argument %make-prefix-argument prefix-argument?)
    (fields
      (immutable raw-value prefix-argument-raw-value)
      (immutable numeric-value prefix-argument-numeric-value)))

  (define make-prefix-argument
    (case-lambda
      [() (%make-prefix-argument #f 1)]
      [(raw)
       (%make-prefix-argument raw
         (cond [(and (integer? raw) (exact? raw)) raw]
               [(eq? raw 'universal) 4]
               [(not raw) 1]
               [else
                (assertion-violation 'make-prefix-argument
                                     "raw prefix has no numeric interpretation" raw)]))]
      [(raw numeric)
       (unless (and (integer? numeric) (exact? numeric))
         (assertion-violation 'make-prefix-argument
                              "numeric prefix must be an exact integer" numeric))
       (%make-prefix-argument raw numeric)]))

  (define (prefix-argument-present? value)
    (and (prefix-argument? value) (prefix-argument-raw-value value) #t))

  ;; CommandPolicy is declaration-time behavior shared by every invocation.
  ;; A semantic command of #f means that the effective command name is used.
  (define-record-type
    (command-policy %make-command-policy command-policy?)
    (fields
      (immutable semantic-command command-policy-semantic-command)
      (immutable repeatable? command-policy-repeatable?)
      (immutable undo-policy command-policy-undo-policy)
      (immutable preserve-prefix? command-policy-preserve-prefix?)
      (immutable transient-state command-policy-transient-state)))

  (define make-command-policy
    (case-lambda
      [() (%make-command-policy #f #f 'boundary #f #f)]
      [(semantic repeatable? undo-policy preserve-prefix? transient-state)
       (unless (and (or (not semantic) (symbol? semantic))
                    (memq undo-policy '(boundary amalgamate ignore)))
         (assertion-violation 'make-command-policy "invalid command policy"
                              semantic repeatable? undo-policy))
       (%make-command-policy semantic (and repeatable? #t) undo-policy
                             (and preserve-prefix? #t) transient-state)]))

  (define-record-type
    (command-identity %make-command-identity command-identity?)
    (fields
      (immutable requested command-identity-requested)
      (immutable effective command-identity-effective)
      (immutable semantic command-identity-semantic)))

  (define make-command-identity
    (case-lambda
      [(name) (make-command-identity name name name)]
      [(requested effective) (make-command-identity requested effective effective)]
      [(requested effective semantic)
       (unless (and (symbol? requested) (symbol? effective) (symbol? semantic))
         (assertion-violation 'make-command-identity
                              "command identities must be symbols"
                              requested effective semantic))
       (%make-command-identity requested effective semantic)]))

  (define-record-type
    (command-loop-state %make-command-loop-state command-loop-state?)
    (fields
      (immutable current command-loop-state-current)
      (immutable last command-loop-state-last)
      (immutable current-prefix command-loop-state-current-prefix)
      (immutable last-prefix command-loop-state-last-prefix)
      (immutable last-record command-loop-state-last-record)
      (immutable repeat-record command-loop-state-repeat-record)))

  (define make-command-loop-state
    (case-lambda
      [() (%make-command-loop-state #f #f (make-prefix-argument)
                                   (make-prefix-argument) #f #f)]
      [(current last current-prefix last-prefix last-record repeat-record)
       (unless (and (or (not current) (command-identity? current))
                    (or (not last) (command-identity? last))
                    (prefix-argument? current-prefix)
                    (prefix-argument? last-prefix)
                    (or (not last-record) (command-execution-record? last-record))
                    (or (not repeat-record) (command-execution-record? repeat-record)))
         (assertion-violation 'make-command-loop-state "invalid command loop state"))
       (%make-command-loop-state current last current-prefix last-prefix
                                 last-record repeat-record)]))

  ;; CommandLoopTransition contains per-execution overrides.  The zero-argument
  ;; form inherits every field from CommandPolicy; the established complete
  ;; constructors remain explicit overrides.
  (define-record-type
    (command-loop-transition %make-command-loop-transition command-loop-transition?)
    (fields
      (immutable semantic-command command-loop-transition-semantic-command)
      (immutable repeatable? command-loop-transition-repeatable?)
      (immutable undo-policy command-loop-transition-undo-policy)
      (immutable preserve-prefix? command-loop-transition-preserve-prefix?)
      (immutable transient-state command-loop-transition-transient-state)))

  (define make-command-loop-transition
    (case-lambda
      [() (%make-command-loop-transition 'inherit 'inherit 'inherit 'inherit 'inherit)]
      [(semantic repeatable? undo-policy)
       (make-command-loop-transition semantic repeatable? undo-policy #f #f)]
      [(semantic repeatable? undo-policy preserve-prefix? transient-state)
       (unless (and (or (not semantic) (symbol? semantic))
                    (memq undo-policy '(boundary amalgamate ignore)))
         (assertion-violation 'make-command-loop-transition
                              "invalid command loop transition"
                              semantic repeatable? undo-policy))
       (%make-command-loop-transition semantic (and repeatable? #t) undo-policy
                                      (and preserve-prefix? #t) transient-state)]))

  (define (command-loop-transition-resolve transition policy effective-command)
    (unless (and (command-loop-transition? transition) (command-policy? policy)
                 (symbol? effective-command))
      (assertion-violation 'command-loop-transition-resolve
                           "invalid transition resolution input"))
    (let ([resolved (lambda (value fallback)
                      (if (eq? value 'inherit) fallback value))])
      (%make-command-loop-transition
        (let ([semantic
               (resolved (command-loop-transition-semantic-command transition)
                         (command-policy-semantic-command policy))])
          (or semantic effective-command))
        (resolved (command-loop-transition-repeatable? transition)
                  (command-policy-repeatable? policy))
        (resolved (command-loop-transition-undo-policy transition)
                  (command-policy-undo-policy policy))
        (resolved (command-loop-transition-preserve-prefix? transition)
                  (command-policy-preserve-prefix? policy))
        (resolved (command-loop-transition-transient-state transition)
                  (command-policy-transient-state policy)))))

  (define-record-type
    (command-execution-record %make-command-execution-record command-execution-record?)
    (fields
      (immutable invocation-id command-execution-record-invocation-id)
      (immutable identity command-execution-record-identity)
      (immutable context command-execution-record-context)
      (immutable arguments command-execution-record-arguments)
      (immutable prefix-argument command-execution-record-prefix-argument)
      (immutable source command-execution-record-source)
      (immutable key-sequence command-execution-record-key-sequence)
      (immutable outcome command-execution-record-outcome)
      (immutable result command-execution-record-result)
      (immutable transition command-execution-record-transition)))

  (define (make-command-execution-record invocation-id identity context arguments prefix
                                         source keys outcome result transition)
    (unless (and (integer? invocation-id) (exact? invocation-id) (>= invocation-id 0)
                 (command-identity? identity) (command-context? context) (list? arguments)
                 (prefix-argument? prefix) (symbol? outcome)
                 (command-loop-transition? transition))
      (assertion-violation 'make-command-execution-record
                           "invalid command execution record"))
    (%make-command-execution-record invocation-id identity context (list-copy arguments)
                                    prefix source (if (list? keys) (list-copy keys) '())
                                    outcome result transition))

  ;; Interactive readers are the only suspension protocol CommandRuntime
  ;; understands.  A reader returns ready values synchronously, or a request
  ;; and decoder.  The interaction package owns presentation and resumes the
  ;; same invocation later; no recursive minibuffer call is retained here.
  (define-record-type
    (interactive-reader %make-interactive-reader interactive-reader?)
    (fields
      (immutable name interactive-reader-name)
      (immutable resolver interactive-reader-resolver)))

  (define (make-interactive-reader name resolver)
    (unless (and (symbol? name) (procedure? resolver))
      (assertion-violation 'make-interactive-reader "invalid interactive reader" name resolver))
    (%make-interactive-reader name resolver))

  (define-record-type
    (interactive-plan %make-interactive-plan interactive-plan?)
    (fields (immutable readers interactive-plan-readers)))

  (define (make-interactive-plan readers)
    (unless (and (list? readers) (for-all interactive-reader? readers))
      (assertion-violation 'make-interactive-plan "expected interactive readers" readers))
    (%make-interactive-plan (list-copy readers)))

  (define-record-type
    (interactive-ready %make-interactive-ready interactive-ready?)
    (fields (immutable values interactive-ready-values)))

  (define (make-interactive-ready values)
    (unless (list? values)
      (assertion-violation 'make-interactive-ready "values must be a list" values))
    (%make-interactive-ready (list-copy values)))

  (define-record-type
    (interactive-suspend %make-interactive-suspend interactive-suspend?)
    (fields
      (immutable request interactive-suspend-request)
      (immutable decoder interactive-suspend-decoder)))

  (define (make-interactive-suspend request decoder)
    (unless (procedure? decoder)
      (assertion-violation 'make-interactive-suspend "decoder must be a procedure" decoder))
    (%make-interactive-suspend request decoder))

  ;; Result values are deliberately small.  The runtime recognizes kernel
  ;; transaction specs and HostOperation values, while package-defined I/O
  ;; travels as CommandEffect and is handled through an explicit registration.
  (define-record-type
    (command-result %make-command-result command-result?)
    (fields (immutable outcomes command-result-outcomes)
            (immutable transition command-result-transition)))

  (define make-command-result
    (case-lambda
      [(outcomes) (make-command-result outcomes (make-command-loop-transition))]
      [(outcomes transition)
       (unless (and (list? outcomes) (command-loop-transition? transition))
         (assertion-violation 'make-command-result
                              "expected outcomes and a command loop transition"
                              outcomes transition))
       (%make-command-result (list-copy outcomes) transition)]))

  (define (command-result-with-transition value transition)
    (unless (command-loop-transition? transition)
      (assertion-violation 'command-result-with-transition
                           "expected a command loop transition" transition))
    (make-command-result
      (cond [(command-result? value) (command-result-outcomes value)]
            [(list? value) value]
            [else (list value)])
      transition))

  (define-record-type (handled-outcome %make-command-handled command-handled?) (fields))
  (define (command-handled) (%make-command-handled))

  (define-record-type
    (command-effect %make-command-effect command-effect?)
    (fields
      (immutable kind command-effect-kind)
      (immutable payload command-effect-payload)))

  (define (make-command-effect kind payload)
    (unless (symbol? kind)
      (assertion-violation 'make-command-effect "effect kind must be a symbol" kind))
    (%make-command-effect kind payload))

  (define invocation-identities (make-identity-source))

  (define-record-type
    (command-invocation %make-command-invocation command-invocation?)
    (fields
      (immutable id command-invocation-id)
      (immutable definition command-invocation-definition)
      (mutable identity command-invocation-identity command-invocation-identity-set!)
      (immutable context command-invocation-context)
      (mutable remaining-readers command-invocation-remaining-readers
                                 command-invocation-remaining-readers-set!)
      (mutable arguments command-invocation-arguments command-invocation-arguments-set!)
      (mutable phase command-invocation-phase command-invocation-phase-set!)
      (mutable suspension command-invocation-suspension command-invocation-suspension-set!)
      (mutable result command-invocation-result command-invocation-result-set!)
      (mutable condition command-invocation-condition command-invocation-condition-set!)))

  (define (make-command-invocation definition context arguments)
    (unless (and (command-definition? definition) (command-context? context) (list? arguments))
      (assertion-violation 'make-command-invocation "invalid command invocation"))
    (%make-command-invocation
      (identity-source-next! invocation-identities)
      definition (make-command-identity (command-definition-name definition))
      context '() (list-copy arguments) 'resolving #f #f #f))

  (define (command-invocation-set-identity! invocation identity)
    (unless (and (command-invocation? invocation) (command-identity? identity))
      (assertion-violation 'command-invocation-set-identity!
                           "expected an invocation and command identity"))
    (command-invocation-identity-set! invocation identity)
    identity)

  ;; An interactive invocation may carry explicit leading arguments.  This
  ;; lets a command started from a semantic BufferItem retain its immutable
  ;; target while ordinary InteractiveReaders collect the remaining values.
  (define make-interactive-command-invocation
    (case-lambda
      [(definition context)
       (make-interactive-command-invocation definition context '())]
      [(definition context arguments)
       (unless (and (command-definition? definition) (command-context? context)
                    (interactive-plan? (command-definition-interaction-spec definition))
                    (list? arguments))
         (assertion-violation 'make-interactive-command-invocation
                              "command has no interactive plan or invalid arguments"
                              definition))
       (%make-command-invocation
         (identity-source-next! invocation-identities)
         definition (make-command-identity (command-definition-name definition)) context
         (interactive-plan-readers (command-definition-interaction-spec definition))
         (list-copy arguments) 'resolving #f #f #f)]))

  (define (invocation-active? invocation)
    (memq (command-invocation-phase invocation) '(resolving reading executing)))

  (define (command-invocation-cancel! invocation)
    (unless (command-invocation? invocation)
      (assertion-violation 'command-invocation-cancel! "expected an invocation" invocation))
    (if (invocation-active? invocation)
        (begin
          (command-invocation-phase-set! invocation 'cancelled)
          (command-invocation-suspension-set! invocation #f)
          #t)
        #f))

  (define (command-invocation-record-condition! invocation condition)
    (unless (command-invocation? invocation)
      (assertion-violation 'command-invocation-record-condition!
                           "expected an invocation" invocation))
    (command-invocation-condition-set! invocation condition)
    condition)

  (define (command-invoke definition context arguments)
    (unless (and (command-definition? definition) (command-context? context) (list? arguments))
      (assertion-violation 'command-invoke "invalid command invocation" definition context))
    (apply (command-definition-invoke definition) context arguments))

  (define (invoke-invocation! invocation invoke)
    (command-invocation-phase-set! invocation 'executing)
    (guard
      (condition
        [else
         (command-invocation-phase-set! invocation 'cancelled)
         (raise condition)])
      (let ([result
              (invoke
                (command-invocation-definition invocation)
                (command-invocation-context invocation)
                (command-invocation-arguments invocation))])
        (command-invocation-result-set! invocation result)
        (command-invocation-phase-set! invocation 'completed)
        result)))

  (define (read-next! invocation invoke)
    (let loop ()
      (let ([readers (command-invocation-remaining-readers invocation)])
        (if (null? readers)
            (invoke-invocation! invocation invoke)
            (let* ([reader (car readers)]
                   [resolution
                     ((interactive-reader-resolver reader)
                      (command-invocation-context invocation)
                      (command-invocation-arguments invocation))])
              (cond
                [(interactive-ready? resolution)
                 (command-invocation-arguments-set!
                   invocation
                   (append (command-invocation-arguments invocation)
                           (interactive-ready-values resolution)))
                 (command-invocation-remaining-readers-set! invocation (cdr readers))
                 (loop)]
                [(interactive-suspend? resolution)
                 (command-invocation-phase-set! invocation 'reading)
                 (command-invocation-suspension-set! invocation resolution)
                 resolution]
                [else
                 (command-invocation-phase-set! invocation 'cancelled)
                 (assertion-violation 'command-invocation-step!
                                      "interactive reader returned an invalid result"
                                      (interactive-reader-name reader) resolution)]))))))

  ;; INVOKE is an internal seam used by CommandRuntime to apply advice.  The
  ;; default keeps direct Scheme invocation useful in unit tests and scripts.
  (define command-invocation-step!
    (case-lambda
      [(invocation)
       (command-invocation-step! invocation command-invoke)]
      [(invocation invoke)
       (unless (and (command-invocation? invocation) (procedure? invoke))
         (assertion-violation 'command-invocation-step! "invalid invocation or invoker"))
       (case (command-invocation-phase invocation)
         [(resolving) (read-next! invocation invoke)]
         [(reading)
          (assertion-violation 'command-invocation-step!
                               "invocation is waiting for an interaction result" invocation)]
         [else
          (assertion-violation 'command-invocation-step!
                               "invocation is not runnable" invocation)])]))

  (define command-invocation-start! command-invocation-step!)

  (define command-invocation-resume!
    (case-lambda
      [(invocation value)
       (command-invocation-resume! invocation value command-invoke)]
      [(invocation value invoke)
       (unless (and (command-invocation? invocation) (procedure? invoke))
         (assertion-violation 'command-invocation-resume! "invalid invocation or invoker"))
       (unless (eq? (command-invocation-phase invocation) 'reading)
         (assertion-violation 'command-invocation-resume! "invocation is not reading" invocation))
       (let* ([suspension (command-invocation-suspension invocation)]
              [decoded ((interactive-suspend-decoder suspension) value)])
         (unless (interactive-ready? decoded)
           (assertion-violation 'command-invocation-resume!
                                "interaction decoder must return InteractiveReady" decoded))
         (command-invocation-arguments-set!
           invocation
           (append (command-invocation-arguments invocation)
                   (interactive-ready-values decoded)))
         (command-invocation-remaining-readers-set!
           invocation (cdr (command-invocation-remaining-readers invocation)))
         (command-invocation-suspension-set! invocation #f)
         (command-invocation-phase-set! invocation 'resolving)
         (command-invocation-step! invocation invoke))])))
