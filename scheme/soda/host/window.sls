(library (soda host window)
  (export make-leaf-window
          make-split-window
          window?
          window-kind
          window-view-id
          window-axis
          window-children
          window-rectangle
          window-layout!
          window-selected?
          window-set-selected!
          window-leaves)
  (import (rnrs))

  (define-record-type
    (window %make-window window?)
    (fields
      (immutable kind window-kind)
      (immutable view-id window-view-id)
      (immutable axis window-axis)
      (immutable children window-children)
      (mutable rectangle window-rectangle window-rectangle-set!)
      (mutable selected? window-selected? window-selected?-set!)))

  (define (make-leaf-window view-id rectangle)
    (%make-window 'leaf view-id #f '() rectangle #f))

  (define (make-split-window axis children rectangle)
    (unless (and (memq axis '(horizontal vertical)) (pair? children))
      (assertion-violation 'make-split-window "invalid split window" axis children))
    (%make-window 'split #f axis children rectangle #f))

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
    (and (integer? value) (exact? value) (>= value 0)))

  ;; Rectangles are (row column width height).  Integer partitioning keeps
  ;; every child inside its parent and gives the leading children a remainder.
  (define (window-layout! window row column width height)
    (unless (and (window? window) (cell-count? row) (cell-count? column)
                 (cell-count? width) (cell-count? height))
      (assertion-violation 'window-layout! "invalid window layout request"))
    (window-rectangle-set! window (list row column width height))
    (unless (eq? (window-kind window) 'leaf)
      (let* ([children (window-children window)]
             [count (length children)]
             [horizontal? (eq? (window-axis window) 'horizontal)]
             [extent (if horizontal? width height)]
             [base (div extent count)]
             [remainder (mod extent count)])
        (let loop ([remaining children] [index 0] [offset 0])
          (unless (null? remaining)
            (let ([size (+ base (if (< index remainder) 1 0))])
              (window-layout! (car remaining)
                              (if horizontal? row (+ row offset))
                              (if horizontal? (+ column offset) column)
                              (if horizontal? size width)
                              (if horizontal? height size))
              (loop (cdr remaining) (+ index 1) (+ offset size)))))))
    window)
)
