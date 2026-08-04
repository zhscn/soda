(library (soda host buffer)
  (export buffer?
          buffer-id
          buffer-name
          buffer-state
          buffer-service-add-close-listener!)
  (import (soda host internal buffer)))
