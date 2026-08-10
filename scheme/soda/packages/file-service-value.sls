(library (soda packages file-service-value)
  (export make-file-service-value
          file-service?
          file-service-state
          file-service-host
          file-service-owner
          file-service-history
          file-keymap
          file-service-watch-service
          file-service-recovery
          file-service-recovery-set!
          file-service-mode-registry)
  (import (rnrs))

  (define-record-type
    (file-service make-file-service-value file-service?)
    (fields
      (immutable state file-service-state)
      (immutable host file-service-host)
      (immutable owner file-service-owner)
      (immutable history file-service-history)
      (immutable keymap file-keymap)
      (immutable watch-service file-service-watch-service)
      (mutable recovery file-service-recovery file-service-recovery-set!)
      (immutable mode-registry file-service-mode-registry)))
)
