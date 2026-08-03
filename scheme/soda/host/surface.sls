(library (soda host surface)
  (export make-surface
          surface?
          surface-id
          surface-size
          surface-root-window
          surface-selected-window
          surface-set-selected-window!
          surface-generation)
  (import (rnrs)
          (soda kernel value)
          (soda host window))

  (define-record-type
    (surface %make-surface surface?)
    (fields
      (immutable id surface-id)
      (mutable size surface-size surface-size-set!)
      (immutable root-window surface-root-window)
      (mutable selected-window surface-selected-window surface-selected-window-set!)
      (mutable generation surface-generation surface-generation-set!)))

  (define surface-identities (make-identity-source))

  (define (make-surface root-window size)
    (unless (window? root-window)
      (assertion-violation 'make-surface "expected a root window" root-window))
    (%make-surface
      (identity-source-next! surface-identities)
      size root-window #f 0))

  (define (surface-set-selected-window! surface window)
    (unless (and (surface? surface) (window? window))
      (assertion-violation
        'surface-set-selected-window! "expected a surface and window"
        surface window))
    (unless (memq window (window-leaves (surface-root-window surface)))
      (assertion-violation
        'surface-set-selected-window! "window is not a root leaf" window))
    (for-each (lambda (leaf) (window-set-selected! leaf #f))
              (window-leaves (surface-root-window surface)))
    (window-set-selected! window #t)
    (surface-selected-window-set! surface window)
    (surface-generation-set! surface (+ 1 (surface-generation surface)))
    window)
)
