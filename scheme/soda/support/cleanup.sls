(library (soda support cleanup)
  (export run-cleanups!)
  (import (rnrs))

  ;; Cleanup is best-effort but deterministic: every action runs in order and
  ;; the first failure is reported only after later resources had a chance to
  ;; restore their own invariants.
  (define (run-cleanups! actions)
    (unless (and (list? actions) (for-all procedure? actions))
      (assertion-violation 'run-cleanups! "expected a list of cleanup procedures" actions))
    (let ([failure #f])
      (for-each
        (lambda (action)
          (guard
            (condition
              [else
               (unless failure (set! failure condition))
               #f])
            (action)))
        actions)
      (when failure (raise failure))
      #t))
)
