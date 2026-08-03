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
          selection-primary-range
          change-by-range)
  (import (rnrs)
          (soda kernel value)
          (soda kernel change))

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
      [(ranges) (make-selection ranges 0 'merge)]
      [(ranges primary)
       (make-selection ranges primary 'merge)]
      [(ranges primary overlap-policy)
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
       (unless (memq overlap-policy '(merge reject))
         (assertion-violation
           'make-selection "overlap policy must be merge or reject"
           overlap-policy))
       (let* ([indexed
               (let loop ([items ranges] [index 0] [result '()])
                 (if (null? items)
                     (reverse result)
                     (loop
                       (cdr items) (+ index 1)
                       (cons (cons index (car items)) result))))]
              [ordered
               (list-sort
                 (lambda (left right)
                   (let ([left-range (cdr left)] [right-range (cdr right)])
                     (or (< (selection-range-from left-range)
                            (selection-range-from right-range))
                         (and
                           (= (selection-range-from left-range)
                              (selection-range-from right-range))
                           (< (selection-range-to left-range)
                              (selection-range-to right-range))))))
                 indexed)])
         (define (merged-range entries from to)
           (let* ([entries (reverse entries)]
                  [primary-entry
                   (let find ([items entries])
                     (cond
                       [(null? items) #f]
                       [(= (caar items) primary) (car items)]
                       [else (find (cdr items))]))]
                  [representative (cdr (or primary-entry (car entries)))]
                  [forward?
                   (<= (selection-range-anchor representative)
                       (selection-range-head representative))])
             (make-selection-range
               (if forward? from to)
               (if forward? to from)
               (selection-range-affinity representative)
               (selection-range-granularity representative)
               (selection-range-metadata representative))))
         (let loop ([items (cdr ordered)]
                    [group (list (car ordered))]
                    [from (selection-range-from (cdar ordered))]
                    [to (selection-range-to (cdar ordered))]
                    [result '()]
                    [result-primary #f])
           (if (null? items)
               (let* ([contains-primary? (exists (lambda (entry) (= (car entry) primary)) group)]
                      [result-primary
                       (if contains-primary? (length result) result-primary)]
                      [result (cons (merged-range group from to) result)])
                 (%make-selection
                   (reverse result)
                   (or result-primary 0)))
               (let* ([entry (car items)]
                      [range (cdr entry)]
                      [next-from (selection-range-from range)]
                      [next-to (selection-range-to range)])
                 (if (<= next-from to)
                     (if (eq? overlap-policy 'reject)
                         (assertion-violation
                           'make-selection "selection ranges overlap"
                           (map cdr (reverse (cons entry group))))
                         (loop
                           (cdr items) (cons entry group)
                           from (max to next-to) result result-primary))
                     (let* ([contains-primary?
                             (exists (lambda (item) (= (car item) primary)) group)]
                            [result-primary
                             (if contains-primary? (length result) result-primary)])
                       (loop
                         (cdr items) (list entry) next-from next-to
                         (cons (merged-range group from to) result)
                         result-primary)))))))]))

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
    (unless (or (change-set? changes) (change-desc? changes))
      (assertion-violation
        'selection-map-change "expected a ChangeSet or ChangeDesc" changes))
    (let ([map-offset
            (lambda (offset affinity)
              (if (change-set? changes)
                  (change-set-map-offset changes offset affinity)
                  (change-desc-map-offset changes offset affinity)))])
    (selection-map
      selection
      (lambda (range)
        (make-selection-range
          (map-offset (selection-range-anchor range)
                      (selection-range-affinity range))
          (map-offset (selection-range-head range)
                      (selection-range-affinity range))
          (selection-range-affinity range)
          (selection-range-granularity range)
          (selection-range-metadata range))))))

  ;; Run one edit producer per selection range and merge the independently
  ;; authored change sets with the same mapping algebra used for transaction
  ;; specs. The producer returns two values: a ChangeSet in the starting
  ;; document and a SelectionRange in the document produced by that set.
  (define (change-by-range selection old-length procedure)
    (unless (and (selection? selection)
                 (exact-integer? old-length) (>= old-length 0)
                 (procedure? procedure))
      (assertion-violation
        'change-by-range "expected a selection, document length, and procedure"))
    (let loop ([items (selection-ranges selection)]
               [total (make-change-set old-length '())]
               [ranges '()])
      (if (null? items)
          (values
            total
            (make-selection
              (reverse ranges)
              (selection-primary selection)
              'merge))
          (call-with-values
            (lambda () (procedure (car items)))
            (lambda (changes range)
              (unless (and (change-set? changes)
                           (= (change-set-old-length changes) old-length)
                           (selection-range? range))
                (assertion-violation
                  'change-by-range
                  "producer must return a compatible ChangeSet and SelectionRange"
                  changes range))
              (let* ([mapped (change-set-map changes total)]
                     [mapped-existing
                      (map
                        (lambda (existing)
                          (car
                            (selection-ranges
                              (selection-map-change
                                (make-selection (list existing)) mapped))))
                        ranges)]
                     [map-by (change-set-map total changes #t)]
                     [mapped-range
                      (car
                        (selection-ranges
                          (selection-map-change
                            (make-selection (list range)) map-by)))])
                (loop
                  (cdr items)
                  (change-set-compose total mapped)
                  (cons mapped-range mapped-existing))))))))
)
