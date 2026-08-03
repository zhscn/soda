(library (soda host render)
  (export make-surface-render
          surface-render?
          surface-render-frame
          surface-render-cursor-row
          surface-render-cursor-column
          render-surface
          render-surface-frame)
  (import (rnrs)
          (soda kernel state)
          (soda kernel view-state)
          (soda host buffer)
          (soda host surface)
          (soda host view)
          (soda host window)
          (soda view compositor)
          (soda view decoration)
          (soda view frame)
          (soda view text-layout))

  (define-record-type
    (surface-render %make-surface-render surface-render?)
    (fields frame cursor-row cursor-column))

  (define (offset-or-false? value)
    (or (not value) (and (integer? value) (exact? value) (>= value 0))))

  (define (make-surface-render frame cursor-row cursor-column)
    (unless (and (frame? frame) (offset-or-false? cursor-row)
                 (offset-or-false? cursor-column))
      (assertion-violation 'make-surface-render "invalid surface render"))
    (%make-surface-render frame cursor-row cursor-column))

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
      (window-layout! (surface-root-window surface) 0 0 width height)
      (let loop ([leaves (window-leaves (surface-root-window surface))]
                 [placements '()] [cursor-row #f] [cursor-column #f])
          (if (null? leaves)
              (make-surface-render
                (compose-frame width height (reverse placements)) cursor-row cursor-column)
              (let* ([leaf (car leaves)]
                     [view (view-service-ref views (window-view-id leaf) #f)])
                (if (not view)
                    (loop (cdr leaves) placements cursor-row cursor-column)
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
                            (layout-text-snapshot
                              snapshot (view-state-selection state)
                              first-line view-width view-height
                              (merge-decoration-sets (view-decorations view)))])
                      (loop
                        (cdr leaves)
                        (cons (make-frame-placement row column (text-layout-frame layout)) placements)
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
