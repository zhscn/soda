(library (soda packages input-history)
  (export make-input-history
          input-history?
          input-history-limit
          input-history-entries
          input-history-add!)
  (import (rnrs))

  ;; InputHistory stores accepted minibuffer values.  It is independent of
  ;; Document undo history and of the frontend used to browse it.
  (define-record-type
    (input-history %make-input-history input-history?)
    (fields
      (immutable limit input-history-limit)
      (mutable entries input-history-entries-raw input-history-entries-set!)))

  (define (make-input-history limit)
    (unless (and (integer? limit) (exact? limit) (> limit 0))
      (assertion-violation 'make-input-history
                           "history limit must be a positive exact integer"
                           limit))
    (%make-input-history limit '()))

  (define (input-history-entries history)
    (unless (input-history? history)
      (assertion-violation 'input-history-entries
                           "expected an InputHistory" history))
    (map string-copy (input-history-entries-raw history)))

  (define (take values count)
    (if (or (zero? count) (null? values))
        '()
        (cons (car values) (take (cdr values) (- count 1)))))

  (define (input-history-add! history value)
    (unless (and (input-history? history) (string? value))
      (assertion-violation 'input-history-add!
                           "expected an InputHistory and string" history value))
    (unless (string=? value "")
      (input-history-entries-set!
        history
        (take
          (cons (string-copy value)
                (filter (lambda (entry) (not (string=? entry value)))
                        (input-history-entries-raw history)))
          (input-history-limit history))))
    (input-history-entries history))
)
