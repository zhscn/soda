(library (soda packages file-service)
  (export make-file-service! file-service? file-service-resource
          file-service-format file-service-conflict file-service-recovery
          file-service-watch-service
          file-service-attach-runtime! file-service-handle-runtime-event!
          file-service-register-mode! file-service-modified-count
          file-service-shutdown-effects file-service-rename-resource!
          file-service-delete-resource! file-conflict? file-conflict-buffer-id
          file-conflict-resource file-conflict-version file-conflict-kind
          file-conflict-status file-keymap)
  (import (soda packages file internal)))
