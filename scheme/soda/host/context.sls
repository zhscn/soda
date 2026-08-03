(library (soda host context)
  (export make-active-context
          active-context?
          active-context-surface-id
          active-context-window-id
          active-context-view-id
          active-context-buffer-id
          active-context-interaction-stack
          surface-active-context
          surface-select-view!
          make-display-request
          display-request?
          display-request-buffer-id
          display-request-origin-view-id
          display-request-role
          display-request-focus-policy
          display-request-placement-hint
          display-request-provenance)
  (import (rnrs)
          (soda host buffer)
          (soda host surface)
          (soda host view)
          (soda host window))

  ;; ActiveContext is a snapshot of the selected leaf.  It has no mutable
  ;; editor state, so an asynchronous package result can retain and validate
  ;; its origin without taking ownership of the Surface.
  (define-record-type
    (active-context %make-active-context active-context?)
    (fields surface-id window-id view-id buffer-id interaction-stack))

  (define (identity? value)
    (and (integer? value) (exact? value) (>= value 0)))

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
    (let ([window (surface-selected-window surface)])
      (and window (context-for-window surface views window))))

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
)
