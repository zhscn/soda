(library (soda kernel range-set)
  (export make-range-value
          range-value?
          range-value-from
          range-value-to
          range-value-value
          range-value-start-affinity
          range-value-end-affinity
          range-value-map-mode
          range-value-point?
          make-range-set
          range-set?
          range-set-ranges
          range-set-empty?
          range-set-query
          range-set-query-point
          range-set-update
          make-range-set-builder
          range-set-builder?
          range-set-builder-add!
          range-set-builder-finish!
          make-range-span
          range-span?
          range-span-from
          range-span-to
          range-span-values
          range-span-points
          range-set-spans
          range-set-cursor
          range-set-sweep-cursor
          range-cursor?
          range-cursor-done?
          range-cursor-current
          range-cursor-next!
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
      (immutable end-affinity range-value-end-affinity)
      (immutable map-mode range-value-map-mode)
      (immutable point range-value-point?)))

  (define valid-affinities '(before after))
  (define valid-map-modes '(retain drop))

  (define make-range-value
    (case-lambda
      [(from to value)
       (make-range-value from to value 'after 'after 'retain #f)]
      [(from to value affinity)
       (make-range-value from to value affinity affinity 'retain #f)]
      [(from to value start-affinity end-affinity)
       (make-range-value
         from to value start-affinity end-affinity 'retain #f)]
      [(from to value start-affinity end-affinity map-mode)
       (make-range-value
         from to value start-affinity end-affinity map-mode #f)]
      [(from to value start-affinity end-affinity map-mode point?)
       (unless (and (exact-integer? from) (exact-integer? to)
                    (>= from 0) (>= to from))
         (assertion-violation 'make-range-value "invalid range" from to))
       (unless (memq start-affinity valid-affinities)
         (assertion-violation
           'make-range-value "invalid start affinity" start-affinity))
       (unless (memq end-affinity valid-affinities)
         (assertion-violation
           'make-range-value "invalid end affinity" end-affinity))
       (unless (memq map-mode valid-map-modes)
         (assertion-violation
           'make-range-value "invalid deletion map mode" map-mode))
       (unless (boolean? point?)
         (assertion-violation
           'make-range-value "point flag must be boolean" point?))
       (%make-range-value
         from to value start-affinity end-affinity map-mode point?)]))

  (define-record-type
    (range-set %make-range-set range-set?)
    (fields
      (immutable ranges range-set-ranges)
      (immutable index range-set-index)
      (immutable prefix-max-end range-set-prefix-max-end)))

  (define-record-type
    (range-set-builder %make-range-set-builder range-set-builder?)
    (fields
      (mutable ranges range-set-builder-ranges range-set-builder-ranges-set!)
      (mutable last range-set-builder-last range-set-builder-last-set!)
      (mutable finished? range-set-builder-finished? range-set-builder-finished?-set!)
      (mutable result range-set-builder-result range-set-builder-result-set!)))

  (define (make-range-set-builder)
    (%make-range-set-builder '() #f #f #f))

  (define (range-before? left right)
    (or (< (range-value-from left) (range-value-from right))
        (and (= (range-value-from left) (range-value-from right))
             (<= (range-value-to left) (range-value-to right)))))

  (define (range-set-builder-add! builder . arguments)
    (unless (range-set-builder? builder)
      (assertion-violation
        'range-set-builder-add! "expected a range set builder" builder))
    (when (range-set-builder-finished? builder)
      (assertion-violation
        'range-set-builder-add! "builder has already been finished" builder))
    (let ([range
            (cond
              [(= (length arguments) 1) (car arguments)]
              [(= (length arguments) 3)
               (apply make-range-value arguments)]
              [else
               (assertion-violation
                 'range-set-builder-add!
                 "expected a range or from, to, value"
                 arguments)])])
      (unless (range-value? range)
        (assertion-violation
          'range-set-builder-add! "expected a range value" range))
      (let ([last (range-set-builder-last builder)])
        (when (and last (not (range-before? last range)))
          (assertion-violation
            'range-set-builder-add!
            "ranges must be added in sorted order"
            last range)))
      (range-set-builder-last-set! builder range)
      (range-set-builder-ranges-set!
        builder
        (cons range (range-set-builder-ranges builder)))
      builder))

  (define (range-set-builder-finish! builder)
    (unless (range-set-builder? builder)
      (assertion-violation
        'range-set-builder-finish! "expected a range set builder" builder))
    (if (range-set-builder-finished? builder)
        (range-set-builder-result builder)
        (let ([result
                (make-range-set
                  (reverse (range-set-builder-ranges builder)))])
          (range-set-builder-result-set! builder result)
          (range-set-builder-finished?-set! builder #t)
          result)))

  (define-record-type
    (range-span %make-range-span range-span?)
    (fields
      (immutable from range-span-from)
      (immutable to range-span-to)
      (immutable values range-span-values)
      (immutable points range-span-points)))

  (define (make-range-span from to values points)
    (unless (and (exact-integer? from) (exact-integer? to)
                 (>= from 0) (>= to from)
                 (list? values) (list? points)
                 (for-all range-value? values)
                 (for-all range-value? points))
      (assertion-violation
        'make-range-span "invalid range span" from to values points))
    (%make-range-span from to (list-copy values) (list-copy points)))

  ;; A cursor is a short-lived query object.  The RangeSet remains immutable;
  ;; only the cursor position advances while a renderer sweeps a viewport.
  (define-record-type
    (range-cursor %make-range-cursor range-cursor?)
    (fields
      (immutable index range-cursor-index)
      (immutable from range-cursor-from)
      (immutable to range-cursor-to)
      (mutable position range-cursor-position range-cursor-position-set!)))

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

  ;; Point queries include a zero-width value anchored at POINT as well as
  ;; ordinary half-open ranges containing POINT.  The interval query above
  ;; intentionally keeps its half-open semantics for viewport spans.
  (define (range-set-query-point value point)
    (unless (range-set? value)
      (assertion-violation
        'range-set-query-point "expected a range set" value))
    (unless (and (exact-integer? point) (>= point 0))
      (assertion-violation
        'range-set-query-point "point must be a non-negative integer" point))
    (let* ([index (range-set-index value)]
           [prefix (range-set-prefix-max-end value)]
           [start
             (let loop ([low 0] [high (vector-length prefix)])
               (if (>= low high)
                   low
                   (let ([middle (div (+ low high) 2)])
                     (if (>= (vector-ref prefix middle) point)
                         (loop low middle)
                         (loop (+ middle 1) high)))))])
      (let loop ([position start] [result '()])
        (if (>= position (vector-length index))
            (reverse result)
            (let* ([range (vector-ref index position)]
                   [from (range-value-from range)]
                   [to (range-value-to range)]
                   [matches (or (and (= from to) (= from point))
                                (and (<= from point) (< point to)))])
              (if (> from point)
                  (reverse result)
                  (loop
                    (+ position 1)
                    (if matches (cons range result) result))))))))

  (define (unique-sorted-integers values)
    (let loop ([items (list-sort < values)] [result '()])
      (if (null? items)
          (reverse result)
          (if (and (pair? result) (= (car result) (car items)))
              (loop (cdr items) result)
              (loop (cdr items) (cons (car items) result))))))

  ;; Update a set by filtering existing values and merging sorted additions.
  ;; The operation keeps the RangeSet immutable and returns the original
  ;; object for the empty update path.
  (define (range-set-update value additions . filter-procedure)
    (unless (range-set? value)
      (assertion-violation 'range-set-update "expected a range set" value))
    (unless (and (list? additions) (for-all range-value? additions))
      (assertion-violation
        'range-set-update "additions must be a list of range values" additions))
    (unless (or (null? filter-procedure)
                (and (pair? filter-procedure)
                     (null? (cdr filter-procedure))
                     (procedure? (car filter-procedure))))
      (assertion-violation
        'range-set-update "filter must be a single procedure" filter-procedure))
    (if (and (null? additions) (null? filter-procedure))
        value
        (let* ([predicate
                 (if (null? filter-procedure)
                     (lambda (range) #t)
                     (car filter-procedure))]
               [kept (filter predicate (range-set-ranges value))]
               [merged
                 (list-sort
                   range-before?
                   (append kept (list-copy additions)))])
          (make-range-set merged))))

  ;; Produce contiguous spans with the active non-point values and point
  ;; values that begin at each span boundary.  This is the common input to a
  ;; face/decorations merger; callers do not need to rescan every cell.
  (define (range-set-spans value from to)
    (unless (range-set? value)
      (assertion-violation 'range-set-spans "expected a range set" value))
    (unless (valid-query? from to)
      (assertion-violation 'range-set-spans "invalid query range" from to))
    (let* ([relevant
             (filter
               (lambda (range)
                 (if (range-value-point? range)
                     (and (<= from (range-value-from range))
                          (<= (range-value-from range) to))
                     (and (< (range-value-from range) to)
                          (> (range-value-to range) from))))
               (range-set-ranges value))]
           [boundaries
             (unique-sorted-integers
               (cons from
                 (cons to
                   (fold-left
                     (lambda (result range)
                       (if (range-value-point? range)
                           (cons (range-value-from range) result)
                           (cons (range-value-to range)
                             (cons (range-value-from range) result))))
                     '()
                     relevant))))])
      (let loop ([positions boundaries] [result '()])
        (if (null? positions)
            (reverse result)
            (let* ([start (car positions)]
                   [rest (cdr positions)]
                   [end (if (null? rest) start (car rest))]
                   [points
                     (filter
                       (lambda (range)
                         (and (range-value-point? range)
                              (= (range-value-from range) start)))
                       relevant)]
                   [active
                     (filter
                       (lambda (range)
                         (and (not (range-value-point? range))
                              (<= (range-value-from range) start)
                              (< start (range-value-to range))))
                       relevant)]
                   [span
                     (and (or (< start end) (pair? points))
                          (make-range-span start end active points))])
              (loop
                rest
                (if span (cons span result) result)))))))

  (define (range-cursor-advance-to-match! cursor)
    (let ([index (range-cursor-index cursor)]
          [from (range-cursor-from cursor)]
          [to (range-cursor-to cursor)])
      (let loop ([position (range-cursor-position cursor)])
        (if (>= position (vector-length index))
            (begin
              (range-cursor-position-set! cursor position)
              #f)
            (let ([range (vector-ref index position)])
              (if (or (>= (range-value-from range) to)
                      (<= (range-value-to range) from))
                  (loop (+ position 1))
                  (begin
                    (range-cursor-position-set! cursor position)
                    range)))))))

  (define (range-set-sweep-cursor value from to)
    (unless (range-set? value)
      (assertion-violation
        'range-set-sweep-cursor "expected a range set" value))
    (unless (valid-query? from to)
      (assertion-violation
        'range-set-sweep-cursor "invalid query range" from to))
    (let ([cursor
            (%make-range-cursor
              (range-set-index value)
              from to
              (range-set-first-index value from))])
      (range-cursor-advance-to-match! cursor)
      cursor))

  ;; Compatibility query retained for callers that used the original API.
  ;; New rendering code should use range-set-sweep-cursor.
  (define (range-set-cursor value from to)
    (range-set-query value from to))

  (define (range-cursor-current cursor)
    (unless (range-cursor? cursor)
      (assertion-violation 'range-cursor-current "expected a range cursor" cursor))
    (range-cursor-advance-to-match! cursor))

  (define (range-cursor-done? cursor)
    (not (range-cursor-current cursor)))

  (define (range-cursor-next! cursor)
    (unless (range-cursor? cursor)
      (assertion-violation 'range-cursor-next! "expected a range cursor" cursor))
    (let ([current (range-cursor-current cursor)])
      (when current
        (range-cursor-position-set!
          cursor
          (+ 1 (range-cursor-position cursor))))
      (range-cursor-current cursor)))

  (define (range-set-map value mapper)
    (unless (range-set? value)
      (assertion-violation 'range-set-map "expected a range set" value))
    (unless (procedure? mapper)
      (assertion-violation 'range-set-map "mapper must be a procedure" mapper))
    ;; Preserve the existing immutable set when the mapper leaves every
    ;; value unchanged.  This is the common path for state effects that do
    ;; not intersect a range and avoids rebuilding the index.
    (let loop ([items (range-set-ranges value)]
               [result '()]
               [changed? #f])
      (if (null? items)
          (if changed? (make-range-set (reverse result)) value)
          (let* ([range (car items)]
                 [mapped (mapper range)])
            (unless (range-value? mapped)
              (assertion-violation
                'range-set-map "mapper must return range values" mapped))
            (loop
              (cdr items)
              (cons mapped result)
              (or changed? (not (eq? mapped range))))))))

  (define (range-set-map-change value changes)
    (unless (and (range-set? value)
                 (or (change-set? changes) (change-desc? changes)))
      (assertion-violation
        'range-set-map-change "expected a range set and ChangeSet or ChangeDesc"
        value changes))
    (let* ([change-list
             (if (change-set? changes)
                 (change-set-changes changes)
                 (change-desc-changes changes))]
           [empty? (null? change-list)]
           [map-offset
             (lambda (offset affinity)
               (if (change-set? changes)
                   (change-set-map-offset changes offset affinity)
                   (change-desc-map-offset changes offset affinity)))]
           [touches-deletion?
             (lambda (range)
               (let loop ([items change-list])
                 (and (pair? items)
                      (let ([change (car items)])
                        (or (and (< (text-change-from change)
                                    (text-change-to change))
                                 (< (range-value-from range)
                                    (text-change-to change))
                                 (> (range-value-to range)
                                    (text-change-from change)))
                            (loop (cdr items)))))))]
           [map-range
             (lambda (range)
               (let* ([mapped-from
                        (map-offset
                          (range-value-from range)
                          (range-value-start-affinity range))]
                      [mapped-to
                        (map-offset
                          (range-value-to range)
                          (range-value-end-affinity range))]
                      ;; Opposite affinities can meet in the middle of a
                      ;; replaced range.  A range remains non-inverted by
                      ;; collapsing to the boundary that excludes the
                      ;; replaced text.
                      [inverted? (> mapped-from mapped-to)]
                      [collapsed (if inverted? mapped-to mapped-from)])
                 (let ([new-from (if inverted? collapsed mapped-from)]
                       [new-to (if inverted? collapsed mapped-to)])
                   (if (and (= new-from (range-value-from range))
                            (= new-to (range-value-to range)))
                       range
                       (make-range-value
                         new-from
                         new-to
                         (range-value-value range)
                         (range-value-start-affinity range)
                         (range-value-end-affinity range)
                         (range-value-map-mode range)
                         (range-value-point? range))))))])
      (if empty?
          value
          (let loop ([items (range-set-ranges value)]
                     [result '()]
                     [changed? #f])
            (if (null? items)
                (if changed? (make-range-set (reverse result)) value)
                (let ([range (car items)])
                  (if (and (eq? (range-value-map-mode range) 'drop)
                           (touches-deletion? range))
                      (loop (cdr items) result #t)
                      (let ([mapped (map-range range)])
                        (loop
                          (cdr items)
                          (cons mapped result)
                          (or changed? (not (eq? mapped range)))))))))))
))
