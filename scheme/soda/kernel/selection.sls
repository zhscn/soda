(library (soda kernel selection)
  (export make-selection-range
          selection-range?
          selection-range-anchor
          selection-range-head
          selection-range-affinity
          selection-range-granularity
          selection-range-metadata
          selection-range-empty?
          selection-range-from
          selection-range-to
          make-selection
          selection?
          selection-ranges
          selection-primary
          selection-range-at
          selection-map
          selection-map-change
          selection-primary-range)
  (import (rnrs)
          (soda kernel value)
          (soda kernel change))

  (define (copy-list value)
    (if (null? value) '() (cons (car value) (copy-list (cdr value)))))

  (define valid-affinities '(before after))
  (define valid-granularities '(character line block node))

  (define (valid-offset? value)
    (and (exact-integer? value) (>= value 0)))

  (define-record-type
    (selection-range %make-selection-range selection-range?)
    (fields
      (immutable anchor selection-range-anchor)
      (immutable head selection-range-head)
      (immutable affinity selection-range-affinity)
      (immutable granularity selection-range-granularity)
      (immutable metadata selection-range-metadata)))

  (define make-selection-range
    (case-lambda
      [(anchor head)
       (make-selection-range anchor head 'before 'character '())]
      [(anchor head affinity granularity metadata)
       (unless (and (valid-offset? anchor) (valid-offset? head))
         (assertion-violation
           'make-selection-range
           "anchor and head must be non-negative exact integers"
           anchor head))
       (unless (memq affinity valid-affinities)
         (assertion-violation
           'make-selection-range "invalid affinity" affinity))
       (unless (memq granularity valid-granularities)
         (assertion-violation
           'make-selection-range "invalid granularity" granularity))
       (%make-selection-range anchor head affinity granularity metadata)]))

  (define (selection-range-empty? range)
    (unless (selection-range? range)
      (assertion-violation 'selection-range-empty? "expected a selection range" range))
    (= (selection-range-anchor range) (selection-range-head range)))

  (define (selection-range-from range)
    (unless (selection-range? range)
      (assertion-violation 'selection-range-from "expected a selection range" range))
    (min (selection-range-anchor range) (selection-range-head range)))

  (define (selection-range-to range)
    (unless (selection-range? range)
      (assertion-violation 'selection-range-to "expected a selection range" range))
    (max (selection-range-anchor range) (selection-range-head range)))

  (define-record-type
    (selection %make-selection selection?)
    (fields
      (immutable ranges selection-ranges)
      (immutable primary selection-primary)))

  (define (proper-range-list? value)
    (and (pair? value)
         (let loop ([items value])
           (or (null? items)
               (and (selection-range? (car items))
                    (loop (cdr items)))))))

  (define make-selection
    (case-lambda
      [(ranges) (make-selection ranges 0)]
      [(ranges primary)
       (unless (proper-range-list? ranges)
         (assertion-violation
           'make-selection
           "ranges must be a non-empty list of selection ranges"
           ranges))
       (unless (and (exact-integer? primary)
                    (>= primary 0)
                    (< primary (length ranges)))
         (assertion-violation
           'make-selection "primary index is outside ranges" primary))
       (%make-selection (copy-list ranges) primary)]))

  (define (selection-range-at selection index)
    (unless (selection? selection)
      (assertion-violation 'selection-range-at "expected a selection" selection))
    (unless (and (exact-integer? index)
                 (>= index 0)
                 (< index (length (selection-ranges selection))))
      (assertion-violation 'selection-range-at "index is outside ranges" index))
    (list-ref (selection-ranges selection) index))

  (define (selection-primary-range selection)
    (selection-range-at selection (selection-primary selection)))

  (define (selection-map selection mapper)
    (unless (selection? selection)
      (assertion-violation 'selection-map "expected a selection" selection))
    (unless (procedure? mapper)
      (assertion-violation 'selection-map "mapper must be a procedure" mapper))
    (make-selection
      (map
        (lambda (range)
          (let ([mapped (mapper range)])
            (unless (selection-range? mapped)
              (assertion-violation
                'selection-map "mapper must return selection ranges" mapped))
            mapped))
        (selection-ranges selection))
      (selection-primary selection)))

  (define (selection-map-change selection changes)
    (unless (change-set? changes)
      (assertion-violation 'selection-map-change "expected a change set" changes))
    (selection-map
      selection
      (lambda (range)
        (make-selection-range
          (change-set-map-offset changes (selection-range-anchor range)
                                  (selection-range-affinity range))
          (change-set-map-offset changes (selection-range-head range)
                                  (selection-range-affinity range))
          (selection-range-affinity range)
          (selection-range-granularity range)
          (selection-range-metadata range)))))
)
