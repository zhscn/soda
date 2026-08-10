(library (soda view text-layout-coordinates)
  (export text-layout-document->point
          text-layout-point->document
          text-layout-point->display-entry
          text-layout-vertical-target)
  (import (rnrs)
          (soda kernel value)
          (soda view display)
          (soda view frame)
          (soda view text-layout-result))

  (define offset? nonnegative-exact-integer?)

  ;; Coordinate queries consume the committed DisplayMap.  They never infer
  ;; document locations from rendered glyphs, so virtual and wide cells retain
  ;; the associations established by projection.
  (define text-layout-document->point
    (case-lambda
      [(layout offset) (text-layout-document->point layout offset 'after)]
      [(layout offset association)
       (unless (and (text-layout? layout) (offset? offset)
                    (memq association '(before after)))
         (assertion-violation
           'text-layout-document->point
           "invalid TextLayout document position" layout offset association))
       (let ([cell
              (display-map-document->cell
                (text-layout-display-map layout) offset association)]
             [frame (text-layout-frame layout)])
         (and cell
              (< cell (* (frame-width frame) (frame-height frame)))
              (cons (div cell (frame-width frame))
                    (mod cell (frame-width frame)))))]))

  (define (text-layout-point->document layout row column)
    (unless (and (text-layout? layout) (offset? row) (offset? column))
      (assertion-violation
        'text-layout-point->document
        "invalid TextLayout display position" layout row column))
    (let ([frame (text-layout-frame layout)])
      (and (< row (frame-height frame))
           (< column (frame-width frame))
           (let* ([map (text-layout-display-map layout)]
                  [cell (+ (* row (frame-width frame)) column)])
             (or (display-map-cell->document map cell)
                 (let ([entry (display-map-cell-boundary-entry map cell)])
                   (and entry (display-map-entry-document-from entry))))))))

  (define (text-layout-point->display-entry layout row column)
    (unless (and (text-layout? layout) (offset? row) (offset? column))
      (assertion-violation
        'text-layout-point->display-entry
        "invalid TextLayout display position" layout row column))
    (let ([frame (text-layout-frame layout)])
      (and (< row (frame-height frame))
           (< column (frame-width frame))
           (let* ([map (text-layout-display-map layout)]
                  [cell (+ (* row (frame-width frame)) column)]
                  [entries (display-map-cell-range map cell (+ cell 1))])
             (or (and (pair? entries) (car entries))
                 (display-map-cell-boundary-entry map cell))))))

  (define text-layout-vertical-target
    (case-lambda
      [(layout offset delta)
       (text-layout-vertical-target layout offset delta #f)]
      [(layout offset delta goal-column)
       (unless (and (text-layout? layout) (offset? offset)
                    (integer? delta) (exact? delta)
                    (or (not goal-column) (offset? goal-column)))
         (assertion-violation
           'text-layout-vertical-target
           "invalid TextLayout vertical motion request"
           layout offset delta goal-column))
       (let ([point (text-layout-document->point layout offset)])
         (and point
              (let* ([frame (text-layout-frame layout)]
                     [width (frame-width frame)]
                     [target-row (+ (car point) delta)]
                     [column (or goal-column (cdr point))])
                (and (> width 0)
                     (>= target-row 0)
                     (< target-row (frame-height frame))
                     (let ([target-column (min column (- width 1))])
                       (let loop ([distance 0])
                         (if (>= distance width)
                             #f
                             (let* ([left (- target-column distance)]
                                    [right (+ target-column distance)]
                                    [left-value
                                     (and (>= left 0)
                                          (text-layout-point->document
                                            layout target-row left))]
                                    [right-value
                                     (and (> distance 0) (< right width)
                                          (text-layout-point->document
                                            layout target-row right))])
                               (cond [left-value left-value]
                                     [right-value right-value]
                                     [else (loop (+ distance 1))])))))))))]))
)
