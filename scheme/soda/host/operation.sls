(library (soda host operation)
  (export host-operation?
          host-operation-kind
          host-operation-surface-id
          host-operation-value
          make-focus-view-operation
          make-focus-window-operation
          make-replace-window-view-operation
          make-split-view-operation
          make-remove-window-operation
          make-push-interaction-operation
          make-pop-interaction-operation
          make-display-request-operation
          make-resize-surface-operation
          make-invalidate-surface-operation
          make-set-surface-feedback-operation
          make-set-surface-shortcut-hints-operation
          host-update?
          host-update-operation
          host-update-surface-id
          host-update-old-context
          host-update-new-context
          host-update-resolution
          host-update-damage)
  (import (except (soda host internal operation) make-host-update))
)
