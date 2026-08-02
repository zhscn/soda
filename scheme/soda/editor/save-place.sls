(library (soda editor save-place)
  (export make-save-place
          save-place?
          save-place-resource
          save-place-point
          save-place-first-line
          save-place-first-visual-row
          save-place-first-column
          save-place-mark
          normalize-save-places)
  (import (rnrs)
          (soda editor contract))

  (define-record-type
    (save-place %make-save-place save-place?)
    (fields resource
            point
            first-line
            first-visual-row
            first-column
            mark))

  (define (make-save-place
            resource point first-line first-visual-row first-column mark)
    (unless
      (and (non-empty-string? resource)
           (exact-non-negative-integer? point)
           (exact-non-negative-integer? first-line)
           (exact-non-negative-integer? first-visual-row)
           (exact-non-negative-integer? first-column)
           (or (not mark) (exact-non-negative-integer? mark)))
      (assertion-violation
        'make-save-place "invalid save place" resource point))
    (%make-save-place
      resource point first-line first-visual-row first-column mark))

  (define (normalize-save-places places)
    (unless (and (list? places) (for-all save-place? places))
      (assertion-violation
        'normalize-save-places "expected save places" places))
    (let loop ([remaining places] [seen '()] [kept '()])
      (if (null? remaining)
          (reverse kept)
          (let* ([entry (car remaining)]
                 [resource (save-place-resource entry)])
            (if (member resource seen)
                (loop (cdr remaining) seen kept)
                (loop (cdr remaining)
                      (cons resource seen)
                      (cons entry kept))))))))
