(library (soda editor decoration)
  (export make-decoration-run
          decoration-run?
          decoration-run-start
          decoration-run-end
          decoration-run-face
          decoration-run-layer
          decoration-run-priority
          decoration-run-owner
          decoration-run-detail
          decoration-run-covers?
          make-decoration-index
          decoration-index?
          decoration-index-runs-in-range
          make-decoration-sweep
          decoration-sweep?
          decoration-sweep-runs-at!
          decoration-runs->styled-chunks
          styled-chunk?
          styled-chunk-start
          styled-chunk-end
          styled-chunk-runs
          make-styled-chunk-cursor
          styled-chunk-cursor?
          styled-chunk-cursor-at!
          decoration-runs-in-range)
  (import (rnrs))

  (define-record-type
    (decoration-run %make-decoration-run decoration-run?)
    (fields start end face layer priority owner detail))

  (define-record-type
    (decoration-index %make-decoration-index decoration-index?)
    (fields runs prefix-max-end))

  (define-record-type
    (decoration-sweep %make-decoration-sweep decoration-sweep?)
    (fields
      (mutable pending
               decoration-sweep-pending
               decoration-sweep-pending-set!)
      (mutable active
               decoration-sweep-active
               decoration-sweep-active-set!)
      (mutable position
               decoration-sweep-position
               decoration-sweep-position-set!)))

  (define-record-type styled-chunk
    (fields start end runs))

  (define-record-type
    (styled-chunk-cursor
      %make-styled-chunk-cursor
      styled-chunk-cursor?)
    (fields
      (mutable chunks
               styled-chunk-cursor-chunks
               styled-chunk-cursor-chunks-set!)
      (mutable position
               styled-chunk-cursor-position
               styled-chunk-cursor-position-set!)))

  (define valid-layers
    '(base-syntax semantic diagnostic search selection transient))

  (define (exact-integer? value)
    (and (integer? value) (exact? value)))

  (define (make-decoration-run
            start
            end
            face
            layer
            priority
            owner
            detail)
    (unless
      (and (exact-integer? start)
           (exact-integer? end)
           (<= 0 start)
           (< start end)
           (symbol? face)
           (memq layer valid-layers)
           (exact-integer? priority)
           (symbol? owner))
      (assertion-violation
        'make-decoration-run
        "invalid decoration run"
        start
        end
        face
        layer
        priority
        owner))
    (%make-decoration-run
      start end face layer priority owner detail))

  (define (decoration-run-covers? run position)
    (unless (decoration-run? run)
      (assertion-violation
        'decoration-run-covers?
        "expected a decoration run"
        run))
    (unless (and (exact-integer? position) (not (negative? position)))
      (assertion-violation
        'decoration-run-covers?
        "position must be a non-negative exact integer"
        position))
    (and (<= (decoration-run-start run) position)
         (< position (decoration-run-end run))))

  (define (layer-rank layer)
    (case layer
      [(base-syntax) 0]
      [(semantic) 1]
      [(diagnostic) 2]
      [(search) 3]
      [(selection) 4]
      [else 5]))

  (define (run-before? left right)
    (let ([left-layer (layer-rank (decoration-run-layer left))]
          [right-layer (layer-rank (decoration-run-layer right))])
      (cond
        [(< left-layer right-layer) #t]
        [(> left-layer right-layer) #f]
        [(< (decoration-run-priority left)
            (decoration-run-priority right))
         #t]
        [(> (decoration-run-priority left)
            (decoration-run-priority right))
         #f]
        [else
         (string<?
           (symbol->string (decoration-run-owner left))
           (symbol->string (decoration-run-owner right)))])))

  (define (insert-run run runs)
    (cond
      [(null? runs) (list run)]
      [(run-before? run (car runs)) (cons run runs)]
      [else (cons (car runs) (insert-run run (cdr runs)))]))

  (define (sort-runs runs)
    (list-sort run-before? runs))

  (define (run-position-before? left right)
    (cond
      [(< (decoration-run-start left)
          (decoration-run-start right))
       #t]
      [(> (decoration-run-start left)
          (decoration-run-start right))
       #f]
      [(< (decoration-run-end left)
          (decoration-run-end right))
       #t]
      [(> (decoration-run-end left)
          (decoration-run-end right))
       #f]
      [else (run-before? left right)]))

  (define (sort-positioned-runs runs)
    (list-sort run-position-before? runs))

  (define (require-run-list who runs)
    (unless (and (list? runs) (for-all decoration-run? runs))
      (assertion-violation
        who
        "expected a list of decoration runs"
        runs)))

  (define (make-decoration-index runs)
    (require-run-list 'make-decoration-index runs)
    (let* ([sorted (sort-positioned-runs runs)]
           [count (length sorted)]
           [values (list->vector sorted)]
           [prefix-max-end (make-vector count 0)])
      (let loop ([index 0] [maximum 0])
        (unless (= index count)
          (let ([next
                  (max
                    maximum
                    (decoration-run-end
                      (vector-ref values index)))])
            (vector-set! prefix-max-end index next)
            (loop (+ index 1) next))))
      (%make-decoration-index values prefix-max-end)))

  (define (first-prefix-end-after prefix position)
    (let loop ([low 0] [high (vector-length prefix)])
      (if (= low high)
          low
          (let ([middle (div (+ low high) 2)])
            (if (> (vector-ref prefix middle) position)
                (loop low middle)
                (loop (+ middle 1) high))))))

  (define (decoration-index-runs-in-range value start end)
    (unless (decoration-index? value)
      (assertion-violation
        'decoration-index-runs-in-range
        "expected a decoration index"
        value))
    (unless
      (and (exact-integer? start)
           (exact-integer? end)
           (<= 0 start end))
      (assertion-violation
        'decoration-index-runs-in-range
        "invalid decoration range query"
        start
        end))
    (if (= start end)
        '()
        (let* ([values (decoration-index-runs value)]
               [count (vector-length values)]
               [first
                 (first-prefix-end-after
                   (decoration-index-prefix-max-end value)
                   start)])
          (let loop ([index first] [result '()])
            (if (= index count)
                (reverse result)
                (let ([run (vector-ref values index)])
                  (cond
                    [(>= (decoration-run-start run) end)
                     (reverse result)]
                    [(< start (decoration-run-end run))
                     (loop (+ index 1) (cons run result))]
                    [else (loop (+ index 1) result)])))))))

  (define make-decoration-sweep
    (case-lambda
      [(runs) (make-decoration-sweep runs 0)]
      [(runs start)
       (require-run-list 'make-decoration-sweep runs)
       (unless
         (and (exact-integer? start) (not (negative? start)))
         (assertion-violation
           'make-decoration-sweep
           "start must be a non-negative exact integer"
           start))
       (%make-decoration-sweep
         (sort-positioned-runs runs)
         '()
         start)]))

  (define (decoration-sweep-runs-at! value position)
    (unless (decoration-sweep? value)
      (assertion-violation
        'decoration-sweep-runs-at!
        "expected a decoration sweep"
        value))
    (unless
      (and (exact-integer? position)
           (>= position (decoration-sweep-position value)))
      (assertion-violation
        'decoration-sweep-runs-at!
        "decoration sweep positions must be non-negative and monotonic"
        position
        (decoration-sweep-position value)))
    (let ([active
            (filter
              (lambda (run)
                (> (decoration-run-end run) position))
              (decoration-sweep-active value))])
      (let activate ([pending (decoration-sweep-pending value)]
                     [active active])
        (cond
          [(or (null? pending)
               (> (decoration-run-start (car pending)) position))
           (decoration-sweep-pending-set! value pending)
           (decoration-sweep-active-set! value active)
           (decoration-sweep-position-set! value position)
           active]
          [(> (decoration-run-end (car pending)) position)
           (activate
             (cdr pending)
             (insert-run (car pending) active))]
          [else (activate (cdr pending) active)]))))

  (define (decoration-sweep-next-boundary value end)
    (let ([next
            (fold-left
              (lambda (boundary run)
                (min boundary (decoration-run-end run)))
              end
              (decoration-sweep-active value))])
      (if (null? (decoration-sweep-pending value))
          next
          (min
            next
            (decoration-run-start
              (car (decoration-sweep-pending value)))))))

  (define (decoration-runs->styled-chunks runs start end)
    (require-run-list 'decoration-runs->styled-chunks runs)
    (unless
      (and
        (exact-integer? start)
        (exact-integer? end)
        (<= 0 start end))
      (assertion-violation
        'decoration-runs->styled-chunks
        "invalid styled chunk range"
        start
        end))
    (let ([sweep (make-decoration-sweep runs start)])
      (let loop ([position start] [chunks '()])
        (if (= position end)
            (reverse chunks)
            (let* ([active
                     (decoration-sweep-runs-at!
                       sweep position)]
                   [boundary
                     (decoration-sweep-next-boundary sweep end)])
              (unless (> boundary position)
                (assertion-violation
                  'decoration-runs->styled-chunks
                  "decoration boundary did not advance"
                  position
                  boundary))
              (loop
                boundary
                (cons
                  (make-styled-chunk
                    position boundary active)
                  chunks)))))))

  (define (make-styled-chunk-cursor chunks start)
    (unless
      (and
        (list? chunks)
        (for-all styled-chunk? chunks)
        (exact-integer? start)
        (not (negative? start)))
      (assertion-violation
        'make-styled-chunk-cursor
        "invalid styled chunk cursor"
        chunks
        start))
    (%make-styled-chunk-cursor chunks start))

  (define (styled-chunk-cursor-at! value position)
    (unless (styled-chunk-cursor? value)
      (assertion-violation
        'styled-chunk-cursor-at!
        "expected a styled chunk cursor"
        value))
    (unless
      (and
        (exact-integer? position)
        (>= position (styled-chunk-cursor-position value)))
      (assertion-violation
        'styled-chunk-cursor-at!
        "styled chunk positions must be non-negative and monotonic"
        position
        (styled-chunk-cursor-position value)))
    (let loop ([chunks (styled-chunk-cursor-chunks value)])
      (cond
        [(null? chunks)
         (styled-chunk-cursor-chunks-set! value '())
         (styled-chunk-cursor-position-set! value position)
         #f]
        [(>= position (styled-chunk-end (car chunks)))
         (loop (cdr chunks))]
        [else
         (unless
           (<= (styled-chunk-start (car chunks)) position)
           (assertion-violation
             'styled-chunk-cursor-at!
             "position precedes the current styled chunk"
             position
             (styled-chunk-start (car chunks))))
         (styled-chunk-cursor-chunks-set! value chunks)
         (styled-chunk-cursor-position-set! value position)
         (car chunks)])))

  (define (decoration-runs-in-range runs start end)
    (unless
      (and (list? runs)
           (for-all decoration-run? runs)
           (exact-integer? start)
           (exact-integer? end)
           (<= 0 start end))
      (assertion-violation
        'decoration-runs-in-range
        "invalid decoration range query"
        start
        end))
    (sort-runs
      (filter
        (lambda (run)
          (and (< (decoration-run-start run) end)
               (< start (decoration-run-end run))))
        runs)))

)
