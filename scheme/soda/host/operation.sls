(library (soda host operation)
  (export host-operation?
          host-operation-kind
          host-operation-surface-id
          host-operation-value
          make-focus-view-operation
          make-display-request-operation
          host-update?
          host-update-operation
          host-update-surface-id
          host-update-old-context
          host-update-new-context
          host-update-resolution
          host-update-damage)
  (import (except (soda host internal operation) make-host-update))
)
