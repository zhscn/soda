(library (soda host frontend)
  (export host-frontend-surface-registered?
          host-frontend-active-view
          host-frontend-surface-message
          host-frontend-make-command-context
          host-frontend-resolve-scroll-request!
          host-frontend-enqueue!
          host-frontend-run!
          host-frontend-dispatch-view!
          host-frontend-dispatch-host!
          host-frontend-add-update-listener!
          host-frontend-add-host-listener!
          host-frontend-render!
          host-frontend-publish-render-feedback!
          host-frontend-capture-condition!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host condition)
          (soda host command)
          (soda host context)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host render)
          (soda host render-service)
          (soda host runtime)
          (soda host value)
          (soda view frame)
          (soda view text-layout))

  ;; Host-owned adapter for presentation loops. Registry traversal and render
  ;; feedback remain host policy rather than becoming frontend policy.
  (define (host-frontend-surface-registered? state surface)
    (and (host-state? state) (surface? surface)
         (eq? surface
              (surface-service-ref
                (host-state-surfaces state) (surface-id surface) #f))))

  (define (host-frontend-active-view state surface)
    (let* ([context (surface-active-context surface (host-state-views state))]
           [view (and context
                      (view-service-ref
                        (host-state-views state) (active-context-view-id context) #f))])
      (and context view (cons context view))))

  (define (host-frontend-surface-message state surface)
    (and (host-frontend-surface-registered? state surface)
         (surface-status-message surface)))

  (define (host-frontend-make-command-context
            state active event sequence prefix-argument source layout)
    (let* ([view
            (or (view-service-ref
                  (host-state-views state) (active-context-view-id active) #f)
                (assertion-violation
                  'host-frontend-make-command-context
                  "active View closed during input dispatch" active))]
           [buffer (view-buffer view)])
      (make-command-context
        #f
        (active-context-surface-id active)
        (active-context-window-id active)
        (view-id view)
        (buffer-id buffer)
        (buffer-state buffer)
        (view-state view)
        event sequence prefix-argument active source layout)))

  ;; Resolve a semantic scroll request against the immutable layout last
  ;; presented for its exact Surface/Window/View occurrence.  Host owns the
  ;; resulting View publication; text-layout owns the pure coordinate policy.
  (define (host-frontend-resolve-scroll-request! state active layout request)
    (unless (and (host-state? state) (active-context? active)
                 (text-layout? layout) (scroll-request? request))
      (assertion-violation
        'host-frontend-resolve-scroll-request!
        "invalid scroll request resolution input"
        state active layout request))
    (if (not (and (eq? (scroll-request-kind request) 'reveal-point)
                  (equal? (scroll-request-surface-id request)
                          (active-context-surface-id active))
                  (equal? (scroll-request-window-id request)
                          (active-context-window-id active))
                  (= (scroll-request-view-id request)
                     (active-context-view-id active))))
        #f
        (let* ([view
                (view-service-ref
                  (host-state-views state) (active-context-view-id active) #f)]
               [view-state (and view (view-state view))]
               [frame (text-layout-frame layout)]
               [width (frame-width frame)]
               [height (frame-height frame)])
          (and view-state (> width 0) (> height 0)
               (let* ([snapshot
                       (buffer-state-document (buffer-state (view-buffer view)))]
                      [text (snapshot-text snapshot)])
                 (dynamic-wind
                   (lambda () #f)
                   (lambda ()
                     (let* ([options
                             (configuration-facet
                               (view-state-configuration view-state)
                               text-layout-options-facet 'view)]
                            [point
                             (selection-range-head
                               (selection-primary-range
                                 (view-state-selection view-state)))]
                            [viewport
                             (text-layout-reveal-viewport
                               text options width height
                               (view-state-viewport view-state) point)])
                       (and (not (equal? viewport
                                         (view-state-viewport view-state)))
                            (dispatcher-dispatch-view!
                              (host-state-dispatch state)
                              (make-view-transaction-spec
                                (view-id view) (view-state-generation view-state)
                                #f viewport #f '() '() #f)))))
                   (lambda () (text-close! text))))))))

  (define (host-frontend-enqueue! state message)
    (runtime-enqueue! (host-state-runtime state) message))

  (define (host-frontend-run! state handler . limit)
    (if (null? limit)
        (host-state-run! state handler)
        (host-state-run! state handler (car limit))))

  (define (host-frontend-dispatch-view! state specification)
    (dispatcher-dispatch-view! (host-state-dispatch state) specification))

  (define (host-frontend-dispatch-host! state operation)
    (dispatcher-dispatch-host! (host-state-dispatch state) operation))

  (define (host-frontend-add-update-listener! state listener)
    (dispatcher-add-listener!
      (host-state-dispatch state) (host-state-owner state) listener))

  (define (host-frontend-add-host-listener! state listener)
    (dispatcher-add-host-listener!
      (host-state-dispatch state) (host-state-owner state) listener))

  (define (host-frontend-render! state service surface)
    (render-service-render! service surface (host-state-views state)))

  (define (add-occurrence groups id occurrence)
    (cond [(null? groups) (list (cons id (list occurrence)))]
          [(= id (caar groups))
           (cons (cons id (cons occurrence (cdar groups))) (cdr groups))]
          [else (cons (car groups) (add-occurrence (cdr groups) id occurrence))]))

  (define (host-frontend-publish-render-feedback! state render invalidate!)
    (let loop ([remaining (surface-render-rendered-views render)] [groups '()])
      (if (null? remaining)
          (for-each
            (lambda (group)
              (host-frontend-enqueue!
                state
                (lambda ()
                  (when (view-service-publish-occurrences!
                          (host-state-views state) (car group) (reverse (cdr group)))
                    (invalidate!)))))
            groups)
          (let ([item (car remaining)])
            (loop (cdr remaining)
                  (add-occurrence groups (rendered-view-view-id item)
                                  (rendered-view-occurrence item))))))
    (for-each
      (lambda (rendered)
        (for-each
          (lambda (failure)
            (host-frontend-enqueue!
              state
              (lambda ()
                (when (view-service-retire-projection-failure!
                        (host-state-views state)
                        (rendered-view-view-id rendered)
                        (rendered-view-projection-generation rendered)
                        (car failure) (cadr failure))
                  (invalidate!)))))
          (rendered-view-transform-failures rendered)))
      (surface-render-rendered-views render)))

  (define (host-frontend-capture-condition! state value)
    (condition-service-capture
      (host-state-conditions state) (host-state-owner state)
      value (lambda arguments #f) '(dismiss)))
)
