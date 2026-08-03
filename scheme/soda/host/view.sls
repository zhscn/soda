(library (soda host view)
  (export view?
          view-id
          view-owner
          view-buffer
          view-state
          view-render-generation
          view-plugin-instances
          view-decorations
          view-merged-decorations
          view-display-stream
          view-display-transforms
          view-transform-display-stream
          view-update-plugins!
          make-view-service
          view-service?
          view-service-create!
          view-service-ref
          view-service-views
          view-service-close-buffer-views!
          view-service-set-plugin-error-handler!
          view-service-set-close-handler!
          view-service-close-view!)
  (import (soda host internal view)))
