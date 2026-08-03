(library (soda host buffer)
  (export buffer?
          buffer-id
          buffer-owner
          buffer-name
          buffer-state
          make-buffer-service
          buffer-service?
          buffer-service-create!
          buffer-service-ref
          buffer-service-buffers
          buffer-service-set-close-handler!
          buffer-service-close-buffer!)
  (import (soda host internal buffer)))
