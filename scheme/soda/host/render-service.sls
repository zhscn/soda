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
          (soda host buffer)
          (soda host render)
          (soda host surface)
          (soda host view)
          (soda host window))

  ;; Rendering is a pure projection, while this service owns the optional
  ;; frontend cache.  Its signature contains only published generations and
  ;; Surface geometry, so no mutable editor value enters a Frame cache key.
  (define-record-type
    (render-service %make-render-service render-service?)
    (fields (mutable signature render-service-signature render-service-signature-set!)
            (mutable render render-service-last-render render-service-render-set!)
            (mutable epoch render-service-epoch render-service-epoch-set!)))

  (define (make-render-service)
    (%make-render-service #f #f 0))

  (define (leaf-signature leaf views)
    (let ([view (view-service-ref views (window-view-id leaf) #f)])
      (if view
          (list (window-view-id leaf)
                (list-copy (window-rectangle leaf))
                (buffer-state-generation (buffer-state (view-buffer view)))
                (view-state-generation (view-state view))
                (view-state-configuration (view-state view)))
          (list (window-view-id leaf) (list-copy (window-rectangle leaf)) #f #f))))

  (define (render-signature service surface views)
    (list (render-service-epoch service)
          (surface-id surface)
          (surface-generation surface)
          (let ([size (surface-size surface)]) (cons (car size) (cdr size)))
          (map (lambda (leaf) (leaf-signature leaf views))
               (window-leaves (surface-root-window surface)))))

  (define (render-service-invalidate! service)
    (unless (render-service? service)
      (assertion-violation 'render-service-invalidate! "expected a RenderService" service))
    (render-service-epoch-set! service (+ 1 (render-service-epoch service)))
    #t)

  (define (render-service-render! service surface views)
    (unless (and (render-service? service) (surface? surface) (view-service? views))
      (assertion-violation 'render-service-render! "invalid render request" service surface views))
    (let ([signature (render-signature service surface views)])
      (if (equal? signature (render-service-signature service))
          (render-service-last-render service)
          (let ([render (render-surface surface views)])
            (render-service-signature-set! service signature)
            (render-service-render-set! service render)
            render))))
)
