(library (soda tui input-scheduler)
  (export make-input-scheduler
          input-scheduler?
          input-scheduler-enqueue!
          input-scheduler-discard-stale-legacy-repeats!
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
  ;; cancels queued repeat state for the same physical key.  Legacy terminals
  ;; cannot report release, so their inferred repeat debt is coalesced to one
  ;; pending event rather than being consumed long after the key is released.
  (define-record-type
    (input-scheduler %make-input-scheduler input-scheduler?)
    (fields
      (immutable state input-scheduler-state)
      (immutable surface-id input-scheduler-surface-id)
      (mutable open-cycles input-scheduler-open-cycles
                           input-scheduler-open-cycles-set!)
      (mutable completed-generation input-scheduler-completed-generation
                                    input-scheduler-completed-generation-set!)))

  (define (make-input-scheduler state surface-id)
    (unless (and (integer? surface-id) (exact? surface-id)
                 (not (negative? surface-id)))
      (assertion-violation
        'make-input-scheduler "expected a non-negative Surface identity" surface-id))
    (%make-input-scheduler state surface-id 0 0))

  (define (same-physical-key? left right)
    (and (key-event? left) (key-event? right)
         (key-stroke=? (key-event->key-stroke left)
                       (key-event->key-stroke right))))

  (define (pending-repeat-for? message surface-id event)
    (and (surface-input-message? message)
         (= (surface-input-message-surface-id message) surface-id)
         (let ([candidate (surface-input-message-event message)])
           (and (key-event? candidate)
                (memq (key-event-type candidate) '(repeat legacy-repeat))
                (same-physical-key? candidate event)))))

  (define (pending-repeat-on-surface? message surface-id)
    (and (surface-input-message? message)
         (= (surface-input-message-surface-id message) surface-id)
         (let ([candidate (surface-input-message-event message)])
           (and (key-event? candidate)
                (memq (key-event-type candidate) '(repeat legacy-repeat))))))

  (define (pending-legacy-repeat-for? message surface-id event)
    (and (surface-input-message? message)
         (= (surface-input-message-surface-id message) surface-id)
         (let ([candidate (surface-input-message-event message)])
           (and (key-event? candidate)
                (eq? (key-event-type candidate) 'legacy-repeat)
                (same-physical-key? candidate event)))))

  (define (pending-legacy-repeat-on-surface? message surface-id)
    (and (surface-input-message? message)
         (= (surface-input-message-surface-id message) surface-id)
         (let ([candidate (surface-input-message-event message)])
           (and (key-event? candidate)
                (eq? (key-event-type candidate) 'legacy-repeat)))))

  (define (input-scheduler-enqueue! scheduler message)
    (unless (input-scheduler? scheduler)
      (assertion-violation
        'input-scheduler-enqueue! "expected an InputScheduler" scheduler))
    (when (surface-input-message? message)
      (let ([event (surface-input-message-event message)]
            [surface-id (surface-input-message-surface-id message)])
        (when (key-event? event)
          (case (key-event-type event)
            ;; A fresh physical press supersedes repeat debt already queued for
            ;; this Surface.  Direction changes therefore take effect at the
            ;; next action instead of waiting behind stale repeats.
            [(press)
             (host-frontend-discard!
               (input-scheduler-state scheduler)
               (lambda (candidate)
                 (pending-repeat-on-surface? candidate surface-id)))]
            [(release)
             (host-frontend-discard!
               (input-scheduler-state scheduler)
               (lambda (candidate)
                 (pending-repeat-for? candidate surface-id event)))]
            [(legacy-repeat)
             ;; A non-Kitty terminal has no key-up report.  Retaining an
             ;; unbounded read burst turns a released key into delayed motion;
             ;; the newest observed repeat is sufficient to keep held motion
             ;; fluid while bounding post-release movement to one action.
             (host-frontend-discard!
               (input-scheduler-state scheduler)
               (lambda (candidate)
                 (pending-legacy-repeat-for? candidate surface-id event)))]))))
    (host-frontend-enqueue! (input-scheduler-state scheduler) message))

  ;; No legacy protocol can tell us that a key was released.  Once the
  ;; terminal adapter completes a poll without another input event, the only
  ;; remaining inferred repeats belong to an already-finished read burst.
  ;; Discard them before the next action turn: continuing a held key still
  ;; produces the next motion when its next byte is actually readable.
  (define (input-scheduler-discard-stale-legacy-repeats! scheduler)
    (unless (input-scheduler? scheduler)
      (assertion-violation
        'input-scheduler-discard-stale-legacy-repeats!
        "expected an InputScheduler" scheduler))
    (host-frontend-discard!
      (input-scheduler-state scheduler)
      (lambda (candidate)
        (pending-legacy-repeat-on-surface?
          candidate (input-scheduler-surface-id scheduler)))))

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
