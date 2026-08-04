(library (soda host buffer-attachment)
  (export buffer-attachment?
          buffer-attachment-key
          buffer-attachment-owner
          buffer-attachment-buffer-id
          buffer-attachment-generation
          buffer-attachment-close-query
          buffer-attachment-refresh)
  (import (soda host internal buffer-attachment)))
