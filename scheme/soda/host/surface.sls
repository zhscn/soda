(library (soda host surface)
  (export make-surface
          surface?
          surface-id
          surface-size
          surface-root-window
          surface-selected-window
          surface-set-selected-window!
          surface-resize!
          surface-generation
          make-surface-input-message
          surface-input-message?
          surface-input-message-surface-id
          surface-input-message-event)
  (import (rnrs)
          (soda kernel value)
          (soda host input-event)
          (soda host window))

  (define-record-type
    (surface-input-message %make-surface-input-message surface-input-message?)
    (fields
      (immutable surface-id surface-input-message-surface-id)
      (immutable event surface-input-message-event)))

  (define (make-surface-input-message surface-id event)
    (unless (and (integer? surface-id) (exact? surface-id) (not (negative? surface-id)))
      (assertion-violation
        'make-surface-input-message "invalid Surface identity" surface-id))
    (unless (input-event? event)
      (assertion-violation
        'make-surface-input-message "expected an input event" event))
    (%make-surface-input-message surface-id event))

  (define-record-type
    (surface %make-surface surface?)
    (fields
      (immutable id surface-id)
      (mutable size surface-size surface-size-set!)
      (immutable root-window surface-root-window)
      (mutable selected-window surface-selected-window surface-selected-window-set!)
      (mutable generation surface-generation surface-generation-set!)))

  (define surface-identities (make-identity-source))

  (define (surface-size? size)
    (and (pair? size) (integer? (car size)) (exact? (car size)) (>= (car size) 0)
         (integer? (cdr size)) (exact? (cdr size)) (>= (cdr size) 0)))

  (define (make-surface root-window size)
    (unless (and (window? root-window) (surface-size? size))
      (assertion-violation 'make-surface "invalid root window or surface size"))
    (window-layout! root-window 0 0 (car size) (cdr size))
    (let ([selected (car (window-leaves root-window))])
      (window-set-selected! selected #t)
      (%make-surface (identity-source-next! surface-identities)
                     size root-window selected 0)))

  (define (surface-resize! surface size)
    (unless (and (surface? surface) (surface-size? size))
      (assertion-violation 'surface-resize! "invalid Surface resize" surface size))
    (if (equal? size (surface-size surface))
        #f
        (begin
          (surface-size-set! surface size)
          (window-layout! (surface-root-window surface) 0 0 (car size) (cdr size))
          (surface-generation-set! surface (+ 1 (surface-generation surface)))
          size)))

  (define (surface-set-selected-window! surface window)
    (unless (and (surface? surface) (window? window))
      (assertion-violation
        'surface-set-selected-window! "expected a surface and window"
        surface window))
    (unless (memq window (window-leaves (surface-root-window surface)))
      (assertion-violation
        'surface-set-selected-window! "window is not a root leaf" window))
    (if (eq? window (surface-selected-window surface))
        window
        (begin
          (for-each (lambda (leaf) (window-set-selected! leaf #f))
                    (window-leaves (surface-root-window surface)))
          (window-set-selected! window #t)
          (surface-selected-window-set! surface window)
          (surface-generation-set! surface (+ 1 (surface-generation surface)))
          window)))
)
