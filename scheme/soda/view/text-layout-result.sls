(library (soda view text-layout-result)
  (export make-text-layout
          text-layout?
          text-layout-frame
          text-layout-display-map
          text-layout-cursor-row
          text-layout-cursor-column
          text-layout-complete?
          text-layout-visible-ranges
          text-layout-content-height)
  (import (rnrs)
          (soda kernel value)
          (soda view display)
          (soda view frame))

  ;; A TextLayout is the immutable result of projecting a snapshot.  Keeping
  ;; the value independent from measurement and rendering lets geometry code
  ;; consume layouts without importing the cell renderer.
  (define-record-type
    (text-layout %make-text-layout text-layout?)
    (fields frame display-map cursor-row cursor-column complete?))

  (define make-text-layout
    (case-lambda
      [(frame display-map cursor-row cursor-column)
       (make-text-layout frame display-map cursor-row cursor-column #t)]
      [(frame display-map cursor-row cursor-column complete?)
       (unless (and (frame? frame) (display-map? display-map)
                    (or (not cursor-row)
                        (nonnegative-exact-integer? cursor-row))
                    (or (not cursor-column)
                        (nonnegative-exact-integer? cursor-column))
                    (boolean? complete?))
         (assertion-violation 'make-text-layout "invalid text layout result"))
       (%make-text-layout frame display-map cursor-row cursor-column complete?)]))

  (define (text-layout-visible-ranges layout)
    (unless (text-layout? layout)
      (assertion-violation
        'text-layout-visible-ranges "expected a TextLayout" layout))
    (display-map-visible-ranges (text-layout-display-map layout)))

  (define (text-layout-content-height layout)
    (unless (text-layout? layout)
      (assertion-violation
        'text-layout-content-height "expected a TextLayout" layout))
    (let* ([frame (text-layout-frame layout)]
           [width (frame-width frame)])
      (if (zero? width)
          0
          (let ([last-cell
                 (fold-left
                   (lambda (current entry)
                     (let ([from (display-map-entry-cell-from entry)]
                           [to (display-map-entry-cell-to entry)])
                       (max current (if (> to from) (- to 1) from))))
                   0
                   (display-map-entries (text-layout-display-map layout)))])
            (max 1
                 (+ 1 (div last-cell width))
                 (if (text-layout-cursor-row layout)
                     (+ 1 (text-layout-cursor-row layout))
                     0))))))
)
