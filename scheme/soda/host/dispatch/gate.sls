(library (soda host dispatch gate)
  (export make-dispatch-gate
          dispatch-gate?
          dispatch-gate-run!
          dispatch-gate-notify!)
  (import (rnrs))

  (define-record-type
    (dispatch-gate %make-dispatch-gate dispatch-gate?)
    (fields
      (mutable phase dispatch-gate-phase dispatch-gate-phase-set!)
      (mutable deferred dispatch-gate-deferred dispatch-gate-deferred-set!)
      (mutable draining? dispatch-gate-draining? dispatch-gate-draining?-set!)))

  (define (make-dispatch-gate)
    (%make-dispatch-gate 'idle '() #f))

  (define (dispatch-gate-drain! gate)
    (when (and (eq? (dispatch-gate-phase gate) 'idle)
               (pair? (dispatch-gate-deferred gate))
               (not (dispatch-gate-draining? gate)))
      (dynamic-wind
        (lambda () (dispatch-gate-draining?-set! gate #t))
        (lambda ()
          (let loop ()
            (when (pair? (dispatch-gate-deferred gate))
              (let ([queued (dispatch-gate-deferred gate)])
                (dispatch-gate-deferred-set! gate '())
                (for-each (lambda (thunk) (dispatch-gate-run! gate thunk)) queued)
                (loop)))))
        (lambda () (dispatch-gate-draining?-set! gate #f)))))

  ;; Work requested during publication is queued in declaration order and
  ;; observes the completed update at the next idle boundary.
  (define (dispatch-gate-run! gate thunk)
    (unless (and (dispatch-gate? gate) (procedure? thunk))
      (assertion-violation
        'dispatch-gate-run! "expected a DispatchGate and thunk" gate thunk))
    (if (eq? (dispatch-gate-phase gate) 'idle)
        (let ([result
               (dynamic-wind
                 (lambda () (dispatch-gate-phase-set! gate 'publishing))
                 thunk
                 (lambda () (dispatch-gate-phase-set! gate 'idle)))])
          (unless (dispatch-gate-draining? gate)
            (dispatch-gate-drain! gate))
          result)
        (begin
          (dispatch-gate-deferred-set!
            gate (append (dispatch-gate-deferred gate) (list thunk)))
          #f)))

  (define (dispatch-gate-notify! gate thunk)
    (unless (and (dispatch-gate? gate) (procedure? thunk))
      (assertion-violation
        'dispatch-gate-notify! "expected a DispatchGate and thunk" gate thunk))
    (let ([phase (dispatch-gate-phase gate)])
      (dynamic-wind
        (lambda () (dispatch-gate-phase-set! gate 'notifying))
        thunk
        (lambda () (dispatch-gate-phase-set! gate phase)))))
)
