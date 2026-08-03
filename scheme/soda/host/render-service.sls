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
                (view-render-generation view))
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
          ;; A render-local transform can retire itself after a contained
          ;; failure.  Retry once against the newly published View cache so a
          ;; failed plugin cannot leave its pre-failure output on screen.
          (let build ([attempt-signature signature] [retries 1])
            (let* ([render (render-surface surface views)]
                   [current-signature (render-signature service surface views)])
              (if (and (> retries 0)
                       (not (equal? attempt-signature current-signature)))
                  (build current-signature (- retries 1))
                  (begin
                    (render-service-signature-set! service attempt-signature)
                    (render-service-render-set! service render)
                    render)))))))
)
