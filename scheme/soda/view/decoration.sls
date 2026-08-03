(library (soda view decoration)
  (export make-face-decoration
          face-decoration?
          face-decoration-face
          face-decoration-priority
          make-decoration-set
          decoration-set?
          merge-decoration-sets
          decoration-face)
  (import (rnrs)
          (soda kernel range-set))

  (define-record-type
    (face-decoration %make-face-decoration face-decoration?)
    (fields face priority))

  (define (make-face-decoration face priority)
    (unless (and (symbol? face) (integer? priority) (exact? priority))
      (assertion-violation 'make-face-decoration "invalid face decoration" face priority))
    (%make-face-decoration face priority))

  ;; DecorationSet is an immutable RangeSet whose values are decorations.
  (define (decoration-set? value) (range-set? value))

  (define (make-decoration-set ranges)
    (unless (and (list? ranges)
                 (for-all (lambda (range)
                            (and (range-value? range)
                                 (face-decoration? (range-value-value range))))
                          ranges))
      (assertion-violation 'make-decoration-set "invalid decoration ranges" ranges))
    (make-range-set ranges))

  (define (merge-decoration-sets sets)
    (unless (and (list? sets) (for-all decoration-set? sets))
      (assertion-violation 'merge-decoration-sets "expected DecorationSets" sets))
    (range-set-update
      (make-range-set '())
      (apply append (map range-set-ranges sets))))

  (define (decoration-face ranges fallback)
    (let loop ([remaining ranges] [winner #f])
      (if (null? remaining)
          (if winner (face-decoration-face winner) fallback)
          (let ([candidate (range-value-value (car remaining))])
            (loop (cdr remaining)
                  (if (or (not winner)
                          (> (face-decoration-priority candidate)
                             (face-decoration-priority winner)))
                      candidate
                      winner))))))
)
