(library (soda tui input-scheduler)
  (export make-input-scheduler
          input-scheduler?
          input-scheduler-enqueue!
          input-scheduler-consume!
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
      ;; Entries are (surface-id key-stroke count).  They describe only
      ;; repeats still waiting in Runtime, rather than every decoded key.
      ;; This lets legacy terminals enqueue a large press-only read without
      ;; repeatedly scanning it for repeat events that cannot exist.
      (mutable pending-repeats input-scheduler-pending-repeats
                               input-scheduler-pending-repeats-set!)
      (mutable open-cycles input-scheduler-open-cycles
                           input-scheduler-open-cycles-set!)
      (mutable completed-generation input-scheduler-completed-generation
                                    input-scheduler-completed-generation-set!)))

  (define (make-input-scheduler state)
    (%make-input-scheduler state '() 0 0))

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

  (define (pending-repeat-on-surface? message surface-id)
    (and (surface-input-message? message)
         (= (surface-input-message-surface-id message) surface-id)
         (let ([candidate (surface-input-message-event message)])
           (and (key-event? candidate)
                (eq? (key-event-type candidate) 'repeat)))))

  (define (repeat-entry-matches? entry surface-id event)
    (and (= (car entry) surface-id)
         (key-stroke=? (cadr entry) (key-event->key-stroke event))))

  (define (pending-repeat-on-surface-tracked? scheduler surface-id)
    (exists (lambda (entry) (= (car entry) surface-id))
            (input-scheduler-pending-repeats scheduler)))

  (define (pending-repeat-tracked? scheduler surface-id event)
    (exists (lambda (entry) (repeat-entry-matches? entry surface-id event))
            (input-scheduler-pending-repeats scheduler)))

  (define (remember-repeat! scheduler surface-id event)
    (let ([entries (input-scheduler-pending-repeats scheduler)])
      (if (pending-repeat-tracked? scheduler surface-id event)
          (input-scheduler-pending-repeats-set!
            scheduler
            (map (lambda (entry)
                   (if (repeat-entry-matches? entry surface-id event)
                       (list (car entry) (cadr entry) (+ (caddr entry) 1))
                       entry))
                 entries))
          (input-scheduler-pending-repeats-set!
            scheduler
            (cons (list surface-id (key-event->key-stroke event) 1) entries)))))

  (define (forget-repeat! scheduler surface-id event)
    (let loop ([remaining (input-scheduler-pending-repeats scheduler)]
               [result '()])
      (cond
        [(null? remaining)
         (input-scheduler-pending-repeats-set! scheduler (reverse result))]
        [(repeat-entry-matches? (car remaining) surface-id event)
         (let ([entry (car remaining)])
           (input-scheduler-pending-repeats-set!
             scheduler
             (append (reverse result)
                     (if (> (caddr entry) 1)
                         (cons (list (car entry) (cadr entry) (- (caddr entry) 1))
                               (cdr remaining))
                         (cdr remaining)))))]
        [else (loop (cdr remaining) (cons (car remaining) result))])))

  (define (forget-repeats-on-surface! scheduler surface-id)
    (input-scheduler-pending-repeats-set!
      scheduler
      (filter (lambda (entry) (not (= (car entry) surface-id)))
              (input-scheduler-pending-repeats scheduler))))

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
             (when (pending-repeat-on-surface-tracked? scheduler surface-id)
               (host-frontend-discard!
                 (input-scheduler-state scheduler)
                 (lambda (candidate)
                   (pending-repeat-on-surface? candidate surface-id)))
               (forget-repeats-on-surface! scheduler surface-id))]
            [(repeat) (remember-repeat! scheduler surface-id event)]
            [(release)
             (when (pending-repeat-tracked? scheduler surface-id event)
               (host-frontend-discard!
                 (input-scheduler-state scheduler)
                 (lambda (candidate)
                   (pending-repeat-for? candidate surface-id event)))
               (let loop ()
                 (when (pending-repeat-tracked? scheduler surface-id event)
                   (forget-repeat! scheduler surface-id event)
                   (loop))))]))))
    (host-frontend-enqueue-input! (input-scheduler-state scheduler) message))

  ;; Frontend invokes this exactly when an input message leaves Runtime.  The
  ;; count stays accurate across partial drains, so a later press or release
  ;; still cancels only repeat messages that are genuinely queued.
  (define (input-scheduler-consume! scheduler message)
    (unless (input-scheduler? scheduler)
      (assertion-violation
        'input-scheduler-consume! "expected an InputScheduler" scheduler))
    (when (surface-input-message? message)
      (let ([event (surface-input-message-event message)])
        (when (and (key-event? event) (eq? (key-event-type event) 'repeat))
          (forget-repeat! scheduler (surface-input-message-surface-id message) event)))))

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
