(library (soda host window)
  (export make-leaf-window
          make-split-window
          window?
          window-kind
          window-view-id
          window-axis
          window-children
          window-rectangle
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
)
