(library (soda host context)
  (export make-active-context
          active-context?
          active-context-surface-id
          active-context-window-id
          active-context-view-id
          active-context-buffer-id
          active-context-interaction-stack
          surface-active-context
          make-display-request
          display-request?
          display-request-buffer-id
          display-request-origin-view-id
          display-request-role
          display-request-focus-policy
          display-request-placement-hint
          display-request-provenance)
  (import
    (except (soda host internal context)
            surface-select-view!
            surface-select-window!
            surface-split-view!
            surface-remove-view-window!
            surface-push-interaction-view!
            surface-pop-interaction-view!
            surface-route-display-request!))
)
