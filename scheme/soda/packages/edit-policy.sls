(library (soda packages edit-policy)
  (export buffer-edit-policies-facet buffer-read-only-option
          buffer-read-only-facet buffer-read-only-compartment buffer-read-only?
          make-buffer-read-only-extension make-buffer-read-only-setting-extension
          make-edit-authority edit-authority? make-edit-authority-annotation
          make-buffer-edit-policy buffer-edit-policy?
          buffer-edit-policy-content-changes buffer-edit-policy-validator
          buffer-edit-policy-authority make-buffer-edit-policy-extension)
  (import (soda packages buffer-ui internal)))
