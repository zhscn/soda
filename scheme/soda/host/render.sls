(library (soda host render)
  (export make-surface-render
          surface-render?
          surface-render-frame
          surface-render-cursor-row
          surface-render-cursor-column
          surface-render-rendered-views
          make-rendered-view
          rendered-view?
          rendered-view-view-id
          rendered-view-rectangle
          rendered-view-layout
          make-surface-hit
          surface-hit?
          surface-hit-view-id
          surface-hit-document-offset
          surface-render-hit-test
          render-surface
          render-surface-frame)
  (import (rnrs)
          (soda kernel state)
          (soda kernel extension)
          (soda kernel value)
          (soda kernel view-state)
          (soda host buffer)
          (soda host surface)
          (soda host view)
          (soda host window)
          (soda view compositor)
          (soda view decoration)
          (soda view display)
          (soda view frame)
          (soda view text-layout))

  ;; RenderedView retains the pure layout projection needed for coordinate
  ;; routing.  It is part of a rendered Surface, not mutable View state.
  (define-record-type
    (rendered-view %make-rendered-view rendered-view?)
    (fields view-id rectangle layout))

  (define (rectangle? value)
    (and (list? value) (= (length value) 4)
         (for-all (lambda (cell) (and (integer? cell) (exact? cell) (>= cell 0))) value)))

  (define (make-rendered-view view-id rectangle layout)
    (unless (and (rectangle? rectangle) (text-layout? layout))
      (assertion-violation 'make-rendered-view "invalid rendered View" view-id rectangle layout))
    (%make-rendered-view view-id (list-copy rectangle) layout))

  (define-record-type
    (surface-hit %make-surface-hit surface-hit?)
    (fields view-id document-offset))

  (define (make-surface-hit view-id document-offset)
    (unless (or (not document-offset) (offset-or-false? document-offset))
      (assertion-violation 'make-surface-hit "invalid document hit offset" document-offset))
    (%make-surface-hit view-id document-offset))

  (define-record-type
    (surface-render %make-surface-render surface-render?)
    (fields frame cursor-row cursor-column rendered-views))

  (define (offset-or-false? value)
    (or (not value) (and (integer? value) (exact? value) (>= value 0))))

  (define make-surface-render
    (case-lambda
      [(frame cursor-row cursor-column)
       (make-surface-render frame cursor-row cursor-column '())]
      [(frame cursor-row cursor-column rendered-views)
       (unless (and (frame? frame) (offset-or-false? cursor-row)
                    (offset-or-false? cursor-column)
                    (list? rendered-views) (for-all rendered-view? rendered-views))
         (assertion-violation 'make-surface-render "invalid surface render"))
       (%make-surface-render frame cursor-row cursor-column (list-copy rendered-views))]))

  (define (surface-render-hit-test render row column)
    (unless (and (surface-render? render) (offset-or-false? row)
                 (offset-or-false? column))
      (assertion-violation 'surface-render-hit-test "invalid Surface coordinate" render row column))
    (let find ([views (reverse (surface-render-rendered-views render))])
      (and (pair? views)
           (let* ([rendered (car views)]
                  [rectangle (rendered-view-rectangle rendered)]
                  [top (car rectangle)] [left (cadr rectangle)]
                  [width (caddr rectangle)] [height (cadddr rectangle)])
             (if (and (<= top row) (< row (+ top height))
                      (<= left column) (< column (+ left width)))
                 (make-surface-hit
                   (rendered-view-view-id rendered)
                   (text-layout-point->document (rendered-view-layout rendered)
                                                 (- row top) (- column left)))
                 (find (cdr views)))))))

  ;; Rendering consumes only published BufferState and ViewState.  A frontend
  ;; may retain the result, but no render step mutates editor state.
  (define (render-surface surface views)
    (unless (and (surface? surface) (view-service? views))
      (assertion-violation 'render-surface-frame "expected a Surface and ViewService"))
    (let* ([size (surface-size surface)]
           [width (car size)]
           [height (cdr size)])
      (unless (and (integer? width) (exact? width) (>= width 0)
                   (integer? height) (exact? height) (>= height 0))
        (assertion-violation 'render-surface "invalid Surface size" size))
      (let loop ([leaves (window-leaves (surface-root-window surface))]
                 [placements '()] [rendered-views '()] [cursor-row #f] [cursor-column #f])
          (if (null? leaves)
              (make-surface-render
                (compose-frame width height (reverse placements)) cursor-row cursor-column
                (reverse rendered-views))
              (let* ([leaf (car leaves)]
                     [view (view-service-ref views (window-view-id leaf) #f)])
                (if (not view)
                    (loop (cdr leaves) placements rendered-views cursor-row cursor-column)
                    (let* ([rectangle (window-rectangle leaf)]
                           [row (car rectangle)]
                           [column (cadr rectangle)]
                           [view-width (caddr rectangle)]
                           [view-height (cadddr rectangle)]
                           [state (view-state view)]
                           [snapshot (buffer-state-document (buffer-state (view-buffer view)))]
                           [viewport (view-state-viewport state)]
                           [first-line (if (and (pair? viewport) (integer? (car viewport)))
                                           (max 0 (car viewport))
                                           0)]
                           [layout
                            (let ([options
                                   (configuration-facet
                                     (view-state-configuration state)
                                     text-layout-options-facet 'view)]
                                  [streams (view-display-streams view)])
                              (if (null? streams)
                                  (layout-text-snapshot
                                    snapshot (view-state-selection state)
                                    first-line view-width view-height
                                    (merge-decoration-sets (view-decorations view)) options)
                                  (layout-display-stream
                                    (make-display-stream
                                      (apply append (map display-stream-fragments streams)))
                                    (view-state-selection state)
                                    view-width view-height options)))])
                      (loop
                        (cdr leaves)
                        (cons (make-frame-placement row column (text-layout-frame layout)) placements)
                        (cons (make-rendered-view (view-id view) rectangle layout) rendered-views)
                        (if (and (eq? leaf (surface-selected-window surface))
                                 (text-layout-cursor-row layout))
                            (+ row (text-layout-cursor-row layout))
                            cursor-row)
                        (if (and (eq? leaf (surface-selected-window surface))
                                 (text-layout-cursor-column layout))
                            (+ column (text-layout-cursor-column layout))
                            cursor-column)))))))))

  (define (render-surface-frame surface views)
    (surface-render-frame (render-surface surface views)))
)
