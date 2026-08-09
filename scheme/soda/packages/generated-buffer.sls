(library (soda packages generated-buffer)
  (export make-projection-update projection-update?
          projection-update-model-generation projection-update-text
          projection-update-item-ranges projection-update-decorations
          projection-update-semantic-position-map generated-projection-field
          generated-projection-extension make-projection-transaction-spec
          make-semantic-position semantic-position?
          semantic-position-provider-id semantic-position-item-id
          semantic-position-offset-within-item semantic-position-fallback-offset
          semantic-position-desired-column semantic-position-at-point
          make-semantic-position-restore-effect)
  (import (soda packages buffer-ui internal)))
