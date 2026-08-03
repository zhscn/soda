(library (soda kernel range-set)
  (export make-range-value
          range-value?
          range-value-from
          range-value-to
          range-value-value
          range-value-start-affinity
          range-value-end-affinity
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
      (immutable value range-value-value)
      (immutable start-affinity range-value-start-affinity)
      (immutable end-affinity range-value-end-affinity)))

  (define valid-affinities '(before after))

  (define make-range-value
    (case-lambda
      [(from to value)
       (make-range-value from to value 'after 'after)]
      [(from to value affinity)
       (make-range-value from to value affinity affinity)]
      [(from to value start-affinity end-affinity)
       (unless (and (exact-integer? from) (exact-integer? to)
                    (>= from 0) (>= to from))
         (assertion-violation 'make-range-value "invalid range" from to))
       (unless (memq start-affinity valid-affinities)
         (assertion-violation
           'make-range-value "invalid start affinity" start-affinity))
       (unless (memq end-affinity valid-affinities)
         (assertion-violation
           'make-range-value "invalid end affinity" end-affinity))
       (%make-range-value
         from to value start-affinity end-affinity)]))

  (define-record-type
    (range-set %make-range-set range-set?)
    (fields
      (immutable ranges range-set-ranges)
      (immutable index range-set-index)
      (immutable prefix-max-end range-set-prefix-max-end)))

  (define (range-order? ranges)
    (let loop ([items ranges] [previous-from 0] [previous-to 0])
      (or (null? items)
          (and (range-value? (car items))
               (let ([from (range-value-from (car items))]
                     [to (range-value-to (car items))])
                 (and (or (> from previous-from)
                          (and (= from previous-from) (>= to previous-to)))
                      (loop (cdr items) from to)))))))

  (define (prefix-max-ends ranges)
    (let ([output (make-vector (length ranges))])
      (let loop ([items ranges] [index 0] [maximum 0])
        (unless (null? items)
          (let* ([range (car items)]
                 [maximum (if (> (range-value-to range) maximum)
                              (range-value-to range)
                              maximum)])
            (vector-set! output index maximum)
            (loop (cdr items) (+ index 1) maximum))))
      output))

  (define (make-range-set ranges)
    (unless (and (list? ranges) (range-order? ranges))
      (assertion-violation
        'make-range-set "ranges must be ordered by start and end" ranges))
    (let ([copy (list-copy ranges)])
      (%make-range-set
        copy
        (list->vector copy)
        (prefix-max-ends copy))))

  (define (range-set-empty? value)
    (unless (range-set? value)
      (assertion-violation 'range-set-empty? "expected a range set" value))
    (null? (range-set-ranges value)))

  (define (valid-query? from to)
    (and (exact-integer? from)
         (exact-integer? to)
         (>= from 0)
         (>= to from)))

  ;; Return the first range whose end is strictly after FROM.  Ranges are
  ;; immutable and sorted, so a binary search avoids scanning decorations that
  ;; end before the visible query window.
  (define (range-set-first-index value from)
    (let ([prefix (range-set-prefix-max-end value)])
      (let loop ([low 0] [high (vector-length prefix)])
        (if (>= low high)
            low
            (let ([middle (div (+ low high) 2)])
              (if (> (vector-ref prefix middle) from)
                  (loop low middle)
                  (loop (+ middle 1) high)))))))

  (define (range-set-query value from to)
    (unless (range-set? value)
      (assertion-violation 'range-set-query "expected a range set" value))
    (unless (valid-query? from to)
      (assertion-violation 'range-set-query "invalid query range" from to))
    (let ([index (range-set-index value)]
          [start (range-set-first-index value from)])
      (let loop ([position start] [result '()])
        (if (>= position (vector-length index))
            (reverse result)
            (let ([range (vector-ref index position)])
              (if (>= (range-value-from range) to)
                  (reverse result)
                  (loop
                    (+ position 1)
                    (if (> (range-value-to range) from)
                        (cons range result)
                        result))))))))

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
    (unless (or (change-set? changes) (change-desc? changes))
      (assertion-violation
        'range-set-map-change "expected a ChangeSet or ChangeDesc" changes))
    (let ([map-offset
            (lambda (offset affinity)
              (if (change-set? changes)
                  (change-set-map-offset changes offset affinity)
                  (change-desc-map-offset changes offset affinity)))])
      (range-set-map
        value
        (lambda (range)
          (let* ([mapped-from
                   (map-offset
                     (range-value-from range)
                     (range-value-start-affinity range))]
                 [mapped-to
                   (map-offset
                     (range-value-to range)
                     (range-value-end-affinity range))]
                 ;; Opposite affinities can meet in the middle of a replaced
                 ;; range.  A range remains non-inverted by collapsing to the
                 ;; boundary that excludes the replaced text.
                 [collapsed (if (> mapped-from mapped-to)
                                mapped-to
                                mapped-from)])
            (make-range-value
              (if (> mapped-from mapped-to) collapsed mapped-from)
              (if (> mapped-from mapped-to) collapsed mapped-to)
              (range-value-value range)
              (range-value-start-affinity range)
              (range-value-end-affinity range)))))))
)
