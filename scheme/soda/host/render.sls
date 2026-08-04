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
          rendered-view-occurrence
          rendered-view-projection-generation
          rendered-view-visible-ranges
          rendered-view-transform-failures
          make-surface-hit
          surface-hit?
          surface-hit-view-id
          surface-hit-document-offset
          surface-hit-kind
          surface-hit-source
          surface-render-hit-test
          render-surface
          render-surface-frame)
  (import (rnrs)
          (soda kernel state)
          (soda kernel extension)
          (soda kernel value)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host internal buffer)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda view compositor)
          (soda view decoration)
          (soda view display)
          (soda view projection)
          (soda view occurrence)
          (soda view frame)
          (soda view text-layout))

  ;; RenderedView retains the pure layout projection needed for coordinate
  ;; routing.  It is part of a rendered Surface, not mutable View state.
  (define-record-type
    (rendered-view %make-rendered-view rendered-view?)
    (fields view-id rectangle layout occurrence projection-generation transform-failures))

  (define (rectangle? value)
    (and (list? value) (= (length value) 4)
         (for-all nonnegative-exact-integer? value)))

  (define make-rendered-view
    (case-lambda
      [(view-id rectangle layout)
       (make-rendered-view view-id rectangle layout #f 0 '())]
      [(view-id rectangle layout transform-failures)
       (make-rendered-view view-id rectangle layout #f 0 transform-failures)]
      [(view-id rectangle layout occurrence projection-generation transform-failures)
       (unless (and (rectangle? rectangle) (text-layout? layout)
                    (or (not occurrence) (view-occurrence? occurrence))
                    (integer? projection-generation) (exact? projection-generation)
                    (>= projection-generation 0)
                    (list? transform-failures))
         (assertion-violation 'make-rendered-view "invalid rendered View"
                              view-id rectangle layout occurrence projection-generation transform-failures))
       (%make-rendered-view view-id (list-copy rectangle) layout occurrence projection-generation
                            (list-copy transform-failures))]))

  (define (rendered-view-visible-ranges rendered)
    (unless (rendered-view? rendered)
      (assertion-violation 'rendered-view-visible-ranges "expected a RenderedView" rendered))
    (text-layout-visible-ranges (rendered-view-layout rendered)))

  (define-record-type
    (surface-hit %make-surface-hit surface-hit?)
    (fields view-id document-offset kind source))

  (define make-surface-hit
    (case-lambda
      [(view-id document-offset)
       (make-surface-hit view-id document-offset #f #f)]
      [(view-id document-offset kind source)
       (unless (and (offset-or-false? document-offset)
                    (or (not kind) (memq kind '(text virtual widget line-break))))
         (assertion-violation 'make-surface-hit "invalid Surface hit" view-id document-offset kind))
       (%make-surface-hit view-id document-offset kind source)]))

  (define-record-type
    (surface-render %make-surface-render surface-render?)
    (fields frame cursor-row cursor-column rendered-views))

  (define (offset-or-false? value)
    (or (not value) (nonnegative-exact-integer? value)))

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
                 (let* ([layout (rendered-view-layout rendered)]
                        [local-row (- row top)]
                        [local-column (- column left)]
                        [entry (text-layout-point->display-entry layout local-row local-column)])
                   (make-surface-hit
                     (rendered-view-view-id rendered)
                     (text-layout-point->document layout local-row local-column)
                     (and entry (display-map-entry-kind entry))
                     (and entry (display-map-entry-source entry))))
                 (find (cdr views)))))))

  ;; Rendering consumes only published BufferState and ViewState.  A frontend
  ;; may retain the result, but no render step mutates editor state.
  (define (render-surface surface views)
    (unless (and (surface? surface) (view-service? views))
      (assertion-violation 'render-surface-frame "expected a Surface and ViewService"))
    (let* ([size (surface-size surface)]
           [width (car size)]
           [height (cdr size)])
      (unless (and (nonnegative-exact-integer? width)
                   (nonnegative-exact-integer? height))
        (assertion-violation 'render-surface "invalid Surface size" size))
      (let loop ([leaves (surface-windows surface)]
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
                           [first-line (viewport-first-line viewport)]
                           [visual-row (viewport-visual-row viewport)]
                           [view-projection (view-projection view)]
                           [projection
                            (let ([options
                                  (configuration-facet
                                     (view-state-configuration state)
                                     text-layout-options-facet 'view)]
                                  [provided-stream
                                   (view-projection-display-stream view-projection)])
                              (let ([failures '()])
                                (define (transform base)
                                  (let-values ([(stream transform-failures)
                                                (view-projection-transform-display-stream
                                                  view-projection base)])
                                    (set! failures transform-failures)
                                    stream))
                                (list
                                  (if provided-stream
                                      (layout-display-stream
                                        (transform provided-stream)
                                        (view-state-selection state)
                                        view-width view-height options visual-row)
                                      (layout-snapshot-display-stream
                                        snapshot
                                        (view-state-selection state)
                                        first-line visual-row
                                        view-width view-height
                                        (view-projection-decorations view-projection)
                                        transform options))
                                  failures))) ]
                           [layout (car projection)]
                           [transform-failures (cadr projection)])
                      (loop
                        (cdr leaves)
                        (cons (make-frame-placement row column (text-layout-frame layout)) placements)
                        (cons (make-rendered-view
                                (view-id view) rectangle layout
                                (make-view-occurrence
                                  (surface-id surface) (window-id leaf) (view-id view)
                                  rectangle viewport (text-layout-visible-ranges layout)
                                  (view-projection-generation view-projection))
                                                  (view-projection-generation view-projection)
                                                  transform-failures)
                              rendered-views)
                        (if (and (eq? leaf (surface-active-window surface))
                                 (text-layout-cursor-row layout))
                            (+ row (text-layout-cursor-row layout))
                            cursor-row)
                        (if (and (eq? leaf (surface-active-window surface))
                                 (text-layout-cursor-column layout))
                            (+ column (text-layout-cursor-column layout))
                            cursor-column)))))))))

  (define (render-surface-frame surface views)
    (surface-render-frame (render-surface surface views)))
)
