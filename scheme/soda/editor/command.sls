(library (soda editor command)
  (export make-command-registry
          command-registry?
          register-command!
          command-registered?
          command-names
          command-procedure
          command-documentation
          execute-command!
          make-command-context
          command-context?
          command-context-editor
          command-context-view
          command-context-event
          command-context-argument
          make-command-effect
          command-effect?
          command-effect-kind
          command-effect-payload)
  (import (rnrs))

  (define-record-type (command-registry %make-command-registry command-registry?)
    (fields entries))

  (define-record-type command-context
    (fields editor view event argument))

  (define-record-type command-effect
    (fields kind payload))

  (define (make-command-registry)
    (%make-command-registry (make-eq-hashtable)))

  (define (require-registry who value)
    (unless (command-registry? value)
      (assertion-violation who "expected a command registry" value)))

  (define register-command!
    (case-lambda
      [(registry name procedure)
       (register-command! registry name procedure #f)]
      [(registry name procedure documentation)
       (require-registry 'register-command! registry)
       (unless (symbol? name)
         (assertion-violation
           'register-command!
           "command name must be a symbol"
           name))
       (unless (procedure? procedure)
         (assertion-violation
           'register-command!
           "command implementation must be a procedure"
           procedure))
       (unless (or (not documentation) (string? documentation))
         (assertion-violation
           'register-command!
           "command documentation must be a string or #f"
           documentation))
       (hashtable-set!
         (command-registry-entries registry)
         name
         (cons procedure documentation))
       name]))

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

  (define (command-procedure registry name)
    (car (command-entry 'command-procedure registry name)))

  (define (command-documentation registry name)
    (cdr (command-entry 'command-documentation registry name)))

  (define (command-names registry)
    (require-registry 'command-names registry)
    (vector->list
      (hashtable-keys (command-registry-entries registry))))

  (define (execute-command! registry name context)
    (unless (command-context? context)
      (assertion-violation
        'execute-command!
        "expected a command context"
        context))
    (let ([effects ((command-procedure registry name) context)])
      (unless (and (list? effects) (for-all command-effect? effects))
        (assertion-violation
          'execute-command!
          "command must return a list of command effects"
          name
          effects))
      effects)))
