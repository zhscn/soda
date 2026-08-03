(library (soda core state)
  (export make-core-state
          core-state?
          core-state-owner
          core-state-runtime
          core-state-commands
          core-state-packages
          core-state-closed?
          core-state-close!
          core-state-register-package!
          core-state-activate-package!
          core-state-deactivate-package!)
  (import (rnrs)
          (soda core command)
          (soda core package)
          (soda core runtime)
          (soda core value))

  (define-record-type
    (core-state %make-core-state core-state?)
    (fields
      (immutable owner core-state-owner)
      (immutable runtime core-state-runtime)
      (immutable commands core-state-commands)
      (immutable packages core-state-packages)
      (mutable closed? core-state-closed? core-state-closed?-set!)))

  (define (make-core-state)
    (%make-core-state
      (make-owner 'core)
      (make-runtime-state)
      (make-command-registry)
      (make-package-registry)
      #f))

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

  (define (core-state-close! state)
    (require-open-state 'core-state-close! state)
    (package-deactivate-all! (core-state-packages state))
    (runtime-clear-owner!
      (core-state-runtime state)
      (core-state-owner state))
    (owner-close! (core-state-owner state))
    (core-state-closed?-set! state #t)
    #t)
)
