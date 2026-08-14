(library (soda host render-service)
  (export make-render-service
          render-service?
          render-service-render!
          render-service-invalidate!
          render-service-last-render)
  (import (rnrs)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel value)
          (soda host internal buffer)
          (soda host internal presentation)
          (soda host render)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda view projection)
          (soda view text-layout))

  ;; Rendering is a pure projection, while this service owns the optional
  ;; frontend cache.  Its signature describes cell layout rather than every
  ;; ViewState generation: a single collapsed caret does not alter cells and
  ;; can be projected through the committed DisplayMap.
  (define-record-type
    (render-service %make-render-service render-service?)
    (fields (mutable signature render-service-signature render-service-signature-set!)
            (mutable caret-signature render-service-caret-signature
                     render-service-caret-signature-set!)
            (mutable render render-service-last-render render-service-render-set!)
            (mutable epoch render-service-epoch render-service-epoch-set!)))

  (define (make-render-service)
    (%make-render-service #f #f #f 0))

  (define (collapsed-caret? selection)
    (let ([ranges (selection-ranges selection)])
      (and (= (length ranges) 1)
           (selection-range-empty? (car ranges)))))

  (define (selection-layout-token selection)
    (if (collapsed-caret? selection) 'collapsed-caret selection))

  (define (view-render-token leaf views)
    (let ([view (view-service-ref views (window-view-id leaf) #f)])
      (if view
          (let ([state (view-state view)])
            (vector
              (window-view-id leaf)
              (buffer-state-generation (buffer-state (view-buffer view)))
              (view-projection-generation (view-projection view))
              (view-state-viewport state)
              (view-state-configuration state)
              (selection-layout-token (view-state-selection state))))
          (vector (window-view-id leaf) #f #f))))

  (define (surface-render-token service surface views presentations)
    (vector (render-service-epoch service)
            (and presentations
                 (buffer-presentation-service-generation presentations))
            (surface-id surface)
            (surface-generation surface)
            (map (lambda (leaf) (view-render-token leaf views))
                 (surface-windows surface))))

  (define (surface-caret-token surface views)
    (let* ([active (surface-active-window surface)]
           [view
            (and active
                 (view-service-ref views (window-view-id active) #f))]
           [selection
            (and view (view-state-selection (view-state view)))])
      (and selection (collapsed-caret? selection)
           (vector
             (view-id view)
             (selection-range-head (selection-primary-range selection))))))

  (define (render-service-invalidate! service)
    (unless (render-service? service)
      (assertion-violation 'render-service-invalidate! "expected a RenderService" service))
    (render-service-epoch-set! service (+ 1 (render-service-epoch service)))
    #t)

  (define (render-service-render-with-presentations!
            service surface views presentations)
    (unless (and (render-service? service) (surface? surface) (view-service? views))
      (assertion-violation 'render-service-render! "invalid render request" service surface views))
    (let ([signature (surface-render-token service surface views presentations)]
          [caret-signature (surface-caret-token surface views)])
      (if (equal? signature (render-service-signature service))
          (let ([cached (render-service-last-render service)])
            (if (equal? caret-signature (render-service-caret-signature service))
                cached
                (let ([render
                       (or (and cached
                                (surface-render-retarget-active-view
                                  cached surface views presentations))
                           (if presentations
                               (render-surface surface views presentations)
                               (render-surface surface views)))])
                  (render-service-caret-signature-set! service caret-signature)
                  (render-service-render-set! service render)
                  render)))
          (let ([render
                 (if presentations
                     (render-surface surface views presentations)
                     (render-surface surface views))])
            (render-service-signature-set! service signature)
            (render-service-caret-signature-set! service caret-signature)
            (render-service-render-set! service render)
            render))))

  (define render-service-render!
    (case-lambda
      [(service surface views)
       (render-service-render-with-presentations! service surface views #f)]
      [(service surface views presentations)
       (unless (buffer-presentation-service? presentations)
         (assertion-violation 'render-service-render!
                              "expected a BufferPresentationService"
                              presentations))
       (render-service-render-with-presentations!
         service surface views presentations)]))
)
