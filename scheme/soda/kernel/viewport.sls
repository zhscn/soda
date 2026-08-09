(library (soda kernel viewport)
  (export make-viewport
          viewport?
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

  (define default-viewport (make-viewport 0 0))

  (define (viewport=? left right)
    (and (viewport? left) (viewport? right)
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
