(library (soda kernel viewport)
  (export make-viewport
          make-display-viewport
          viewport?
          viewport-origin
          document-viewport?
          display-viewport?
          viewport-first-line
          viewport-visual-row
          viewport=?
          default-viewport
          make-scroll-request
          scroll-request?
          scroll-request-kind
          scroll-request-surface-id
          scroll-request-window-id
          scroll-request-view-id
          scroll-request-argument)
  (import (rnrs))

  ;; A document viewport starts at a logical document line and may skip visual
  ;; rows within that line.  Structural DisplayStream projections may instead
  ;; retain a display-row origin when no document line can name their leading
  ;; virtual content.  The origin is explicit so callers cannot mistake one
  ;; coordinate system for the other.
  (define-record-type
    (viewport %make-viewport viewport?)
    (fields origin first-line visual-row))

  (define (offset? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (make-viewport first-line visual-row)
    (unless (and (offset? first-line) (offset? visual-row))
      (assertion-violation 'make-viewport
                           "viewport positions must be non-negative exact integers"
                           first-line visual-row))
    (%make-viewport 'document first-line visual-row))

  (define (make-display-viewport visual-row)
    (unless (offset? visual-row)
      (assertion-violation 'make-display-viewport
                           "display row must be a non-negative exact integer"
                           visual-row))
    (%make-viewport 'display 0 visual-row))

  (define default-viewport (make-viewport 0 0))

  (define (document-viewport? value)
    (and (viewport? value) (eq? (viewport-origin value) 'document)))

  (define (display-viewport? value)
    (and (viewport? value) (eq? (viewport-origin value) 'display)))

  (define (viewport=? left right)
    (and (viewport? left) (viewport? right)
         (eq? (viewport-origin left) (viewport-origin right))
         (= (viewport-first-line left) (viewport-first-line right))
         (= (viewport-visual-row left) (viewport-visual-row right))))

  ;; ScrollRequest is a semantic command-loop intent.  It names the View
  ;; whose presentation should change while leaving viewport measurement to a
  ;; frontend with a compatible immutable layout.
  (define-record-type
    (scroll-request %make-scroll-request scroll-request?)
    (fields kind surface-id window-id view-id argument))

  (define (optional-offset? value)
    (or (not value) (offset? value)))

  (define make-scroll-request
    (case-lambda
      [(kind surface-id window-id view-id)
       (make-scroll-request kind surface-id window-id view-id #f)]
      [(kind surface-id window-id view-id argument)
       (unless
         (and (memq kind '(reveal-point scroll-rows scroll-pages recenter
                                      move-point-to-window-row))
              (optional-offset? surface-id) (optional-offset? window-id)
              (offset? view-id)
              (case kind
                [(reveal-point) (not argument)]
                [(scroll-rows scroll-pages)
                 (and (integer? argument) (exact? argument) (not (zero? argument)))]
                [(recenter move-point-to-window-row)
                 (memq argument '(top center bottom))]
                [else #f]))
         (assertion-violation 'make-scroll-request
                              "invalid scroll request"
                              kind surface-id window-id view-id argument))
       (%make-scroll-request kind surface-id window-id view-id argument)]))
)
