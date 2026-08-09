(library (soda host render-service)
  (export make-render-service
          render-service?
          render-service-render!
          render-service-invalidate!
          render-service-last-render)
  (import (rnrs)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel value)
          (soda host internal buffer)
          (soda host render)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window))

  ;; Rendering is a pure projection, while this service owns the optional
  ;; frontend cache.  Surface generation covers tree, geometry, focus, size,
  ;; and chrome; each leaf adds only the published Buffer/View generations
  ;; which can change independently of its Surface placement.
  (define-record-type
    (render-service %make-render-service render-service?)
    (fields (mutable signature render-service-signature render-service-signature-set!)
            (mutable render render-service-last-render render-service-render-set!)
            (mutable epoch render-service-epoch render-service-epoch-set!)))

  (define (make-render-service)
    (%make-render-service #f #f 0))

  (define (view-render-token leaf views)
    (let ([view (view-service-ref views (window-view-id leaf) #f)])
      (if view
          (vector (window-view-id leaf)
                  (buffer-state-generation (buffer-state (view-buffer view)))
                  (view-render-generation view))
          (vector (window-view-id leaf) #f #f))))

  (define (surface-render-token service surface views)
    (vector (render-service-epoch service)
            (surface-id surface)
            (surface-generation surface)
            (map (lambda (leaf) (view-render-token leaf views))
                 (surface-windows surface))))

  (define (render-service-invalidate! service)
    (unless (render-service? service)
      (assertion-violation 'render-service-invalidate! "expected a RenderService" service))
    (render-service-epoch-set! service (+ 1 (render-service-epoch service)))
    #t)

  (define (render-service-render! service surface views)
    (unless (and (render-service? service) (surface? surface) (view-service? views))
      (assertion-violation 'render-service-render! "invalid render request" service surface views))
    (let ([signature (surface-render-token service surface views)])
      (if (equal? signature (render-service-signature service))
          (render-service-last-render service)
          (let ([render (render-surface surface views)])
            (render-service-signature-set! service signature)
            (render-service-render-set! service render)
            render))))
)
