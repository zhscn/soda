(library (soda host view)
  (export view?
          view-id
          view-owner
          view-buffer
          view-state
          view-plugin-instances
          view-decorations
          view-display-streams
          view-display-transforms
          view-close!
          view-update-plugins!
          make-view-service
          view-service?
          view-service-create!
          view-service-ref
          view-service-views
          view-service-set-plugin-error-handler!
          view-service-close-view!)
  (import (soda host internal view)))
