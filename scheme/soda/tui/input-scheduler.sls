(library (soda tui input-scheduler)
  (export make-input-scheduler
          input-scheduler?
          input-scheduler-enqueue!
          input-scheduler-begin-cycle!
          input-scheduler-completed-generation
          input-scheduler-presentation-ready?)
  (import (rnrs)
          (soda host frontend)
          (soda host input-event)
          (soda host surface))

  ;; InputScheduler owns terminal key-lifecycle scheduling.  The host runtime
  ;; remains a general message queue and the frontend consumes only normalized
  ;; action cycles: press, repeat, and text input begin a cycle; release only
  ;; cancels queued repeat state for the same physical key.
  (define-record-type
    (input-scheduler %make-input-scheduler input-scheduler?)
    (fields
      (immutable state input-scheduler-state)
      (mutable open-cycles input-scheduler-open-cycles
                           input-scheduler-open-cycles-set!)
      (mutable completed-generation input-scheduler-completed-generation
                                    input-scheduler-completed-generation-set!)))

  (define (make-input-scheduler state)
    (%make-input-scheduler state 0 0))

  (define (same-physical-key? left right)
    (and (key-event? left) (key-event? right)
         (key-stroke=? (key-event->key-stroke left)
                       (key-event->key-stroke right))))

  (define (pending-repeat-for? message surface-id event)
    (and (surface-input-message? message)
         (= (surface-input-message-surface-id message) surface-id)
         (let ([candidate (surface-input-message-event message)])
           (and (key-event? candidate)
                (eq? (key-event-type candidate) 'repeat)
                (same-physical-key? candidate event)))))

  (define (input-scheduler-enqueue! scheduler message)
    (unless (input-scheduler? scheduler)
      (assertion-violation
        'input-scheduler-enqueue! "expected an InputScheduler" scheduler))
    (when (surface-input-message? message)
      (let ([event (surface-input-message-event message)])
        (when (and (key-event? event)
                   (eq? (key-event-type event) 'release))
          (host-frontend-discard!
            (input-scheduler-state scheduler)
            (lambda (candidate)
              (pending-repeat-for?
                candidate (surface-input-message-surface-id message) event))))))
    (host-frontend-enqueue! (input-scheduler-state scheduler) message))

  ;; The boundary is queued before command dispatch.  Command messages use the
  ;; runtime priority lane, so they execute first and the boundary closes the
  ;; complete input transaction even when older input is already queued.
  (define (input-scheduler-begin-cycle! scheduler)
    (unless (input-scheduler? scheduler)
      (assertion-violation
        'input-scheduler-begin-cycle! "expected an InputScheduler" scheduler))
    (input-scheduler-open-cycles-set!
      scheduler (+ 1 (input-scheduler-open-cycles scheduler)))
    (host-frontend-enqueue-priority!
      (input-scheduler-state scheduler)
      (lambda ()
        (when (zero? (input-scheduler-open-cycles scheduler))
          (assertion-violation
            'input-scheduler-begin-cycle!
            "input cycle boundary has no matching open cycle" scheduler))
        (input-scheduler-open-cycles-set!
          scheduler (- (input-scheduler-open-cycles scheduler) 1))
        (input-scheduler-completed-generation-set!
          scheduler (+ 1 (input-scheduler-completed-generation scheduler))))))

  (define (input-scheduler-presentation-ready? scheduler)
    (unless (input-scheduler? scheduler)
      (assertion-violation
        'input-scheduler-presentation-ready? "expected an InputScheduler" scheduler))
    (zero? (input-scheduler-open-cycles scheduler)))
)
