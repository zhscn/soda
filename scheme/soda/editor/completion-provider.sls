(library (soda editor completion-provider)
  (export make-completion-provider
          completion-provider?
          completion-provider-name
          completion-provider-start
          completion-provider-cancel
          completion-provider-resolve
          make-completion-provider-catalog
          completion-provider-catalog?
          completion-provider-catalog-snapshot
          completion-provider-catalog-restore!
          completion-provider-catalog-register!
          completion-provider-catalog-find
          completion-provider-catalog-ref
          completion-provider-for-request
          completion-provider-catalog-bind-request!
          completion-provider-catalog-names
          editor-register-completion-provider!
          editor-take-completion-effects!
          make-completion-response-for-request)
  (import (rnrs)
          (soda editor command)
          (soda editor completion)
          (soda editor editor-storage)
          (soda editor event)
          (soda editor ordered-registry))

  (define-record-type
    (completion-provider %make-completion-provider completion-provider?)
    (fields
      name
      start-procedure
      cancel-procedure
      resolve-procedure))

  (define-record-type
    (completion-provider-catalog
      %make-completion-provider-catalog
      completion-provider-catalog?)
    (fields registry))

  (define make-completion-provider
    (case-lambda
      [(name start cancel)
       (make-completion-provider
         name
         start
         cancel
         (lambda (item) #f))]
      [(name start cancel resolve)
       (unless (symbol? name)
         (assertion-violation
           'make-completion-provider
           "provider name must be a symbol"
           name))
       (unless
         (and
           (procedure? start)
           (procedure? cancel)
           (procedure? resolve))
         (assertion-violation
           'make-completion-provider
           "provider operations must be procedures"
           name))
       (%make-completion-provider name start cancel resolve)]))

  (define (completion-provider-start provider request)
    (unless (completion-provider? provider)
      (assertion-violation
        'completion-provider-start
        "expected a completion provider"
        provider))
    (unless (completion-request? request)
      (assertion-violation
        'completion-provider-start
        "expected a completion request"
        request))
    (unless (eq? (completion-provider-name provider)
                 (completion-request-provider request))
      (assertion-violation
        'completion-provider-start
        "request names another provider"
        (completion-request-provider request)))
    (let ([messages
            ((completion-provider-start-procedure provider)
             request)])
      (unless
        (and
          (list? messages)
          (for-all
            (lambda (message)
              (or (completion-response-message? message)
                  (internal-command-message? message)))
            messages))
        (assertion-violation
          'completion-provider-start
          "provider start must return completion responses or internal command messages"
          messages))
      messages))

  (define (completion-provider-cancel provider request)
    (unless (completion-provider? provider)
      (assertion-violation
        'completion-provider-cancel
        "expected a completion provider"
        provider))
    (unless (completion-request? request)
      (assertion-violation
        'completion-provider-cancel
        "expected a completion request"
        request))
    (unless (eq? (completion-provider-name provider)
                 (completion-request-provider request))
      (assertion-violation
        'completion-provider-cancel
        "request names another provider"
        (completion-request-provider request)))
    ((completion-provider-cancel-procedure provider) request))

  (define (completion-provider-resolve provider item)
    (unless (completion-provider? provider)
      (assertion-violation
        'completion-provider-resolve
        "expected a completion provider"
        provider))
    (unless (completion-item? item)
      (assertion-violation
        'completion-provider-resolve
        "expected a completion item"
        item))
    (unless
      (eq?
        (completion-provider-name provider)
        (completion-item-provider item))
      (assertion-violation
        'completion-provider-resolve
        "item names another provider"
        (completion-item-provider item)))
    (let ([resolved
            ((completion-provider-resolve-procedure provider) item)])
      (unless
        (or
          (not resolved)
          (eq? resolved 'pending)
          (and
            (completion-item? resolved)
            (completion-item-resolved? resolved)
            (equal?
              (completion-item-id resolved)
              (completion-item-id item))
            (eq?
              (completion-item-provider resolved)
              (completion-item-provider item))))
        (assertion-violation
          'completion-provider-resolve
          "provider resolve returned an invalid completion item"
          resolved))
      resolved))

  (define (make-completion-provider-catalog)
    (%make-completion-provider-catalog (make-ordered-registry)))

  (define (completion-provider-catalog-snapshot catalog)
    (unless (completion-provider-catalog? catalog)
      (assertion-violation
        'completion-provider-catalog-snapshot
        "expected a completion provider catalog"
        catalog))
    (ordered-registry-snapshot
      (completion-provider-catalog-registry catalog)))

  (define (completion-provider-catalog-restore! catalog snapshot)
    (unless (completion-provider-catalog? catalog)
      (assertion-violation
        'completion-provider-catalog-restore!
        "expected a completion provider catalog"
        catalog))
    (ordered-registry-restore!
      (completion-provider-catalog-registry catalog)
      snapshot)
    catalog)

  (define (completion-provider-catalog-register! catalog provider)
    (unless (completion-provider-catalog? catalog)
      (assertion-violation
        'completion-provider-catalog-register!
        "expected a completion provider catalog"
        catalog))
    (unless (completion-provider? provider)
      (assertion-violation
        'completion-provider-catalog-register!
        "expected a completion provider"
        provider))
    (ordered-registry-set!
      (completion-provider-catalog-registry catalog)
      (completion-provider-name provider)
      provider)
    provider)

  (define (completion-provider-catalog-find catalog name)
    (unless (completion-provider-catalog? catalog)
      (assertion-violation
        'completion-provider-catalog-find
        "expected a completion provider catalog"
        catalog))
    (unless (symbol? name)
      (assertion-violation
        'completion-provider-catalog-find
        "provider name must be a symbol"
        name))
    (ordered-registry-ref
      (completion-provider-catalog-registry catalog)
      name))

  (define (completion-provider-catalog-ref catalog name)
    (or
      (completion-provider-catalog-find catalog name)
      (assertion-violation
        'completion-provider-catalog-ref
        "unknown completion provider"
        name)))

  (define (editor-register-completion-provider! editor provider)
    (require-open-editor
      'editor-register-completion-provider!
      editor)
    (completion-provider-catalog-register!
      (editor-completion-provider-catalog editor)
      provider))

  (define (completion-effect? effect)
    (memq
      (command-effect-kind effect)
      '(completion.request completion.cancel)))

  (define (editor-take-completion-effects! editor)
    (require-open-editor
      'editor-take-completion-effects!
      editor)
    (let-values
      ([(completion remaining)
        (partition
          completion-effect?
          (editor-effects editor))])
      (editor-effects-set! editor remaining)
      completion))

  (define (completion-provider-for-request catalog request)
    (unless (completion-request? request)
      (assertion-violation
        'completion-provider-for-request
        "expected a completion request"
        request))
    (or
      (completion-request-provider-instance request)
      (completion-provider-catalog-ref
        catalog
        (completion-request-provider request))))

  (define (completion-provider-catalog-bind-request! catalog request)
    (let ([provider
            (completion-provider-for-request catalog request)])
      (unless (completion-request-provider-instance request)
        (completion-request-provider-instance-set!
          request
          provider))
      provider))

  (define (completion-provider-catalog-names catalog)
    (unless (completion-provider-catalog? catalog)
      (assertion-violation
        'completion-provider-catalog-names
        "expected a completion provider catalog"
        catalog))
    (ordered-registry-names
      (completion-provider-catalog-registry catalog)))

  (define (make-completion-response-for-request
            request
            items
            complete?)
    (unless (completion-request? request)
      (assertion-violation
        'make-completion-response-for-request
        "expected a completion request"
        request))
    (make-completion-response-message
      (completion-request-session-id request)
      (completion-request-generation request)
      (completion-request-provider request)
      (completion-request-target-id request)
      (completion-request-target-revision request)
      items
      complete?)))
