(library (soda host internal context)
  (export make-active-context
          active-context?
          active-context-surface-id
          active-context-window-id
          active-context-view-id
          active-context-buffer-id
          active-context-interaction-stack
          surface-active-context
          surface-select-view!
          surface-select-window!
          surface-replace-window-view-context!
          surface-split-view!
          surface-split-window-view!
          surface-remove-view-window!
          surface-push-interaction-view!
          surface-add-interaction-companion-view!
          surface-pop-interaction-view!
          surface-remove-interaction-view!
          surface-route-display-request!
          make-display-request
          display-request?
          display-request-buffer-id
          display-request-origin-view-id
          display-request-role
          display-request-focus-policy
          display-request-placement-hint
          display-request-provenance)
  (import (rnrs)
          (soda kernel value)
          (soda host internal buffer)
          (rename (soda host internal surface)
                  (surface-replace-window-view! surface-replace-window-view-on-surface!))
          (soda host internal view)
          (soda host internal window))

  ;; ActiveContext is a snapshot of the selected leaf.  It has no mutable
  ;; editor state, so an asynchronous package result can retain and validate
  ;; its origin without taking ownership of the Surface.
  (define-record-type
    (active-context %make-active-context active-context?)
    (fields surface-id window-id view-id buffer-id interaction-stack))

  (define identity? nonnegative-exact-integer?)

  (define (make-active-context surface-id window-id view-id buffer-id interaction-stack)
    (unless (and (identity? surface-id) (identity? window-id)
                 (identity? view-id) (identity? buffer-id)
                 (list? interaction-stack))
      (assertion-violation 'make-active-context "invalid active context"
                           surface-id window-id view-id buffer-id interaction-stack))
    (%make-active-context surface-id window-id view-id buffer-id
                          (append interaction-stack '())))

  (define (context-for-window surface views window)
    (let ([view (view-service-ref views (window-view-id window) #f)])
      (and view
           (make-active-context (surface-id surface)
                                (window-id window)
                                (view-id view)
                                (buffer-id (view-buffer view))
                                '()))))

  (define (surface-active-context surface views)
    (unless (and (surface? surface) (view-service? views))
      (assertion-violation 'surface-active-context
                           "expected a Surface and ViewService" surface views))
    (let ([window (surface-active-window surface)])
      (and window
           (let ([context (context-for-window surface views window)])
             (and context
                  (make-active-context
                    (active-context-surface-id context)
                    (active-context-window-id context)
                    (active-context-view-id context)
                    (active-context-buffer-id context)
                    (map window-id (surface-interaction-windows surface))))))))

  (define (surface-select-view! surface views target-view-id)
    (unless (and (surface? surface) (view-service? views) (identity? target-view-id))
      (assertion-violation 'surface-select-view!
                           "invalid Surface, ViewService, or View identity"
                           surface views target-view-id))
    (let ([target (view-service-ref views target-view-id #f)])
      (and target
           (let loop ([leaves (window-leaves (surface-root-window surface))])
             (cond
               [(null? leaves) #f]
               [(= (window-view-id (car leaves)) target-view-id)
                (surface-set-selected-window! surface (car leaves))
                (context-for-window surface views (car leaves))]
               [else (loop (cdr leaves))])))))

  (define (surface-select-window! surface views target-window-id)
    (unless (and (surface? surface) (view-service? views)
                 (identity? target-window-id))
      (assertion-violation 'surface-select-window!
                           "invalid Surface, ViewService, or Window identity"
                           surface views target-window-id))
    (let ([target
           (find
             (lambda (window) (= (window-id window) target-window-id))
             (surface-windows surface))])
      (and target
           (if (memq target (window-leaves (surface-root-window surface)))
               (begin
                 (surface-set-selected-window! surface target)
                 (context-for-window surface views target))
               (and (eq? target (surface-active-window surface))
                    (surface-active-context surface views))))))

  (define (surface-replace-window-view-context! surface views window-id view-id)
    (unless (and (surface? surface) (view-service? views) (identity? window-id)
                 (identity? view-id))
      (assertion-violation 'surface-replace-window-view-context!
                           "invalid Surface, ViewService, Window, or View identity"
                           surface views window-id view-id))
    (and (view-service-ref views view-id #f)
         (surface-replace-window-view-on-surface! surface window-id view-id)
         (surface-active-context surface views)))

  (define (surface-split-view! surface views axis target-view-id focus-policy)
    (unless (and (surface? surface) (view-service? views) (identity? target-view-id)
                 (memq axis '(horizontal vertical)) (memq focus-policy '(focus preserve)))
      (assertion-violation 'surface-split-view!
                           "invalid Surface split View request"
                           surface views axis target-view-id focus-policy))
    (and (view-service-ref views target-view-id #f)
         (let ([window
                (surface-split-selected-window! surface axis target-view-id focus-policy)])
           (context-for-window surface views window))))

  (define (surface-split-window-view!
            surface views window-id axis target-view-id focus-policy)
    (unless (and (surface? surface) (view-service? views) (identity? window-id)
                 (identity? target-view-id) (memq axis '(horizontal vertical))
                 (memq focus-policy '(focus preserve)))
      (assertion-violation 'surface-split-window-view!
                           "invalid explicit Surface split View request"
                           surface views window-id axis target-view-id focus-policy))
    (and (view-service-ref views target-view-id #f)
         (let ([window
                (surface-split-window!
                  surface window-id axis target-view-id focus-policy)])
           (and window (context-for-window surface views window)))))

  (define (surface-remove-view-window! surface views window-id)
    (unless (and (surface? surface) (view-service? views) (identity? window-id))
      (assertion-violation 'surface-remove-view-window!
                           "invalid Surface, ViewService, or Window identity"
                           surface views window-id))
    (let ([selected (surface-remove-window! surface window-id)])
      (and selected (context-for-window surface views selected))))

  (define (surface-push-interaction-view! surface views view-id height)
    (unless (and (surface? surface) (view-service? views) (identity? view-id))
      (assertion-violation 'surface-push-interaction-view!
                           "invalid Surface interaction View request" surface views view-id height))
    (and (view-service-ref views view-id #f)
         (let ([window (surface-push-interaction! surface view-id height)])
           (surface-active-context surface views))))

  (define (surface-add-interaction-companion-view!
            surface views anchor-view-id view-id height)
    (unless (and (surface? surface) (view-service? views)
                 (identity? anchor-view-id) (identity? view-id))
      (assertion-violation
        'surface-add-interaction-companion-view!
        "invalid Surface interaction companion request"
        surface views anchor-view-id view-id height))
    (and (view-service-ref views anchor-view-id #f)
         (view-service-ref views view-id #f)
         (surface-add-interaction-companion!
           surface anchor-view-id view-id height)
         (surface-active-context surface views)))

  (define (surface-pop-interaction-view! surface views)
    (unless (and (surface? surface) (view-service? views))
      (assertion-violation 'surface-pop-interaction-view!
                           "expected a Surface and ViewService" surface views))
    (and (surface-pop-interaction! surface)
         (surface-active-context surface views)))

  (define (surface-remove-interaction-view! surface views view-id)
    (unless (and (surface? surface) (view-service? views) (identity? view-id))
      (assertion-violation 'surface-remove-interaction-view!
                           "invalid Surface, ViewService, or View identity"
                           surface views view-id))
    (and (surface-remove-interaction! surface view-id)
         (surface-active-context surface views)))

  (define (window-for-buffer surface views buffer-id)
    (let* ([selected (surface-selected-window surface)]
           [selected-context
            (and selected (context-for-window surface views selected))])
      (if (and selected-context
               (= (active-context-buffer-id selected-context) buffer-id))
          selected
          (let loop ([leaves (window-leaves (surface-root-window surface))])
            (cond
              [(null? leaves) #f]
              [else
               (let ([context (context-for-window surface views (car leaves))])
                 (if (and context (= (active-context-buffer-id context) buffer-id))
                     (car leaves)
                     (loop (cdr leaves))))])))))

  ;; DisplayRequest carries package policy to the placement service without
  ;; embedding a package object in Surface, Window, or View state.  The host
  ;; accepts arbitrary role/hint/provenance payloads as opaque package values.
  (define-record-type
    (display-request %make-display-request display-request?)
    (fields buffer-id origin-view-id role focus-policy placement-hint provenance))

  (define (make-display-request buffer-id origin-view-id role focus-policy
                                placement-hint provenance)
    (unless (and (identity? buffer-id)
                 (or (not origin-view-id) (identity? origin-view-id))
                 (symbol? role)
                 (memq focus-policy '(focus preserve)))
      (assertion-violation 'make-display-request "invalid DisplayRequest"
                           buffer-id origin-view-id role focus-policy))
    (%make-display-request buffer-id origin-view-id role focus-policy
                           placement-hint provenance))

  ;; Packages use this resolver only for an existing projection.  A request
  ;; without a matching leaf remains unresolved, leaving Buffer/View creation
  ;; and split policy to the package-level placement implementation.
  (define (surface-route-display-request! surface views request)
    (unless (and (surface? surface) (view-service? views) (display-request? request))
      (assertion-violation 'surface-route-display-request!
                           "expected a Surface, ViewService, and DisplayRequest"
                           surface views request))
    (let ([window (window-for-buffer surface views (display-request-buffer-id request))])
      (and window
           (begin
             (when (eq? (display-request-focus-policy request) 'focus)
               (surface-set-selected-window! surface window))
             (context-for-window surface views window)))))
)
