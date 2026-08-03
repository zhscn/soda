(library (soda tui layout)
  (export make-fixed-extent
          make-flex-extent
          layout-extent?
          layout-extent-kind
          layout-extent-amount
          layout-split)
  (import (rnrs)
          (soda tui frame))

  (define-record-type (layout-extent %make-layout-extent layout-extent?)
    (fields kind amount))

  (define (positive-exact-integer? value)
    (and (integer? value) (exact? value) (positive? value)))

  (define (make-fixed-extent cells)
    (unless
      (and (integer? cells) (exact? cells) (not (negative? cells)))
      (assertion-violation
        'make-fixed-extent
        "fixed extent must be a non-negative exact integer"
        cells))
    (%make-layout-extent 'fixed cells))

  (define (make-flex-extent weight)
    (unless (positive-exact-integer? weight)
      (assertion-violation
        'make-flex-extent
        "flex weight must be a positive exact integer"
        weight))
    (%make-layout-extent 'flex weight))

  (define (fixed-total extents)
    (fold-left
      (lambda (total extent)
        (if (eq? (layout-extent-kind extent) 'fixed)
            (+ total (layout-extent-amount extent))
            total))
      0
      extents))

  (define (flex-total extents)
    (fold-left
      (lambda (total extent)
        (if (eq? (layout-extent-kind extent) 'flex)
            (+ total (layout-extent-amount extent))
            total))
      0
      extents))

  (define (base-flex-allocations extents available total-weight)
    (map
      (lambda (extent)
        (if (eq? (layout-extent-kind extent) 'flex)
            (div
              (* available (layout-extent-amount extent))
              total-weight)
            0))
      extents))

  (define (distribute-flex-remainder
            extents
            allocations
            remainder)
    (let loop ([extents extents]
               [allocations allocations]
               [remaining remainder])
      (if (null? extents)
          '()
          (let ([flex?
                  (eq? (layout-extent-kind (car extents)) 'flex)])
            (cons
              (+ (car allocations)
                 (if (and flex? (positive? remaining)) 1 0))
              (loop
                (cdr extents)
                (cdr allocations)
                (if (and flex? (positive? remaining))
                    (- remaining 1)
                    remaining)))))))

  (define (extent-allocations total extents)
    (let* ([fixed (fixed-total extents)]
           [flex-weight (flex-total extents)])
      (if (> fixed total)
          (let loop ([remaining total] [extents extents])
            (if (null? extents)
                '()
                (let* ([extent (car extents)]
                       [allocation
                         (if (eq? (layout-extent-kind extent) 'fixed)
                             (min
                               remaining
                               (layout-extent-amount extent))
                             0)])
                  (cons
                    allocation
                    (loop
                      (- remaining allocation)
                      (cdr extents))))))
          (let ([available (- total fixed)])
            (if (zero? flex-weight)
                (map
                  (lambda (extent)
                    (if (eq? (layout-extent-kind extent) 'fixed)
                        (layout-extent-amount extent)
                        0))
                  extents)
                (let* ([base
                        (base-flex-allocations
                          extents
                          available
                          flex-weight)]
                       [used (fold-left + 0 base)]
                       [flex
                         (distribute-flex-remainder
                           extents
                           base
                           (- available used))])
                  (map
                    (lambda (extent flex-allocation)
                      (if (eq? (layout-extent-kind extent) 'fixed)
                          (layout-extent-amount extent)
                          flex-allocation))
                    extents
                    flex)))))))

  (define (layout-split rectangle orientation extents)
    (unless (rect? rectangle)
      (assertion-violation
        'layout-split
        "expected a rectangle"
        rectangle))
    (unless (memq orientation '(horizontal vertical))
      (assertion-violation
        'layout-split
        "orientation must be horizontal or vertical"
        orientation))
    (unless
      (and (list? extents) (for-all layout-extent? extents))
      (assertion-violation
        'layout-split
        "extents must be a list of layout extents"
        extents))
    (let* ([total
             (if (eq? orientation 'vertical)
                 (rect-rows rectangle)
                 (rect-columns rectangle))]
           [allocations (extent-allocations total extents)])
      (let loop ([allocations allocations] [offset 0])
        (if (null? allocations)
            '()
            (let ([amount (car allocations)])
              (cons
                (if (eq? orientation 'vertical)
                    (make-rect
                      (+ (rect-row rectangle) offset)
                      (rect-column rectangle)
                      amount
                      (rect-columns rectangle))
                    (make-rect
                      (rect-row rectangle)
                      (+ (rect-column rectangle) offset)
                      (rect-rows rectangle)
                      amount))
                (loop
                  (cdr allocations)
                  (+ offset amount)))))))))
