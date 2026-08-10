(library (soda packages buffer-ui configuration)
  (export buffer-input-layers-facet
          buffer-read-only-option
          buffer-read-only-facet
          buffer-read-only-compartment
          buffer-read-only?
          buffer-display-profile-facet
          buffer-item-ranges-facet
          buffer-update-listeners-facet
          make-buffer-input-layer-extension
          buffer-input-context
          make-buffer-display-profile-extension
          make-buffer-read-only-extension
          make-buffer-read-only-setting-extension)
  (import (rnrs)
          (soda kernel change)
          (soda kernel extension)
          (soda kernel option)
          (soda kernel state)
          (soda kernel view-state)
          (soda host buffer)
          (soda host context)
          (soda host input)
          (soda host value)
          (soda host view))

  (define (append-values values)
    (fold-left append '() values))

  (define (append-values-in-precedence-order values)
    (fold-left (lambda (result value) (append value result)) '() values))

  (define buffer-input-layers-facet
    (make-facet 'buffer-input-layers 'buffer '()
                append-values-in-precedence-order equal? equal?))

  (define buffer-read-only-option
    (make-option-spec
      'buffer-read-only #f boolean? eq?
      "Whether ordinary editing commands may change the Buffer."))
  (define buffer-read-only-facet (option-spec-facet buffer-read-only-option))
  (define buffer-read-only-compartment
    (option-spec-compartment buffer-read-only-option))

  (define buffer-display-profile-facet
    (make-facet 'buffer-display-profile 'buffer '() append-values equal? equal?))
  (define buffer-item-ranges-facet
    (make-facet 'buffer-item-ranges 'buffer '() list-copy eq? eq?))
  (define buffer-update-listeners-facet update-listeners-facet)

  (define (make-buffer-input-layer-extension layers)
    (unless (and (list? layers) (for-all input-layer? layers))
      (assertion-violation
        'make-buffer-input-layer-extension
        "expected a list of InputLayer values" layers))
    (make-facet-provider buffer-input-layers-facet (list-copy layers)))

  (define (buffer-input-context active view fallback-layers)
    (unless (and (active-context? active) (view? view)
                 (list? fallback-layers) (for-all input-layer? fallback-layers))
      (assertion-violation
        'buffer-input-context "invalid active context, View, or InputLayer values"
        active view fallback-layers))
    (unless (and (= (active-context-view-id active) (view-id view))
                 (= (active-context-buffer-id active)
                    (buffer-id (view-buffer view))))
      (assertion-violation
        'buffer-input-context "active context does not identify the supplied View"
        active view))
    (let* ([state (buffer-state (view-buffer view))]
           [layers
            (configuration-facet
              (buffer-state-configuration state) buffer-input-layers-facet 'buffer)])
      (make-input-context
        (active-context-view-id active)
        (active-context-buffer-id active)
        (input-layer-compose (append layers fallback-layers))
        (view-state-input-state (view-state view)))))

  (define (make-buffer-display-profile-extension contributions)
    (unless (list? contributions)
      (assertion-violation
        'make-buffer-display-profile-extension
        "display profile contributions must be a list" contributions))
    (make-facet-provider buffer-display-profile-facet (list-copy contributions)))

  (define (buffer-read-only? configuration)
    (option-ref configuration buffer-read-only-option))

  (define (make-read-only-filter-extension)
    (make-facet-provider
      transaction-filters-facet
      (list
        (lambda (state transaction)
          (if (or (change-set-empty? (resolved-transaction-changes transaction))
                  (not (buffer-read-only? (buffer-state-configuration state))))
              transaction
              #f)))))

  (define (make-buffer-read-only-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation
        'make-buffer-read-only-extension "expected a read-only boolean" enabled?))
    (list (make-buffer-local-option-extension buffer-read-only-option enabled?)
          (make-read-only-filter-extension)))

  (define (make-buffer-read-only-setting-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation
        'make-buffer-read-only-setting-extension
        "expected a read-only boolean" enabled?))
    (list (make-facet-provider buffer-read-only-facet enabled?)
          (make-read-only-filter-extension)))
)
