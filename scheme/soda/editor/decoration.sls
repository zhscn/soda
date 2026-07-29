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
          decoration-runs-in-range
          decoration-runs-at)
  (import (rnrs))

  (define-record-type
    (decoration-run %make-decoration-run decoration-run?)
    (fields start end face layer priority owner detail))

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
    (fold-left
      (lambda (result run) (insert-run run result))
      '()
      runs))

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

  (define (decoration-runs-at runs position)
    (unless
      (and (list? runs)
           (for-all decoration-run? runs)
           (exact-integer? position)
           (not (negative? position)))
      (assertion-violation
        'decoration-runs-at
        "invalid decoration point query"
        position))
    (sort-runs
      (filter
        (lambda (run) (decoration-run-covers? run position))
        runs))))
