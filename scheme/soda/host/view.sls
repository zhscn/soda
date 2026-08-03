(library (soda host view)
  (export view?
          view-id
          view-owner
          view-buffer
          view-state
          view-close!
          make-view-service
          view-service?
          view-service-create!
          view-service-ref
          view-service-views
          view-service-close-view!)
  (import (soda host internal view)))
