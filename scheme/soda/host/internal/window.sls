(library (soda host internal window)
  (export make-leaf-window
          make-split-window
          window?
          window-id
          window-kind
          window-view-id
          window-axis
          window-children
          window-weights
          window-rectangle
          window-layout!
          window-selected?
          window-set-selected!
          window-leaves)
  (import (rnrs)
          (soda kernel value))

  (define-record-type
    (window %make-window window?)
    (fields
      (immutable id window-id)
      (immutable kind window-kind)
      (immutable view-id window-view-id)
      (immutable axis window-axis)
      (immutable children window-children)
      (immutable weights window-weights)
      (mutable rectangle window-rectangle window-rectangle-set!)
      (mutable selected? window-selected? window-selected?-set!)))

  (define window-identities (make-identity-source))

  (define (make-leaf-window view-id rectangle)
    (%make-window (identity-source-next! window-identities)
                  'leaf view-id #f '() '() rectangle #f))

  (define (split-weights? children weights)
    (and (= (length children) (length weights))
         (for-all (lambda (weight)
                    (and (rational? weight) (exact? weight) (> weight 0)))
                  weights)))

  (define (equal-weights count)
    (let loop ([remaining count] [result '()])
      (if (= remaining 0)
          (reverse result)
          (loop (- remaining 1) (cons 1 result)))))

  (define make-split-window
    (case-lambda
      [(axis children rectangle)
       (make-split-window axis children (equal-weights (length children)) rectangle)]
      [(axis children weights rectangle)
       (unless (and (memq axis '(horizontal vertical))
                    (pair? children)
                    (list? children)
                    (list? weights)
                    (split-weights? children weights))
         (assertion-violation 'make-split-window
                              "invalid split window, children, or weights"
                              axis children weights))
       (%make-window (identity-source-next! window-identities)
                     'split #f axis (append children '()) (append weights '()) rectangle #f)]))

  (define (window-set-selected! window value)
    (unless (window? window)
      (assertion-violation 'window-set-selected! "expected a window" window))
    (window-selected?-set! window (and value #t))
    (window-selected? window))

  (define (window-leaves window)
    (unless (window? window)
      (assertion-violation 'window-leaves "expected a window" window))
    (if (eq? (window-kind window) 'leaf)
        (list window)
        (apply append (map window-leaves (window-children window)))))

  (define (cell-count? value)
    (nonnegative-exact-integer? value))

  (define (weighted-extents extent weights)
    (let* ([total (apply + weights)]
           [floors (map (lambda (weight) (floor (/ (* extent weight) total))) weights)]
           [remaining (- extent (apply + floors))])
      ;; Exact rational weights make the largest-remainder allocation stable.
      ;; Ties retain child order, so equal weights preserve the existing split
      ;; behavior where leading children receive the extra terminal cells.
      (let loop ([count remaining] [sizes floors])
        (if (= count 0)
            sizes
            (let choose ([index 0] [best-index 0] [best-remainder -1]
                         [remaining-weights weights])
              (if (null? remaining-weights)
                  (loop (- count 1)
                        (let increment ([items sizes] [position 0])
                          (if (= position best-index)
                              (cons (+ 1 (car items)) (cdr items))
                              (cons (car items)
                                    (increment (cdr items) (+ position 1))))))
                  (let ([remainder
                         (- (* extent (car remaining-weights))
                            (* (list-ref floors index) total))])
                    (if (> remainder best-remainder)
                        (choose (+ index 1) index remainder (cdr remaining-weights))
                        (choose (+ index 1) best-index best-remainder
                                (cdr remaining-weights))))))))))

  ;; Rectangles are (row column width height).  Integer partitioning keeps
  ;; every child inside its parent and gives the leading children a remainder.
  (define (window-layout! window row column width height)
    (unless (and (window? window) (cell-count? row) (cell-count? column)
                 (cell-count? width) (cell-count? height))
      (assertion-violation 'window-layout! "invalid window layout request"))
    (window-rectangle-set! window (list row column width height))
    (unless (eq? (window-kind window) 'leaf)
      (let* ([children (window-children window)]
             [horizontal? (eq? (window-axis window) 'horizontal)]
             [extent (if horizontal? width height)]
             [extents (weighted-extents extent (window-weights window))])
        (let loop ([remaining children] [remaining-extents extents] [offset 0])
          (unless (null? remaining)
            (let ([size (car remaining-extents)])
              (window-layout! (car remaining)
                              (if horizontal? row (+ row offset))
                              (if horizontal? (+ column offset) column)
                              (if horizontal? size width)
                              (if horizontal? height size))
              (loop (cdr remaining) (cdr remaining-extents) (+ offset size)))))))
    window)
)
