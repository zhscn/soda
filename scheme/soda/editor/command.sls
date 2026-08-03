(library (soda editor command)
  (export make-command-registry
          command-registry?
          command-registry-snapshot
          command-registry-restore!
          register-command-definition!
          command-registered?
          command-interactive?
          command-names
          interactive-command-names
          command-procedure
          command-documentation
          command-class
          command-definition-ref
          make-command-definition
          make-interactive-context-command
          make-internal-context-command
          command-definition?
          command-definition-name
          command-definition-procedure
          command-definition-documentation
          command-definition-class
          command-definition-interactive-plan
          command-definition-modes
          attach-command-definition!
          procedure-command-definition
          define-command
          make-interactive-plan
          interactive-plan?
          interactive-plan-readers
          make-interactive-reader
          interactive-reader?
          interactive-reader-name
          interactive-reader-resolver
          make-interactive-ready
          interactive-ready?
          interactive-ready-values
          make-interactive-suspend
          interactive-suspend?
          interactive-suspend-request
          interactive-suspend-decoder
          make-command-invocation
          command-invocation?
          command-invocation-id
          command-invocation-definition
          command-invocation-context
          command-invocation-remaining-readers
          command-invocation-arguments
          command-invocation-state
          command-invocation-suspension
          command-invocation-set-remaining-readers!
          command-invocation-set-arguments!
          command-invocation-set-state!
          command-invocation-set-suspension!
          command-add-advice!
          command-remove-advice!
          command-advice-names
          add-command-hook!
          remove-command-hook!
          command-hooks
          execute-command!
          execute-command-definition!
          make-command-context
          command-context?
          command-context-editor
          command-context-view
          command-context-event
          command-context-argument
          command-context-prefix
          command-context-count
          command-context-non-negative-count
          make-command-effect
          command-effect?
          command-effect-kind
          command-effect-payload)
  (import (rnrs)
          (soda editor contract)
          (soda editor hashtable-state)
          (soda editor prefix))

  (define-record-type (command-registry %make-command-registry command-registry?)
    (fields entries hooks))

  (define-record-type
    (command-registry-state %make-command-registry-state command-registry-state?)
    (fields entries hooks))

  (define-record-type
    (command-context %make-command-context command-context?)
    (fields editor view event argument prefix))

  (define make-command-context
    (case-lambda
      [(editor view event argument)
       (%make-command-context editor view event argument #f)]
      [(editor view event argument prefix)
       (unless (or (not prefix) (prefix-argument? prefix))
         (assertion-violation
           'make-command-context
           "prefix must be a prefix argument or #f"
           prefix))
       (%make-command-context editor view event argument prefix)]))

  (define (command-context-count context)
    (unless (command-context? context)
      (assertion-violation
        'command-context-count
        "expected a command context"
        context))
    (let ([prefix (command-context-prefix context)])
      (if prefix (prefix-argument-value prefix) 1)))

  (define (command-context-non-negative-count who context)
    (let ([count (command-context-count context)])
      (when (negative? count)
        (assertion-violation
          who
          "command requires a non-negative prefix argument"
          count))
      count))

  (define-record-type command-effect
    (fields kind payload))

  (define-record-type
    (interactive-reader %make-interactive-reader interactive-reader?)
    (fields name resolver))

  (define-record-type
    (interactive-plan %make-interactive-plan interactive-plan?)
    (fields readers))

  (define-record-type
    (interactive-ready %make-interactive-ready interactive-ready?)
    (fields values))

  (define-record-type
    (interactive-suspend %make-interactive-suspend interactive-suspend?)
    (fields request decoder))

  (define-record-type
    (command-definition %make-command-definition command-definition?)
    (fields name
            procedure
            invoker
            documentation
            class
            interactive-plan
            modes))

  (define-record-type
    (command-invocation %make-command-invocation command-invocation?)
    (fields id
            definition
            context
            (mutable remaining-readers)
            (mutable arguments)
            (mutable state)
            (mutable suspension)))

  (define-record-type command-advice
    (fields name where procedure depth))

  (define-record-type
    (registered-command %make-registered-command registered-command?)
    (fields definition (mutable advice)))

  (define (clone-command-entries entries)
    (let ([copy (make-eq-hashtable)])
      (let-values ([(names commands) (hashtable-entries entries)])
        (let loop ([index 0])
          (unless (= index (vector-length names))
            (let ([command (vector-ref commands index)])
              (hashtable-set!
                copy
                (vector-ref names index)
                (%make-registered-command
                  (registered-command-definition command)
                  (registered-command-advice command))))
            (loop (+ index 1)))))
      copy))

  (define (command-registry-snapshot registry)
    (unless (command-registry? registry)
      (assertion-violation
        'command-registry-snapshot
        "expected a command registry"
        registry))
    (%make-command-registry-state
      (clone-command-entries (command-registry-entries registry))
      (hashtable-copy (command-registry-hooks registry) #t)))

  (define (command-registry-restore! registry snapshot)
    (unless (command-registry? registry)
      (assertion-violation
        'command-registry-restore!
        "expected a command registry"
        registry))
    (unless (command-registry-state? snapshot)
      (assertion-violation
        'command-registry-restore!
        "expected a command registry snapshot"
        snapshot))
    (replace-hashtable!
      (command-registry-entries registry)
      (clone-command-entries
        (command-registry-state-entries snapshot)))
    (replace-hashtable!
      (command-registry-hooks registry)
      (command-registry-state-hooks snapshot))
    registry)

  (define procedure-definitions (make-eq-hashtable))

  (define (make-interactive-reader name resolver)
    (unless (symbol? name)
      (assertion-violation
        'make-interactive-reader
        "reader name must be a symbol"
        name))
    (unless (procedure? resolver)
      (assertion-violation
        'make-interactive-reader
        "reader resolver must be a procedure"
        resolver))
    (%make-interactive-reader name resolver))

  (define (make-interactive-plan readers)
    (unless
      (and (list? readers) (for-all interactive-reader? readers))
      (assertion-violation
        'make-interactive-plan
        "readers must be a list of interactive readers"
        readers))
    (%make-interactive-plan readers))

  (define (make-interactive-ready values)
    (unless (list? values)
      (assertion-violation
        'make-interactive-ready
        "values must be a list"
        values))
    (%make-interactive-ready values))

  (define (make-interactive-suspend request decoder)
    (unless (procedure? decoder)
      (assertion-violation
        'make-interactive-suspend
        "decoder must be a procedure"
        decoder))
    (%make-interactive-suspend request decoder))

  (define (make-command-definition
            name
            procedure
            invoker
            documentation
            class
            interactive-plan
            modes)
    (unless (symbol? name)
      (assertion-violation
        'make-command-definition
        "command name must be a symbol"
        name))
    (unless (procedure? procedure)
      (assertion-violation
        'make-command-definition
        "command procedure must be a procedure"
        procedure))
    (unless (procedure? invoker)
      (assertion-violation
        'make-command-definition
        "command invoker must be a procedure"
        invoker))
    (unless (or (not documentation) (string? documentation))
      (assertion-violation
        'make-command-definition
        "documentation must be a string or #f"
        documentation))
    (unless (or (not class) (symbol? class))
      (assertion-violation
        'make-command-definition
        "command class must be a symbol or #f"
        class))
    (unless (or (not interactive-plan)
                (interactive-plan? interactive-plan))
      (assertion-violation
        'make-command-definition
        "interactive plan must be an interactive plan or #f"
        interactive-plan))
    (unless (and (list? modes) (for-all symbol? modes))
      (assertion-violation
        'make-command-definition
        "command modes must be a list of symbols"
        modes))
    (%make-command-definition
      name
      procedure
      invoker
      documentation
      class
      interactive-plan
      modes))

  (define (attach-command-definition! procedure definition)
    (unless (procedure? procedure)
      (assertion-violation
        'attach-command-definition!
        "expected a procedure"
        procedure))
    (unless (command-definition? definition)
      (assertion-violation
        'attach-command-definition!
        "expected a command definition"
        definition))
    (hashtable-set! procedure-definitions procedure definition)
    procedure)

  (define (procedure-command-definition procedure)
    (unless (procedure? procedure)
      (assertion-violation
        'procedure-command-definition
        "expected a procedure"
        procedure))
    (hashtable-ref procedure-definitions procedure #f))

  (define-syntax define-command
    (lambda (form)
      (syntax-case form (interactive)
        [(_ (name context argument ...)
            documentation
            (interactive reader ...)
            body ...)
         #'(define name
             (let ([implementation
                     (lambda (context argument ...)
                       body ...)])
               (attach-command-definition!
                 implementation
                 (make-command-definition
                   'name
                   implementation
                   (lambda (command-context arguments)
                     (apply
                       implementation
                       command-context
                       arguments))
                   documentation
                   #f
                   (make-interactive-plan
                     (list reader ...))
                   '()))
               implementation))]
        [(_ (name context argument ...)
            (interactive reader ...)
            body ...)
         #'(define-command
             (name context argument ...)
             #f
             (interactive reader ...)
             body ...)])))

  (define (make-command-invocation
            id
            definition
            context)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'make-command-invocation
        "invocation id must be a non-negative exact integer"
        id))
    (unless (command-definition? definition)
      (assertion-violation
        'make-command-invocation
        "expected a command definition"
        definition))
    (unless (command-context? context)
      (assertion-violation
        'make-command-invocation
        "expected a command context"
        context))
    (%make-command-invocation
      id
      definition
      context
      (interactive-plan-readers
        (command-definition-interactive-plan definition))
      '()
      'resolving
      #f))

  (define (command-invocation-set-remaining-readers! invocation readers)
    (unless (and
              (command-invocation? invocation)
              (list? readers)
              (for-all interactive-reader? readers))
      (assertion-violation
        'command-invocation-set-remaining-readers!
        "invalid invocation readers"
        invocation
        readers))
    (command-invocation-remaining-readers-set! invocation readers))

  (define (command-invocation-set-arguments! invocation arguments)
    (unless (and (command-invocation? invocation) (list? arguments))
      (assertion-violation
        'command-invocation-set-arguments!
        "invalid invocation arguments"
        invocation
        arguments))
    (command-invocation-arguments-set! invocation arguments))

  (define (command-invocation-set-state! invocation state)
    (unless (and
              (command-invocation? invocation)
              (memq state '(resolving suspended running finished aborted)))
      (assertion-violation
        'command-invocation-set-state!
        "invalid invocation state"
        invocation
        state))
    (command-invocation-state-set! invocation state))

  (define (command-invocation-set-suspension! invocation suspension)
    (unless (and
              (command-invocation? invocation)
              (or (not suspension)
                  (interactive-suspend? suspension)))
      (assertion-violation
        'command-invocation-set-suspension!
        "invalid invocation suspension"
        invocation
        suspension))
    (command-invocation-suspension-set! invocation suspension))

  (define (make-command-registry)
    (%make-command-registry
      (make-eq-hashtable)
      (make-eq-hashtable)))

  (define (require-registry who value)
    (unless (command-registry? value)
      (assertion-violation who "expected a command registry" value)))

  (define (definition-with-registration-metadata
            definition
            name
            documentation
            class)
    (make-command-definition
      name
      (command-definition-procedure definition)
      (command-definition-invoker definition)
      (or documentation
          (command-definition-documentation definition))
      (or class (command-definition-class definition))
      (command-definition-interactive-plan definition)
      (command-definition-modes definition)))

  (define (make-context-command
            name
            procedure
            documentation
            class
            interactive?)
    (unless (procedure? procedure)
      (assertion-violation
        'make-context-command
        "command implementation must be a procedure"
        procedure))
    (let ([attached (procedure-command-definition procedure)])
      (if attached
          (let ([definition
                  (definition-with-registration-metadata
                    attached name documentation class)])
            (if interactive?
                definition
                (make-command-definition
                  name
                  (command-definition-procedure definition)
                  (lambda (context arguments)
                    (unless (null? arguments)
                      (assertion-violation
                        name
                        "internal context command does not accept resolved arguments"
                        arguments))
                    (procedure context))
                  (command-definition-documentation definition)
                  (command-definition-class definition)
                  #f
                  (command-definition-modes definition))))
          (make-command-definition
            name
            procedure
            (lambda (context arguments)
              (unless (null? arguments)
                (assertion-violation
                  name
                  "context command does not accept resolved arguments"
                  arguments))
              (procedure context))
            documentation
            class
            (and interactive? (make-interactive-plan '()))
            '()))))

  (define make-interactive-context-command
    (case-lambda
      [(name procedure)
       (make-interactive-context-command name procedure #f #f)]
      [(name procedure documentation)
       (make-interactive-context-command
         name procedure documentation #f)]
      [(name procedure documentation class)
       (make-context-command
         name procedure documentation class #t)]))

  (define make-internal-context-command
    (case-lambda
      [(name procedure)
       (make-internal-context-command name procedure #f #f)]
      [(name procedure documentation)
       (make-internal-context-command
         name procedure documentation #f)]
      [(name procedure documentation class)
       (make-context-command
         name procedure documentation class #f)]))

  (define (register-command-definition! registry definition)
    (require-registry 'register-command-definition! registry)
    (unless (command-definition? definition)
      (assertion-violation
        'register-command-definition!
        "expected a command definition"
        definition))
    (let* ([name (command-definition-name definition)]
           [existing
             (hashtable-ref
               (command-registry-entries registry)
               name
               #f)])
      (hashtable-set!
        (command-registry-entries registry)
        name
        (%make-registered-command
          definition
          (if existing
              (registered-command-advice existing)
              '()))))
    (command-definition-name definition))

  (define (command-registered? registry name)
    (require-registry 'command-registered? registry)
    (and (symbol? name)
         (hashtable-contains? (command-registry-entries registry) name)))

  (define (command-entry who registry name)
    (require-registry who registry)
    (unless (symbol? name)
      (assertion-violation who "command name must be a symbol" name))
    (or (hashtable-ref (command-registry-entries registry) name #f)
        (assertion-violation who "unknown command" name)))

  (define (command-definition-ref registry name)
    (registered-command-definition
      (command-entry 'command-definition-ref registry name)))

  (define (command-procedure registry name)
    (command-definition-procedure
      (command-definition-ref registry name)))

  (define (command-documentation registry name)
    (command-definition-documentation
      (command-definition-ref registry name)))

  (define (command-class registry name)
    (command-definition-class
      (command-definition-ref registry name)))

  (define (command-interactive? registry name)
    (and
      (command-definition-interactive-plan
        (command-definition-ref registry name))
      #t))

  (define (command-names registry)
    (require-registry 'command-names registry)
    (vector->list
      (hashtable-keys (command-registry-entries registry))))

  (define (interactive-command-names registry)
    (filter
      (lambda (name) (command-interactive? registry name))
      (command-names registry)))

  (define (valid-effects? effects)
    (and (list? effects) (for-all command-effect? effects)))

  (define (require-effects who name effects)
    (unless (valid-effects? effects)
      (assertion-violation
        who
        "command must return a list of command effects"
        name
        effects))
    effects)

  (define (sorted-advice entry)
    (list-sort
      (lambda (left right)
        (< (command-advice-depth left)
           (command-advice-depth right)))
      (registered-command-advice entry)))

  (define (apply-filter-args advice context arguments)
    (fold-left
      (lambda (current item)
        (if (eq? (command-advice-where item) 'filter-args)
            (let ([filtered
                    ((command-advice-procedure item)
                     context current)])
              (unless (list? filtered)
                (assertion-violation
                  'execute-command-definition!
                  "filter-args advice must return a list"
                  (command-advice-name item)
                  filtered))
              filtered)
            current))
      arguments
      advice))

  (define (invoke-with-around
            definition
            advice
            context
            arguments)
    (let ([base
            (lambda (call-context call-arguments)
              ((command-definition-invoker definition)
               call-context call-arguments))])
      ((fold-right
         (lambda (item next)
           (if (eq? (command-advice-where item) 'around)
               (lambda (call-context call-arguments)
                 ((command-advice-procedure item)
                  next call-context call-arguments))
               next))
         base
         advice)
       context
       arguments)))

  (define (execute-entry! entry context arguments)
    (let* ([definition (registered-command-definition entry)]
           [advice (sorted-advice entry)]
           [filtered
             (apply-filter-args advice context arguments)])
      (for-each
        (lambda (item)
          (when (eq? (command-advice-where item) 'before)
            ((command-advice-procedure item) context filtered)))
        advice)
      (let* ([effects
               (require-effects
                 'execute-command-definition!
                 (command-definition-name definition)
                 (invoke-with-around
                   definition advice context filtered))]
             [filtered-effects
               (fold-left
                 (lambda (current item)
                   (if
                     (eq?
                       (command-advice-where item)
                       'filter-return)
                     (require-effects
                       'execute-command-definition!
                       (command-definition-name definition)
                       ((command-advice-procedure item)
                        context filtered current))
                     current))
                 effects
                 advice)])
        (for-each
          (lambda (item)
            (when (eq? (command-advice-where item) 'after)
              ((command-advice-procedure item)
               context filtered filtered-effects)))
          (reverse advice))
        filtered-effects)))

  (define (execute-command-definition!
            registry
            definition
            context
            arguments)
    (unless (command-context? context)
      (assertion-violation
        'execute-command-definition!
        "expected a command context"
        context))
    (unless (list? arguments)
      (assertion-violation
        'execute-command-definition!
        "arguments must be a list"
        arguments))
    (let ([entry
            (command-entry
              'execute-command-definition!
              registry
              (command-definition-name definition))])
      (execute-entry! entry context arguments)))

  (define execute-command!
    (case-lambda
      [(registry name context)
       (execute-command! registry name context '())]
      [(registry name context arguments)
       (execute-command-definition!
         registry
         (command-definition-ref registry name)
         context
         arguments)]))

  (define (command-add-advice!
            registry
            command
            name
            where
            procedure
            depth)
    (let ([entry (command-entry 'command-add-advice! registry command)])
      (unless (symbol? name)
        (assertion-violation
          'command-add-advice!
          "advice name must be a symbol"
          name))
      (unless (memq where
                    '(before after around filter-args filter-return))
        (assertion-violation
          'command-add-advice!
          "unknown advice placement"
          where))
      (unless (procedure? procedure)
        (assertion-violation
          'command-add-advice!
          "advice must be a procedure"
          procedure))
      (unless (and (integer? depth) (exact? depth))
        (assertion-violation
          'command-add-advice!
          "advice depth must be an exact integer"
          depth))
      (registered-command-advice-set!
        entry
        (cons
          (make-command-advice name where procedure depth)
          (filter
            (lambda (item)
              (not (eq? (command-advice-name item) name)))
            (registered-command-advice entry))))
      name))

  (define (command-remove-advice! registry command name)
    (let ([entry
            (command-entry 'command-remove-advice! registry command)])
      (registered-command-advice-set!
        entry
        (filter
          (lambda (item)
            (not (eq? (command-advice-name item) name)))
          (registered-command-advice entry))))
    name)

  (define (command-advice-names registry command)
    (map
      command-advice-name
      (sorted-advice
        (command-entry 'command-advice-names registry command))))

  (define (hook-key phase)
    (unless (memq phase '(pre-command post-command))
      (assertion-violation
        'command-hooks
        "unknown command hook phase"
        phase))
    phase)

  (define (command-hooks registry phase)
    (require-registry 'command-hooks registry)
    (map
      cdr
      (hashtable-ref
        (command-registry-hooks registry)
        (hook-key phase)
        '())))

  (define (add-command-hook! registry phase name procedure)
    (require-registry 'add-command-hook! registry)
    (unless (symbol? name)
      (assertion-violation
        'add-command-hook!
        "hook name must be a symbol"
        name))
    (unless (procedure? procedure)
      (assertion-violation
        'add-command-hook!
        "hook must be a procedure"
        procedure))
    (let* ([key (hook-key phase)]
           [hooks
             (hashtable-ref
               (command-registry-hooks registry)
               key
               '())])
      (hashtable-set!
        (command-registry-hooks registry)
        key
        (append
          (filter
            (lambda (entry) (not (eq? (car entry) name)))
            hooks)
          (list (cons name procedure)))))
    name)

  (define (remove-command-hook! registry phase name)
    (require-registry 'remove-command-hook! registry)
    (let* ([key (hook-key phase)]
           [hooks
             (hashtable-ref
               (command-registry-hooks registry)
               key
               '())])
      (hashtable-set!
        (command-registry-hooks registry)
        key
        (filter
          (lambda (entry) (not (eq? (car entry) name)))
          hooks)))
    name))
