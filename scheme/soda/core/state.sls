(library (soda core state)
  (export make-core-state
          core-state?
          core-state-owner
          core-state-runtime
          core-state-buffers
          core-state-views
          core-state-input
          core-state-display
          core-state-commands
          core-state-packages
          core-state-conditions
          core-state-closed?
          core-state-close!
          core-state-register-package!
          core-state-activate-package!
          core-state-deactivate-package!
          core-state-enqueue!
          core-state-dispatch!)
  (import (rnrs)
          (soda core buffer)
          (soda core command)
          (soda core condition)
          (soda core display)
          (soda core input)
          (soda core package)
          (soda core runtime)
          (soda core value)
          (soda core view))

  (define-record-type
    (core-state %make-core-state core-state?)
    (fields
      (immutable owner core-state-owner)
      (immutable runtime core-state-runtime)
      (immutable buffers core-state-buffers)
      (immutable views core-state-views)
      (immutable input core-state-input)
      (immutable display core-state-display)
      (immutable commands core-state-commands)
      (immutable packages core-state-packages)
      (immutable conditions core-state-conditions)
      (mutable closed? core-state-closed? core-state-closed?-set!)))

  (define (make-core-state)
    (let* ([owner (make-owner 'core)]
           [runtime (make-runtime-state)]
           [buffers (make-buffer-service)]
           [views (make-view-service)]
           [input (make-input-service)]
           [display (make-display-service)]
           [commands (make-command-registry)]
           [conditions (make-condition-service)]
           [packages
             (make-package-registry
               `((runtime . ,runtime)
                 (buffers . ,buffers)
                 (views . ,views)
                 (input . ,input)
                 (display . ,display)
                 (commands . ,commands)
                 (conditions . ,conditions)))])
      (%make-core-state
        owner runtime buffers views input display commands packages conditions #f)))

  (define (require-open-state who state)
    (unless (core-state? state)
      (assertion-violation who "expected a core state" state))
    (when (core-state-closed? state)
      (assertion-violation who "core state is closed" state))
    state)

  (define (core-state-register-package! state definition)
    (require-open-state 'core-state-register-package! state)
    (register-package! (core-state-packages state) definition))

  (define (core-state-activate-package! state name)
    (require-open-state 'core-state-activate-package! state)
    (package-activate! (core-state-packages state) name))

  (define (core-state-deactivate-package! state name)
    (require-open-state 'core-state-deactivate-package! state)
    (package-deactivate! (core-state-packages state) name))

  (define (core-state-enqueue! state message)
    (require-open-state 'core-state-enqueue! state)
    (runtime-enqueue! (core-state-runtime state) message))

  (define (core-state-dispatch! state handler . limit)
    (require-open-state 'core-state-dispatch! state)
    (unless (procedure? handler)
      (assertion-violation
        'core-state-dispatch! "handler must be a procedure" handler))
    (apply
      runtime-drain!
      (core-state-runtime state)
      (lambda (message)
        (call-with-condition-boundary
          (core-state-conditions state)
          (message-owner message)
          (message-target message)
          message
          (lambda () (handler message))))
      limit))

  (define (core-state-close! state)
    (unless (core-state? state)
      (assertion-violation 'core-state-close! "expected a core state" state))
    (if (core-state-closed? state)
        #f
        (let ([failure #f])
          (guard
            (condition [else (set! failure condition)])
            (package-deactivate-all! (core-state-packages state)))
          (guard
            (condition [else (unless failure (set! failure condition))])
            (runtime-clear-owner!
              (core-state-runtime state)
              (core-state-owner state)))
          (guard
            (condition [else (unless failure (set! failure condition))])
            (owner-close! (core-state-owner state)))
          (core-state-closed?-set! state #t)
          (if failure (raise failure) #t))))
)
