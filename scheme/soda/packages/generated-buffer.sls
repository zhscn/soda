(library (soda packages generated-buffer)
  (export make-projection-update projection-update?
          projection-update-model-generation projection-update-text
          projection-update-item-ranges projection-update-decorations
          projection-update-semantic-position-map generated-projection-field
          generated-projection-extension make-projection-transaction-spec
          generated-buffer-input-layer
          make-generated-buffer-profile generated-buffer-profile?
          generated-buffer-profile-extensions
          generated-buffer-profile-command-categories
          make-semantic-position semantic-position?
          semantic-position-provider-id semantic-position-item-id
          semantic-position-offset-within-item semantic-position-fallback-offset
          semantic-position-desired-column semantic-position-at-point
          make-semantic-position-restore-effect)
  (import (rnrs)
          (soda host input)
          (soda packages buffer-ui internal))

  ;; A GeneratedBufferProfile is the shared interaction contract for
  ;; package-owned read-only result Buffers.  A package contributes only
  ;; producer-specific layers; generic motion, q-to-return, edit rejection,
  ;; optional projection state, and command capability categories remain
  ;; uniform across Help, listings, reports, and process output.
  (define-record-type
    (generated-buffer-profile %make-generated-buffer-profile generated-buffer-profile?)
    (fields (immutable extensions generated-buffer-profile-extensions)
            (immutable command-categories
                       generated-buffer-profile-command-categories)))

  (define (make-generated-buffer-profile projection? authority item? input-layers)
    (unless (and (boolean? projection?)
                 (or (not authority) (edit-authority? authority))
                 (boolean? item?)
                 (list? input-layers)
                 (for-all input-layer? input-layers))
      (assertion-violation
        'make-generated-buffer-profile
        "expected projection flag, optional edit authority, item flag, and InputLayers"
        projection? authority item? input-layers))
    (%make-generated-buffer-profile
      (append
        (cond [projection? (generated-projection-extension)]
              [item? (list (buffer-item-field-extension))]
              [else '()])
        (list
          (make-buffer-input-layer-extension
            (append input-layers
                    (list (generated-buffer-input-layer))))
          (make-buffer-edit-policy-extension
            (make-buffer-edit-policy 'reject #f authority))))
      (if item?
          '(generated-buffer buffer-item)
          '(generated-buffer)))))
