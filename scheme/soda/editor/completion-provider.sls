(library (soda editor completion-provider)
  (export make-completion-provider
          completion-provider?
          completion-provider-name
          completion-provider-start
          completion-provider-cancel
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
          make-completion-response-for-request)
  (import (rnrs)
          (soda editor completion)
          (soda editor event))

  (define-record-type
    (completion-provider %make-completion-provider completion-provider?)
    (fields name start-procedure cancel-procedure))

  (define-record-type
    (completion-provider-catalog
      %make-completion-provider-catalog
      completion-provider-catalog?)
    (fields entries))

  (define-record-type
    (completion-provider-catalog-state
      %make-completion-provider-catalog-state
      completion-provider-catalog-state?)
    (fields entries))

  (define (make-completion-provider name start cancel)
    (unless (symbol? name)
      (assertion-violation
        'make-completion-provider
        "provider name must be a symbol"
        name))
    (unless (and (procedure? start) (procedure? cancel))
      (assertion-violation
        'make-completion-provider
        "provider operations must be procedures"
        name))
    (%make-completion-provider name start cancel))

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
          (for-all completion-response-message? messages))
        (assertion-violation
          'completion-provider-start
          "provider start must return completion response messages"
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

  (define (make-completion-provider-catalog)
    (%make-completion-provider-catalog (make-eq-hashtable)))

  (define (completion-provider-catalog-snapshot catalog)
    (unless (completion-provider-catalog? catalog)
      (assertion-violation
        'completion-provider-catalog-snapshot
        "expected a completion provider catalog"
        catalog))
    (%make-completion-provider-catalog-state
      (hashtable-copy
        (completion-provider-catalog-entries catalog)
        #t)))

  (define (completion-provider-catalog-restore! catalog snapshot)
    (unless (completion-provider-catalog? catalog)
      (assertion-violation
        'completion-provider-catalog-restore!
        "expected a completion provider catalog"
        catalog))
    (unless (completion-provider-catalog-state? snapshot)
      (assertion-violation
        'completion-provider-catalog-restore!
        "expected a completion provider catalog snapshot"
        snapshot))
    (hashtable-clear! (completion-provider-catalog-entries catalog))
    (let-values
      ([(names providers)
        (hashtable-entries
          (completion-provider-catalog-state-entries snapshot))])
      (let loop ([index 0])
        (unless (= index (vector-length names))
          (hashtable-set!
            (completion-provider-catalog-entries catalog)
            (vector-ref names index)
            (vector-ref providers index))
          (loop (+ index 1)))))
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
    (hashtable-set!
      (completion-provider-catalog-entries catalog)
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
    (hashtable-ref
      (completion-provider-catalog-entries catalog)
      name
      #f))

  (define (completion-provider-catalog-ref catalog name)
    (or
      (completion-provider-catalog-find catalog name)
      (assertion-violation
        'completion-provider-catalog-ref
        "unknown completion provider"
        name)))

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
    (vector->list
      (hashtable-keys
        (completion-provider-catalog-entries catalog))))

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
