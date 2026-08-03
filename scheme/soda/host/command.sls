(library (soda host command)
  (export make-command-definition
          command-definition?
          command-definition-name
          command-definition-invoke
          command-definition-interaction-spec
          make-command-registry
          command-registry?
          command-register!
          command-unregister!
          command-lookup
          make-command-context
          command-context?
          command-context-view-id
          command-context-buffer-id
          command-context-source
          command-invoke)
  (import (rnrs)
          (soda host value))

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
      (immutable source command-context-source)))

  (define (make-command-context view-id buffer-id source)
    (%make-command-context view-id buffer-id source))

  (define (command-invoke definition context arguments)
    (unless (and (command-definition? definition) (command-context? context))
      (assertion-violation 'command-invoke "invalid command invocation" definition context))
    (apply (command-definition-invoke definition) context arguments))
)
