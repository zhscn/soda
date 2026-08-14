(library (soda host internal navigation)
  (export make-navigation-history
          navigation-history?
          navigation-history-entries
          navigation-history-cursor
          navigation-history-pending?
          navigation-history-begin!
          navigation-history-back!
          navigation-history-forward!
          navigation-history-commit!
          navigation-history-rollback!
          navigation-history-cancel!
          navigation-entry?
          navigation-entry-from
          navigation-entry-to
          navigation-jump?
          navigation-jump-kind
          navigation-jump-from
          navigation-jump-target)
  (import (rnrs)
          (soda kernel location))

  (define-record-type navigation-entry
    (fields from to))

  (define-record-type
    (navigation-jump %make-navigation-jump navigation-jump?)
    (fields history serial kind from target cursor entries))

  ;; Cursor is the number of committed transitions currently applied.  New
  ;; jumps truncate entries after it, while back/forward only move it after
  ;; successful resolution and placement.
  (define-record-type
    (navigation-history %make-navigation-history navigation-history?)
    (fields
      (mutable entries navigation-history-entries
               navigation-history-entries-set!)
      (mutable cursor navigation-history-cursor
               navigation-history-cursor-set!)
      (mutable serial navigation-history-serial
               navigation-history-serial-set!)
      (mutable pending navigation-history-pending
               navigation-history-pending-set!)))

  (define (make-navigation-history)
    (%make-navigation-history '() 0 0 #f))

  (define (navigation-history-pending? history)
    (unless (navigation-history? history)
      (assertion-violation
        'navigation-history-pending? "expected NavigationHistory" history))
    (and (navigation-history-pending history) #t))

  (define (next-jump! history kind from target)
    (let* ([serial (+ 1 (navigation-history-serial history))]
           [jump (%make-navigation-jump
                   history serial kind from target
                   (navigation-history-cursor history)
                   (navigation-history-entries history))])
      (navigation-history-serial-set! history serial)
      ;; Replacing pending makes the old token observationally superseded.
      (navigation-history-pending-set! history jump)
      jump))

  (define (navigation-history-begin! history from target)
    (unless (and (navigation-history? history)
                 (location? from) (location? target))
      (assertion-violation
        'navigation-history-begin! "invalid navigation jump" history from target))
    (next-jump! history 'jump from target))

  (define (navigation-history-back! history)
    (unless (navigation-history? history)
      (assertion-violation
        'navigation-history-back! "expected NavigationHistory" history))
    (let ([cursor (navigation-history-cursor history)])
      (and (> cursor 0)
           (let ([entry (list-ref (navigation-history-entries history)
                                  (- cursor 1))])
             (next-jump! history 'back
                         (navigation-entry-to entry)
                         (navigation-entry-from entry))))))

  (define (navigation-history-forward! history)
    (unless (navigation-history? history)
      (assertion-violation
        'navigation-history-forward! "expected NavigationHistory" history))
    (let ([cursor (navigation-history-cursor history)]
          [entries (navigation-history-entries history)])
      (and (< cursor (length entries))
           (let ([entry (list-ref entries cursor)])
             (next-jump! history 'forward
                         (navigation-entry-from entry)
                         (navigation-entry-to entry))))))

  (define (take values count)
    (if (or (zero? count) (null? values))
        '()
        (cons (car values) (take (cdr values) (- count 1)))))

  (define (navigation-history-commit! history jump arrived)
    (unless (and (navigation-history? history)
                 (navigation-jump? jump) (location? arrived))
      (assertion-violation
        'navigation-history-commit! "invalid navigation commit"
        history jump arrived))
    (if (not (eq? jump (navigation-history-pending history)))
        #f
        (begin
          (case (navigation-jump-kind jump)
            [(jump)
             (let* ([cursor (navigation-jump-cursor jump)]
                    [prefix (take (navigation-history-entries history) cursor)])
               (navigation-history-entries-set!
                 history
                 (append prefix
                         (list (make-navigation-entry
                                 (navigation-jump-from jump) arrived))))
               (navigation-history-cursor-set! history (+ cursor 1)))]
            [(back)
             (navigation-history-cursor-set!
               history (- (navigation-jump-cursor jump) 1))]
            [(forward)
             (navigation-history-cursor-set!
               history (+ (navigation-jump-cursor jump) 1))])
          (navigation-history-pending-set! history #f)
          #t)))

  ;; A follow commits history before its View/Surface transaction publishes.
  ;; Until another jump begins, a failed transaction can restore the exact
  ;; pre-jump cursor and entry sequence without observing partial navigation.
  (define (navigation-history-rollback! history jump)
    (unless (and (navigation-history? history) (navigation-jump? jump))
      (assertion-violation
        'navigation-history-rollback! "invalid navigation rollback" history jump))
    (and (eq? history (navigation-jump-history jump))
         (= (navigation-history-serial history) (navigation-jump-serial jump))
         (not (navigation-history-pending history))
         (begin
           (navigation-history-entries-set! history (navigation-jump-entries jump))
           (navigation-history-cursor-set! history (navigation-jump-cursor jump))
           #t)))

  (define (navigation-history-cancel! history jump)
    (unless (and (navigation-history? history) (navigation-jump? jump))
      (assertion-violation
        'navigation-history-cancel! "invalid navigation cancellation"
        history jump))
    (and (eq? jump (navigation-history-pending history))
         (begin (navigation-history-pending-set! history #f) #t)))
)
