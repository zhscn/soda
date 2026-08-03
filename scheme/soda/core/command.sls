(library (soda core command)
  (export make-command-definition
          command-definition?
          command-definition-name
          command-definition-invoke
          command-definition-interactive-invoke
          command-definition-documentation
          command-definition-class
          command-definition-owner
          make-command-registry
          command-registry?
          register-command!
          unregister-command!
          command-lookup
          command-definitions
          command-invoke
          command-invoke-interactive
          make-command-context
          command-context?
          command-context-core
          command-context-view-id
          command-context-buffer-id
          command-context-event
          command-context-prefix
          command-context-source)
  (import (rnrs)
          (soda core buffer)
          (soda core value)
          (soda core view))

  (define-record-type
    (command-definition %make-command-definition command-definition?)
    (fields
      (immutable name command-definition-name)
      (immutable invoke command-definition-invoke)
      (immutable interactive-invoke command-definition-interactive-invoke)
      (immutable documentation command-definition-documentation)
      (immutable class command-definition-class)
      (immutable owner command-definition-owner)))

  (define make-command-definition
    (case-lambda
      [(name invoke owner)
       (make-command-definition name invoke #f #f 'normal owner)]
      [(name invoke interactive-invoke documentation class owner)
       (unless (symbol? name)
         (assertion-violation
           'make-command-definition
           "name must be a symbol"
           name))
       (unless (procedure? invoke)
         (assertion-violation
           'make-command-definition
           "invoke must be a procedure"
           invoke))
       (unless (or (not interactive-invoke)
                   (procedure? interactive-invoke))
         (assertion-violation
           'make-command-definition
           "interactive invoke must be a procedure"
           interactive-invoke))
       (owner-assert-active 'make-command-definition owner)
       (%make-command-definition
         name invoke interactive-invoke documentation class owner)]))

  (define-record-type
    (command-registry %make-command-registry command-registry?)
    (fields
      (immutable commands command-registry-table)
      (mutable registrations command-registry-registrations
                command-registry-registrations-set!)))

  (define make-command-registry
    (lambda ()
      (%make-command-registry
        (make-eq-hashtable)
        '())))

  (define (register-command! registry definition)
    (unless (command-registry? registry)
      (assertion-violation
        'register-command!
        "expected a command registry"
        registry))
    (unless (command-definition? definition)
      (assertion-violation
        'register-command!
        "expected a command definition"
        definition))
    (let ([name (command-definition-name definition)])
      (when (hashtable-contains?
              (command-registry-table registry)
              name)
        (assertion-violation
          'register-command!
          "command is already registered"
          name))
      (hashtable-set!
        (command-registry-table registry)
        name
        definition)
      (command-registry-registrations-set!
        registry
        (cons definition (command-registry-registrations registry)))
      (make-registration
        (command-definition-owner definition)
        (lambda ()
          (when (and
                  (hashtable-contains? (command-registry-table registry) name)
                  (eq? definition
                       (hashtable-ref (command-registry-table registry) name #f)))
            (unregister-command! registry name))))))

  (define (unregister-command! registry name)
    (unless (command-registry? registry)
      (assertion-violation
        'unregister-command!
        "expected a command registry"
        registry))
    (if (hashtable-contains? (command-registry-table registry) name)
        (begin
          (hashtable-delete! (command-registry-table registry) name)
          (command-registry-registrations-set!
            registry
            (filter
              (lambda (definition)
                (not (eq? name (command-definition-name definition))))
              (command-registry-registrations registry)))
          #t)
        #f))

  (define (command-lookup registry name . default)
    (unless (command-registry? registry)
      (assertion-violation 'command-lookup "expected a command registry" registry))
    (if (hashtable-contains? (command-registry-table registry) name)
        (hashtable-ref (command-registry-table registry) name #f)
        (if (null? default) #f (car default))))

  (define (command-definitions registry)
    (unless (command-registry? registry)
      (assertion-violation
        'command-definitions
        "expected a command registry"
        registry))
    (command-registry-registrations registry))

  (define-record-type
    (command-context %make-command-context command-context?)
    (fields core view-id buffer-id event prefix source))

  (define make-command-context
    (case-lambda
      [(view event prefix source)
       (make-command-context #f view event prefix source)]
      [(core view event prefix source)
       (unless (view? view)
         (assertion-violation
           'make-command-context "expected a view" view))
       (%make-command-context
         core
         (view-id view)
         (buffer-id (view-buffer view))
         event
         prefix
         source)]))

  (define (command-invoke definition context arguments)
    (unless (command-definition? definition)
      (assertion-violation 'command-invoke "expected a command definition" definition))
    (unless (command-context? context)
      (assertion-violation 'command-invoke "expected a command context" context))
    (unless (list? arguments)
      (assertion-violation 'command-invoke "arguments must be a list" arguments))
    (apply (command-definition-invoke definition) context arguments))

  (define (command-invoke-interactive definition context)
    (unless (command-definition? definition)
      (assertion-violation
        'command-invoke-interactive
        "expected a command definition"
        definition))
    (unless (command-context? context)
      (assertion-violation
        'command-invoke-interactive
        "expected a command context"
        context))
    (let ([procedure (command-definition-interactive-invoke definition)])
      (if procedure
          (procedure context)
          (command-invoke definition context '()))))
)
