(library (soda host package-context)
  (export make-package-context
          package-context?
          package-context-owner
          package-context-host?
          package-context-register-command!
          package-context-register-effect-handler!
          package-context-add-command-hook!
          package-context-add-command-advice!
          package-context-add-commit-participant!
          package-context-add-buffer-close-finalizer!
          package-context-enqueue!
          package-context-enqueue-background!
          package-context-start-task!
          package-context-register-result-source!
          package-context-publish-result-source!
          package-context-unregister-result-source!
          package-context-result-source
          package-context-result-sources
          package-context-subscribe!
          package-context-register-state-slot!
          package-context-state-slot-ref
          package-context-state-slot-set!
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
          (soda host task)
          (soda host event)
          (soda host state-slot)
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

  (define (package-context-host? context host)
    (and (package-host? host)
         (eq? (package-context-host (assert-context 'package-context-host? context))
              host)))

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

  ;; A commit participant sees the immutable update inside its originating
  ;; Dispatcher transaction, before asynchronous package events.  It is for
  ;; transaction-coupled bookkeeping only; editor work still goes through a
  ;; command or effect boundary.
  (define (package-context-add-commit-participant! context procedure)
    (assert-context 'package-context-add-commit-participant! context)
    (package-host-add-commit-participant!
      (package-context-host context) (package-context-owner context) procedure))

  (define (package-context-add-buffer-close-finalizer! context procedure)
    (assert-context 'package-context-add-buffer-close-finalizer! context)
    (package-host-add-buffer-close-finalizer!
      (package-context-host context) (package-context-owner context) procedure))

  (define (package-context-enqueue! context message)
    (if (event-delivery-active?)
        (command-runtime-enqueue-after-current! (context-runtime context) message)
        (command-runtime-enqueue! (context-runtime context) message)))

  (define (package-context-enqueue-background! context message)
    (command-runtime-enqueue-background! (context-runtime context) message))

  ;; External callbacks receive only PUBLISH!, FINISH!, and FAIL! closures.
  ;; The host validates the declared scope and enqueues RESULT-COMMAND later;
  ;; task code cannot mutate editor state from its native callback.
  (define (package-context-start-task!
            context name scope origin result-command result-arguments start)
    (assert-context 'package-context-start-task! context)
    (package-host-start-task!
      (package-context-host context) (package-context-owner context)
      name scope origin result-command result-arguments start))

  (define (package-context-register-result-source! context source)
    (assert-context 'package-context-register-result-source! context)
    (package-host-register-result-source!
      (package-context-host context) (package-context-owner context) source))

  (define (package-context-publish-result-source! context source)
    (assert-context 'package-context-publish-result-source! context)
    (package-host-publish-result-source!
      (package-context-host context) (package-context-owner context) source))

  (define (package-context-unregister-result-source! context id)
    (assert-context 'package-context-unregister-result-source! context)
    (package-host-unregister-result-source!
      (package-context-host context) (package-context-owner context) id))

  (define package-context-result-source
    (case-lambda
      [(context id) (package-context-result-source context id #f)]
      [(context id default)
       (assert-context 'package-context-result-source context)
       (package-host-result-source (package-context-host context) id default)]))

  (define (package-context-result-sources context)
    (assert-context 'package-context-result-sources context)
    (package-host-result-sources (package-context-host context)))

  (define package-context-subscribe!
    (case-lambda
      [(context topic procedure)
       (package-context-subscribe! context topic #f procedure)]
      [(context topic selector procedure)
       (assert-context 'package-context-subscribe! context)
       (package-host-subscribe!
         (package-context-host context) (package-context-owner context)
         topic selector procedure)]))

  (define (package-context-register-state-slot! context slot)
    (assert-context 'package-context-register-state-slot! context)
    (package-host-register-state-slot!
      (package-context-host context) (package-context-owner context) slot))

  (define package-context-state-slot-ref
    (case-lambda
      [(context slot buffer-id)
       (package-context-state-slot-ref context slot buffer-id #f)]
      [(context slot buffer-id default)
       (assert-context 'package-context-state-slot-ref context)
       (package-host-state-slot-ref
         (package-context-host context) (package-context-owner context)
         slot buffer-id default)]))

  ;; Slot writes belong in command work.  Event handlers should enqueue that
  ;; command rather than mutating a slot while delivering an observation.
  (define (package-context-state-slot-set! context slot buffer-id value)
    (assert-context 'package-context-state-slot-set! context)
    (package-host-state-slot-set!
      (package-context-host context) (package-context-owner context)
      slot buffer-id value))

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
