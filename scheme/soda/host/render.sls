(library (soda host render)
  (export render-surface-frame)
  (import (rnrs)
          (soda kernel state)
          (soda kernel view-state)
          (soda host buffer)
          (soda host surface)
          (soda host view)
          (soda host window)
          (soda view compositor)
          (soda view decoration)
          (soda view text-layout))

  ;; Rendering consumes only published BufferState and ViewState.  A frontend
  ;; may retain the returned Frame, but no render step mutates editor state.
  (define (render-surface-frame surface views)
    (unless (and (surface? surface) (view-service? views))
      (assertion-violation 'render-surface-frame "expected a Surface and ViewService"))
    (let* ([size (surface-size surface)]
           [width (car size)]
           [height (cdr size)])
      (unless (and (integer? width) (exact? width) (>= width 0)
                   (integer? height) (exact? height) (>= height 0))
        (assertion-violation 'render-surface-frame "invalid Surface size" size))
      (window-layout! (surface-root-window surface) 0 0 width height)
      (compose-frame
        width height
        (let loop ([leaves (window-leaves (surface-root-window surface))] [result '()])
          (if (null? leaves)
              (reverse result)
              (let* ([leaf (car leaves)]
                     [view (view-service-ref views (window-view-id leaf) #f)])
                (if (not view)
                    (loop (cdr leaves) result)
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
                      (loop (cdr leaves)
                            (cons (make-frame-placement row column
                                                        (text-layout-frame layout))
                                  result))))))))))
)
