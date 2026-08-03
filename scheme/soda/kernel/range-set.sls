(library (soda kernel range-set)
  (export make-range-value
          range-value?
          range-value-from
          range-value-to
          range-value-value
          make-range-set
          range-set?
          range-set-ranges
          range-set-empty?
          range-set-query
          range-set-cursor
          range-set-map
          range-set-map-change)
  (import (rnrs)
          (soda kernel value)
          (soda kernel change))

  (define-record-type
    (range-value %make-range-value range-value?)
    (fields
      (immutable from range-value-from)
      (immutable to range-value-to)
      (immutable value range-value-value)))

  (define (make-range-value from to value)
    (unless (and (exact-integer? from) (exact-integer? to)
                 (>= from 0) (>= to from))
      (assertion-violation 'make-range-value "invalid range" from to))
    (%make-range-value from to value))

  (define-record-type
    (range-set %make-range-set range-set?)
    (fields (immutable ranges range-set-ranges)))

  (define (range-order? ranges)
    (let loop ([items ranges] [end 0])
      (or (null? items)
          (and (range-value? (car items))
               (>= (range-value-from (car items)) end)
               (loop (cdr items) (range-value-to (car items)))))))

  (define (make-range-set ranges)
    (unless (and (list? ranges) (range-order? ranges))
      (assertion-violation
        'make-range-set "ranges must be ordered and non-overlapping" ranges))
    (%make-range-set (list-copy ranges)))

  (define (range-set-empty? value)
    (unless (range-set? value)
      (assertion-violation 'range-set-empty? "expected a range set" value))
    (null? (range-set-ranges value)))

  (define (range-set-query value from to)
    (unless (range-set? value)
      (assertion-violation 'range-set-query "expected a range set" value))
    (filter
      (lambda (range)
        (and (< (range-value-from range) to)
             (> (range-value-to range) from)))
      (range-set-ranges value)))

  ;; A cursor is represented as the ordered intersecting range sequence.  It
  ;; keeps the renderer independent of the storage representation and can be
  ;; replaced by a tree cursor without changing callers.
  (define (range-set-cursor value from to)
    (range-set-query value from to))

  (define (range-set-map value mapper)
    (unless (range-set? value)
      (assertion-violation 'range-set-map "expected a range set" value))
    (unless (procedure? mapper)
      (assertion-violation 'range-set-map "mapper must be a procedure" mapper))
    (make-range-set
      (map
        (lambda (range)
          (let ([mapped (mapper range)])
            (unless (range-value? mapped)
              (assertion-violation
                'range-set-map "mapper must return range values" mapped))
            mapped))
        (range-set-ranges value))))

  (define (range-set-map-change value changes)
    (unless (change-set? changes)
      (assertion-violation 'range-set-map-change "expected a change set" changes))
    (range-set-map
      value
      (lambda (range)
        (let ([mapped (change-set-map-range
                        changes (range-value-from range) (range-value-to range)
                        'after)])
          (make-range-value
            (car mapped) (cdr mapped) (range-value-value range))))))
)
