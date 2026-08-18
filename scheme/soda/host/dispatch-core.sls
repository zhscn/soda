(library (soda host dispatch-core)
  (export make-editor-update editor-update? editor-update-buffer-id
          editor-update-old-buffer-state editor-update-new-buffer-state
          editor-update-views editor-update-changes editor-update-annotations
          editor-update-scroll-request editor-update-damage view-state-update?
          view-state-update-view-id view-state-update-old-state
          view-state-update-new-state make-dispatcher dispatcher?
          dispatcher-set-error-reporter! dispatcher-set-listener!
          dispatcher-set-host-listener! dispatcher-add-listener!
          dispatcher-add-commit-participant!
          dispatcher-add-host-listener!)
  (import (soda host dispatch internal)))
