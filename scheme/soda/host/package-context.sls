(library (soda host package-context)
  (export make-package-context
          package-context?
          package-context-owner
          package-context-register-command!
          package-context-register-effect-handler!
          package-context-add-command-hook!
          package-context-add-command-advice!
          package-context-enqueue!
          package-context-enqueue-background!
          package-context-command-definition
          package-context-command-available?
          package-context-available-user-command-definitions
          package-context-invocation
          package-context-set-interaction-handler!
          package-context-repeat-last!
          package-context-set-repeat-state!
          define-package-command)
  (import (rnrs)
          (soda host command)
          (soda host command-declaration)
          (soda host command-runtime)
          (soda host package)
          (soda host value))

  ;; PackageContext binds one host capability to the Owner responsible for
  ;; every declaration made through it.  Packages can declare behavior and
  ;; enqueue work without receiving a mutable CommandRuntime registry.
  (define-record-type
    (package-context %make-package-context package-context?)
    (fields (immutable host package-context-host)
            (immutable owner package-context-owner)))

  (define (assert-context who value)
    (unless (package-context? value)
      (assertion-violation who "expected a PackageContext" value))
    (owner-assert-active who (package-context-owner value))
    value)

  (define (context-runtime context)
    (package-host-command-runtime
      (package-context-host (assert-context 'context-runtime context))))

  (define (make-package-context host owner)
    (unless (and (package-host? host) (owner? owner))
      (assertion-violation 'make-package-context
                           "expected a PackageHost and Owner" host owner))
    (owner-assert-active 'make-package-context owner)
    (%make-package-context host owner))

  (define (package-context-register-command! context definition)
    (assert-context 'package-context-register-command! context)
    (unless (and (command-definition? definition)
                 (eq? (command-definition-owner definition)
                      (package-context-owner context)))
      (assertion-violation
        'package-context-register-command!
        "command must belong to the PackageContext owner" definition))
    (command-runtime-register-command! (context-runtime context) definition))

  (define (package-context-register-effect-handler! context kind name procedure)
    (command-runtime-register-effect-handler!
      (context-runtime context) kind (package-context-owner context) name procedure))

  (define (package-context-add-command-hook! context phase name procedure)
    (command-runtime-add-hook!
      (context-runtime context) phase (package-context-owner context) name procedure))

  (define package-context-add-command-advice!
    (case-lambda
      [(context command name where procedure)
       (package-context-add-command-advice! context command name where procedure 0)]
      [(context command name where procedure depth)
       (command-runtime-add-advice!
         (context-runtime context) command (package-context-owner context)
         name where procedure depth)]))

  (define (package-context-enqueue! context message)
    (command-runtime-enqueue! (context-runtime context) message))

  (define (package-context-enqueue-background! context message)
    (command-runtime-enqueue-background! (context-runtime context) message))

  (define package-context-command-definition
    (case-lambda
      [(context name)
       (package-context-command-definition context name #f)]
      [(context name default)
       (command-runtime-command-definition (context-runtime context) name default)]))

  (define (package-context-command-available? context definition-or-name command-context)
    (command-runtime-command-available?
      (context-runtime context) definition-or-name command-context))

  (define (package-context-available-user-command-definitions context command-context)
    (command-runtime-available-user-command-definitions
      (context-runtime context) command-context))

  (define package-context-invocation
    (case-lambda
      [(context invocation-id)
       (package-context-invocation context invocation-id #f)]
      [(context invocation-id default)
       (command-runtime-invocation (context-runtime context) invocation-id default)]))

  (define (package-context-set-interaction-handler! context handler)
    (command-runtime-set-interaction-handler!
      (context-runtime context) (package-context-owner context) handler))

  (define (package-context-repeat-last! context command-context)
    (command-runtime-repeat-last! (context-runtime context) command-context))

  (define (package-context-set-repeat-state! context state)
    (command-runtime-set-repeat-state!
      (context-runtime context) (package-context-owner context) state))

  (define-syntax define-package-command
    (syntax-rules ()
      [(_ context name arguments clauses ...)
       (define-command/with
         (lambda (definition)
           (package-context-register-command! context definition))
         (package-context-owner context) name arguments clauses ...)]))
)
