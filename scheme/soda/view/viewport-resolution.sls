(library (soda view viewport-resolution)
  (export make-display-scroll-resolution
          display-scroll-resolution?
          display-scroll-resolution-row
          display-scroll-resolution-selection
          display-row-document-offset
          resolve-display-scroll-request)
  (import (rnrs)
          (soda kernel selection)
          (soda view frame)
          (soda view text-layout))

  ;; A DisplayScrollResolution is the pure coordinate result for a structural
  ;; projection.  Its row is in DisplayMap coordinates; the host decides how
  ;; that result becomes a View transaction.
  (define-record-type
    (display-scroll-resolution %make-display-scroll-resolution
                               display-scroll-resolution?)
    (fields row selection))

  (define (offset? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (make-display-scroll-resolution row selection)
    (unless (and (offset? row) (selection? selection))
      (assertion-violation 'make-display-scroll-resolution
                           "invalid display scroll resolution" row selection))
    (%make-display-scroll-resolution row selection))

  (define (screen-row placement height)
    (case placement
      [(top) 0]
      [(center) (div (- height 1) 2)]
      [(bottom) (- height 1)]))

  (define (display-row-document-offset layout row column)
    (unless (and (text-layout? layout) (offset? row) (offset? column))
      (assertion-violation 'display-row-document-offset
                           "invalid display row coordinate" layout row column))
    (let* ([frame (text-layout-frame layout)]
           [width (frame-width frame)]
           [target-column (if (zero? width) 0 (min column (- width 1)))])
      (and (> width 0)
           (let loop ([distance 0])
             (and (< distance width)
                  (let* ([left (- target-column distance)]
                         [right (+ target-column distance)]
                         [left-value
                          (and (>= left 0)
                               (text-layout-point->document layout row left))]
                         [right-value
                          (and (> distance 0) (< right width)
                               (text-layout-point->document layout row right))])
                    (or left-value right-value (loop (+ distance 1)))))))))

  (define (replace-ranges selection mapper)
    (let loop ([ranges (selection-ranges selection)] [changed? #f] [result '()])
      (if (null? ranges)
          (if changed?
              (make-selection (reverse result) (selection-primary selection))
              selection)
          (let* ([range (car ranges)] [replacement (mapper range)])
            (loop (cdr ranges)
                  (or changed? (not (eq? replacement range)))
                  (cons replacement result))))))

  (define (collapse-selection-at selection offset)
    (replace-ranges
      selection
      (lambda (range)
        (if (and (= (selection-range-anchor range) offset)
                 (= (selection-range-head range) offset))
            range
            (make-selection-range
              offset offset
              (selection-range-affinity range)
              (selection-range-granularity range)
              (selection-range-metadata range))))))

  (define (keep-selection-visible layout selection top height content-height)
    (let ([bottom (min (- content-height 1) (+ top (- height 1)))])
      (replace-ranges
        selection
        (lambda (range)
          (let* ([head (selection-range-head range)]
                 [position (text-layout-document->point layout head)]
                 [row (and position (car position))]
                 [column (if position (cdr position) 0)]
                 [next
                  (cond
                    [(and row (< row top))
                     (display-row-document-offset layout top column)]
                    [(and row (> row bottom))
                     (display-row-document-offset layout bottom column)]
                    [else head])])
            (if (or (not next) (= next head))
                range
                (make-selection-range
                  next next
                  (selection-range-affinity range)
                  (selection-range-granularity range)
                  (selection-range-metadata range))))))))

  ;; Resolve a semantic scroll intent against a complete structural layout.
  ;; CURRENT-TOP and the resulting row are DisplayMap coordinates.  Plain
  ;; document Views use the incremental visual-measurement resolver instead.
  (define (resolve-display-scroll-request layout height current-top selection kind argument)
    (unless (and (text-layout? layout) (text-layout-complete? layout)
                 (offset? height) (> height 0)
                 (offset? current-top) (selection? selection)
                 (memq kind '(reveal-point scroll-rows scroll-pages recenter
                                           move-point-to-window-row))
                 (case kind
                   [(reveal-point) (not argument)]
                   [(scroll-rows scroll-pages)
                    (and (integer? argument) (exact? argument) (not (zero? argument)))]
                   [else (memq argument '(top center bottom))]))
      (assertion-violation 'resolve-display-scroll-request
                           "invalid display scroll request"
                           layout height current-top selection kind argument))
    (let* ([content-height (text-layout-content-height layout)]
           [last-top (max 0 (- content-height height))]
           [top (min last-top current-top)]
           [point (selection-range-head (selection-primary-range selection))]
           [position (text-layout-document->point layout point)]
           [point-row (if position (car position) top)]
           [point-column (if position (cdr position) 0)]
           [requested-top
            (case kind
              [(reveal-point)
               (cond [(< point-row top) point-row]
                     [(>= point-row (+ top height)) (- point-row (- height 1))]
                     [else top])]
              [(scroll-rows) (+ top argument)]
              [(scroll-pages) (+ top (* argument height))]
              [(recenter) (- point-row (screen-row argument height))]
              [(move-point-to-window-row) top])]
           [target-top (min last-top (max 0 requested-top))]
           [next-selection
            (case kind
              [(move-point-to-window-row)
               (let ([target
                      (display-row-document-offset
                        layout
                        (min (- content-height 1)
                             (+ target-top (screen-row argument height)))
                        point-column)])
                 (if target
                     (collapse-selection-at selection target)
                     selection))]
              [(scroll-rows scroll-pages)
               (keep-selection-visible layout selection target-top height content-height)]
              [else selection])])
      (make-display-scroll-resolution target-top next-selection)))
)
