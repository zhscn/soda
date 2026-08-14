(library (soda host dispatch surface-operation)
  (export dispatch-surface-operation!)
  (import (rnrs)
          (soda host internal context)
          (soda host internal operation)
          (soda host internal surface)
          (soda host internal view))

  (define (operation-damage operation start-generation surface)
    (if (= start-generation (surface-generation surface))
        '()
        (case (host-operation-kind operation)
          [(resize-surface) '(resize layout)]
          [(invalidate-surface) '(redraw)]
          [else '(chrome)])))

  (define (apply-surface-operation! surface views operation)
    (case (host-operation-kind operation)
      [(focus-view)
       (surface-select-view! surface views (host-operation-value operation))]
      [(focus-window)
       (surface-select-window! surface views (host-operation-value operation))]
      [(replace-window-view)
       (let ([value (host-operation-value operation)])
         (surface-replace-window-view-context!
           surface views (car value) (cadr value)))]
      [(split-view)
       (let ([value (host-operation-value operation)])
         (surface-split-view!
           surface views (car value) (cadr value) (caddr value)))]
      [(remove-window)
       (surface-remove-view-window!
         surface views (host-operation-value operation))]
      [(push-interaction)
       (let ([value (host-operation-value operation)])
         (surface-push-interaction-view!
           surface views (car value) (cadr value)))]
      [(add-interaction-companion)
       (let ([value (host-operation-value operation)])
         (surface-add-interaction-companion-view!
           surface views (car value) (cadr value) (caddr value)))]
      [(pop-interaction)
       (surface-pop-interaction-view! surface views)]
      [(remove-interaction)
       (surface-remove-interaction-view!
         surface views (host-operation-value operation))]
      [(display-request)
       (surface-route-display-request!
         surface views (host-operation-value operation))]
      [(resize-surface)
       (and (surface-resize! surface (host-operation-value operation))
            (surface-active-context surface views))]
      [(invalidate-surface)
       (and (surface-invalidate! surface) #t)]
      [(set-surface-feedback)
       (and (surface-set-feedback! surface (host-operation-value operation)) #t)]
      [(set-surface-shortcut-hints)
       (and (surface-set-shortcut-hints!
              surface (host-operation-value operation))
            #t)]
      [else
       (assertion-violation
         'dispatch-surface-operation! "unsupported Surface HostOperation"
         operation)]))

  (define (dispatch-surface-operation! surfaces views operation)
    (unless (and (surface-service? surfaces) (view-service? views)
                 (host-operation? operation)
                 (host-operation-surface-id operation))
      (assertion-violation
        'dispatch-surface-operation!
        "expected services and a Surface HostOperation"
        surfaces views operation))
    (let ([surface
           (surface-service-ref surfaces (host-operation-surface-id operation) #f)])
      (and surface
           (let* ([start-generation (surface-generation surface)]
                  [old-context (surface-active-context surface views)]
                  [resolution (apply-surface-operation! surface views operation)]
                  [_retired
                   (when (and old-context
                              (eq? (host-operation-kind operation)
                                   'replace-window-view)
                              (not (surface-service-view-retained?
                                     surfaces
                                     (active-context-view-id old-context))))
                     (view-service-close-view!
                       views (active-context-view-id old-context)))]
                  [new-context (surface-active-context surface views)])
             (and resolution
                  (make-host-update
                    operation (surface-id surface) old-context new-context resolution
                    (operation-damage operation start-generation surface)))))))
)
