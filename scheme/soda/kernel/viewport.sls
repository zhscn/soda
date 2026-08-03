(library (soda kernel viewport)
  (export make-viewport
          viewport?
          viewport-first-line
          viewport-visual-row
          default-viewport)
  (import (rnrs))

  ;; A viewport starts at a logical document line and may skip visual rows
  ;; produced by wrapping or display transforms within that line.
  (define-record-type
    (viewport %make-viewport viewport?)
    (fields first-line visual-row))

  (define (offset? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (make-viewport first-line visual-row)
    (unless (and (offset? first-line) (offset? visual-row))
      (assertion-violation 'make-viewport
                           "viewport positions must be non-negative exact integers"
                           first-line visual-row))
    (%make-viewport first-line visual-row))

  (define default-viewport (make-viewport 0 0)))
