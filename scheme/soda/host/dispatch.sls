(library (soda host dispatch)
  (export make-editor-update editor-update? editor-update-buffer-id
          editor-update-old-buffer-state editor-update-new-buffer-state
          editor-update-views editor-update-changes editor-update-annotations
          editor-update-scroll-request editor-update-damage view-state-update?
          view-state-update-view-id view-state-update-old-state
          view-state-update-new-state make-dispatcher dispatcher?
          dispatcher-dispatch! dispatcher-dispatch-specs!
          dispatcher-dispatch-view! dispatcher-dispatch-host!
          dispatcher-publish-buffer-damage! dispatcher-set-error-reporter!
          dispatcher-set-listener! dispatcher-set-host-listener!
          dispatcher-add-listener! dispatcher-add-host-listener!
          dispatcher-register-global-operation-handler!)
  (import (soda host dispatch-core)
          (soda host dispatch-transaction)
          (soda host dispatch-operation)))
