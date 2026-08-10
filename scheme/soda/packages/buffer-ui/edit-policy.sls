(library (soda packages buffer-ui edit-policy)
  (export buffer-edit-policies-facet
          make-edit-authority
          edit-authority?
          make-edit-authority-annotation
          make-buffer-edit-policy
          buffer-edit-policy?
          buffer-edit-policy-content-changes
          buffer-edit-policy-validator
          buffer-edit-policy-authority
          make-buffer-edit-policy-extension)
  (import (rnrs)
          (soda kernel change)
          (soda kernel extension)
          (soda kernel state)
          (soda host value))

  (define (append-values values)
    (fold-left append '() values))

  (define buffer-edit-policies-facet
    (make-facet 'buffer-edit-policies 'buffer '() append-values eq? eq?))

  ;; Edit authority is owner-scoped and carried by a transaction annotation.
  ;; A producer can update its protected Buffer without granting unrelated
  ;; commands permission to bypass the policy.
  (define-record-type
    (edit-authority %make-edit-authority edit-authority?)
    (fields (immutable owner edit-authority-owner)
            (immutable name edit-authority-name)))

  (define (make-edit-authority owner name)
    (unless (and (owner? owner) (symbol? name))
      (assertion-violation
        'make-edit-authority "expected an owner and symbolic name" owner name))
    (owner-assert-active 'make-edit-authority owner)
    (%make-edit-authority owner name))

  (define (make-edit-authority-annotation authority)
    (unless (edit-authority? authority)
      (assertion-violation
        'make-edit-authority-annotation "expected an EditAuthority" authority))
    (make-annotation 'buffer-edit-authority authority))

  (define-record-type
    (buffer-edit-policy %make-buffer-edit-policy buffer-edit-policy?)
    (fields (immutable content-changes buffer-edit-policy-content-changes)
            (immutable validator buffer-edit-policy-validator)
            (immutable authority buffer-edit-policy-authority)))

  (define make-buffer-edit-policy
    (case-lambda
      [(content-changes) (make-buffer-edit-policy content-changes #f #f)]
      [(content-changes validator authority)
       (unless (and (memq content-changes '(allow reject validate))
                    (or (not validator) (procedure? validator))
                    (or (not authority) (edit-authority? authority)))
         (assertion-violation
           'make-buffer-edit-policy "invalid EditPolicy"
           content-changes validator authority))
       (when (and (eq? content-changes 'validate) (not validator))
         (assertion-violation
           'make-buffer-edit-policy "validate policy requires a validator"
           content-changes))
       (%make-buffer-edit-policy content-changes validator authority)]))

  (define (transaction-authorized? transaction authority)
    (and authority
         (owner-active? (edit-authority-owner authority))
         (exists
           (lambda (annotation)
             (and (eq? (annotation-key annotation) 'buffer-edit-authority)
                  (eq? (annotation-value annotation) authority)))
           (resolved-transaction-annotations transaction))))

  (define (apply-edit-policy policy transaction)
    (if (or (change-set-empty? (resolved-transaction-changes transaction))
            (transaction-authorized? transaction
                                     (buffer-edit-policy-authority policy)))
        transaction
        (case (buffer-edit-policy-content-changes policy)
          [(allow) transaction]
          [(reject) #f]
          [(validate)
           (and ((buffer-edit-policy-validator policy) transaction) transaction)])))

  (define (make-buffer-edit-policy-extension policy)
    (unless (buffer-edit-policy? policy)
      (assertion-violation
        'make-buffer-edit-policy-extension "expected an EditPolicy" policy))
    (let ([filter
           (lambda (state transaction)
             (apply-edit-policy policy transaction))])
      (list (make-facet-provider buffer-edit-policies-facet (list policy))
            (make-facet-provider transaction-filters-facet (list filter)))))
)
