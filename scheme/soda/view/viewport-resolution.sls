(library (soda view viewport-resolution)
  (export make-viewport-scroll-resolution
          viewport-scroll-resolution?
          viewport-scroll-resolution-viewport
          viewport-scroll-resolution-selection
          display-row-document-offset
          resolve-document-reveal-request
          resolve-document-scroll-request
          resolve-display-scroll-request)
  (import (rnrs)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel viewport)
          (soda view frame)
          (soda view text-layout))

  ;; A ViewportScrollResolution is a pure presentation result.  It combines a
  ;; Viewport coordinate with a Selection transformed only when a command's
  ;; interaction contract requires point to remain visible.
  (define-record-type
    (viewport-scroll-resolution %make-viewport-scroll-resolution
                                viewport-scroll-resolution?)
    (fields viewport selection))

  (define (offset? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (make-viewport-scroll-resolution viewport selection)
    (unless (and (viewport? viewport) (selection? selection))
      (assertion-violation 'make-viewport-scroll-resolution
                           "invalid viewport scroll resolution" viewport selection))
    (%make-viewport-scroll-resolution viewport selection))

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

  (define (collapse-selection-at selection offset)
    (selection-map-preserving
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
      (selection-map-preserving
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

  (define (visual-position-before? left right)
    (or (< (visual-position-line left) (visual-position-line right))
        (and (= (visual-position-line left) (visual-position-line right))
             (< (visual-position-row left) (visual-position-row right)))))

  (define (document-screen-row-position text options width height viewport row column)
    (text-layout-viewport-row-position
      text options width height viewport row column))

  (define (visual-position->document-viewport position)
    (make-viewport (visual-position-line position) (visual-position-row position)))

  (define (document-keep-selection-visible text options width height viewport selection)
    (let* ([top (document-screen-row-position text options width height viewport 0 0)]
           [bottom
            (document-screen-row-position text options width height viewport
                                          (- height 1) 0)])
      (selection-map-preserving
        selection
        (lambda (range)
          (let* ([head (selection-range-head range)]
                 [position
                  (text-layout-document-visual-position text options width head)]
                 [screen-row
                  (cond [(visual-position-before? position top) 0]
                        [(visual-position-before? bottom position) (- height 1)]
                        [else #f])]
                 [next
                  (and screen-row
                       (document-screen-row-position
                         text options width height viewport screen-row
                         (visual-position-column position)))]
                 [offset (and next (visual-position-offset next))])
            (if (or (not offset) (= offset head))
                range
                (make-selection-range
                  offset offset
                  (selection-range-affinity range)
                  (selection-range-granularity range)
                  (selection-range-metadata range))))))))

  (define (resolve-document-reveal-request text options width height viewport selection)
    (unless (and (text? text) (text-layout-options? options)
                 (offset? width) (> width 0) (offset? height) (> height 0)
                 (document-viewport? viewport) (selection? selection))
      (assertion-violation 'resolve-document-reveal-request
                           "invalid document reveal request"
                           text options width height viewport selection))
    (make-viewport-scroll-resolution
      (text-layout-reveal-viewport
        text options width height viewport
        (selection-range-head (selection-primary-range selection)))
      selection))

  ;; Resolve scrolling directly in document visual coordinates.  This path
  ;; never materializes a whole-document DisplayMap.
  (define (resolve-document-scroll-request text options width height viewport selection kind argument)
    (unless (and (text? text) (text-layout-options? options)
                 (offset? width) (> width 0) (offset? height) (> height 0)
                 (document-viewport? viewport) (selection? selection)
                 (memq kind '(scroll-rows scroll-pages recenter
                                           move-point-to-window-row))
                 (case kind
                   [(scroll-rows scroll-pages)
                    (and (integer? argument) (exact? argument) (not (zero? argument)))]
                   [else (memq argument '(top center bottom))]))
      (assertion-violation 'resolve-document-scroll-request
                           "invalid document scroll request"
                           text options width height viewport selection kind argument))
    (let* ([target
            (case kind
              [(scroll-rows)
               (visual-position->document-viewport
                 (text-layout-scroll-start text options width height viewport argument))]
              [(scroll-pages)
               (visual-position->document-viewport
                 (text-layout-scroll-start
                   text options width height viewport (* argument height)))]
              [(recenter)
               (visual-position->document-viewport
                 (text-layout-recenter-start
                   text options width height
                   (selection-range-head (selection-primary-range selection))
                   (screen-row argument height)))]
              [else viewport])]
           [next-selection
            (case kind
              [(scroll-rows scroll-pages)
               (document-keep-selection-visible text options width height target selection)]
              [(move-point-to-window-row)
               (let* ([primary (selection-primary-range selection)]
                      [position
                       (text-layout-document-visual-position
                         text options width (selection-range-head primary))]
                      [target-position
                       (document-screen-row-position
                         text options width height viewport
                         (screen-row argument height)
                         (visual-position-column position))])
                 (collapse-selection-at selection
                                        (visual-position-offset target-position)))]
              [else selection])])
      (make-viewport-scroll-resolution target next-selection)))

  ;; Resolve a semantic scroll intent against a complete structural layout.
  ;; CURRENT-TOP and the result Viewport are in DisplayMap coordinates.  Plain
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
      (make-viewport-scroll-resolution
        (make-display-viewport target-top) next-selection)))
)
