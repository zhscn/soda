(library (soda host buffer)
  (export buffer?
          buffer-id
          buffer-name
          buffer-lifecycle
          buffer-live?
          buffer-state
          make-buffer-key
          buffer-key?
          buffer-key-namespace
          buffer-key-identity
          scratch-buffer-key
          buffer-service-add-close-listener!)
  (import (soda host internal buffer)))
