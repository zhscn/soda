(library (soda host surface)
  (export make-surface
          surface?
          surface-id
          surface-frontend
          surface-capabilities
          surface-size
          surface-root-window
          surface-selected-window
          surface-interaction-windows
          surface-active-window
          surface-windows
          surface-generation
          make-surface-service
          surface-service?
          surface-service-register!
          surface-service-ref
          surface-service-surfaces
          surface-service-remove!
          make-surface-input-message
          surface-input-message?
          surface-input-message-surface-id
          surface-input-message-event)
  (import
    (except (soda host internal surface)
            surface-set-selected-window!
            surface-split-selected-window!
            surface-remove-window!
            surface-push-interaction!
            surface-pop-interaction!
            surface-resize!
            surface-service-prune-view!))
)
