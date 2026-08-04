(library (soda view occurrence)
  (export make-view-occurrence
          view-occurrence?
          view-occurrence-surface-id
          view-occurrence-window-id
          view-occurrence-view-id
          view-occurrence-rectangle
          view-occurrence-viewport
          view-occurrence-visible-ranges
          view-occurrence-projection-generation
          view-occurrence=?)
  (import (rnrs) (soda kernel viewport))

  ;; A View may be projected into several windows.  This immutable value is
  ;; the viewport-local input supplied to plugins after a frame is published.
  (define-record-type
    (view-occurrence %make-view-occurrence view-occurrence?)
    (fields surface-id window-id view-id rectangle viewport visible-ranges
            projection-generation))
  (define (identity? value) (and (integer? value) (exact? value) (>= value 0)))
  (define (rectangle? value)
    (and (list? value) (= (length value) 4) (for-all identity? value)))
  (define (copy-list values) (reverse (reverse values)))
  (define (make-view-occurrence surface-id window-id view-id rectangle viewport ranges generation)
    (unless (and (identity? surface-id) (identity? window-id) (identity? view-id)
                 (rectangle? rectangle) (viewport? viewport) (list? ranges)
                 (identity? generation))
      (assertion-violation 'make-view-occurrence "invalid View occurrence"
                           surface-id window-id view-id rectangle viewport ranges generation))
    (%make-view-occurrence surface-id window-id view-id (copy-list rectangle)
                           viewport (copy-list ranges) generation))
  (define (view-occurrence=? left right)
    (and (view-occurrence? left) (view-occurrence? right)
         (= (view-occurrence-surface-id left) (view-occurrence-surface-id right))
         (= (view-occurrence-window-id left) (view-occurrence-window-id right))
         (= (view-occurrence-view-id left) (view-occurrence-view-id right))
         (equal? (view-occurrence-rectangle left) (view-occurrence-rectangle right))
         (equal? (view-occurrence-viewport left) (view-occurrence-viewport right))
         (equal? (view-occurrence-visible-ranges left) (view-occurrence-visible-ranges right))
         (= (view-occurrence-projection-generation left)
            (view-occurrence-projection-generation right))))
)
