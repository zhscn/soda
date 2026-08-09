(library (soda host internal setting)
  (export make-setting-service
          setting-service?
          setting-service-register!
          setting-service-ref
          setting-service-schemas
          setting-service-parse
          setting-service-make-reload-operation
          setting-service-apply-reload!
          setting-service-apply-reload-request!
          setting-service-source
          setting-service-resolve
          setting-service-resolved-settings
          setting-service-extensions)
  (import (rnrs)
          (only (chezscheme) equal-hash)
          (soda kernel resource)
          (soda host internal operation)
          (soda host setting)
          (soda host value))

  (define-record-type schema-entry
    (fields owner schema))

  (define-record-type
    (setting-service %make-setting-service setting-service?)
    (fields table sources
            (mutable next-order setting-service-next-order
                     setting-service-next-order-set!)))

  (define-record-type
    (source-entry %make-source-entry source-entry?)
    (fields owner order
            (mutable source source-entry-source source-entry-source-set!)
            (mutable values source-entry-values source-entry-values-set!)))

  (define-record-type configuration-reload-request
    (fields owner source))

  (define (make-setting-service)
    (%make-setting-service (make-eq-hashtable) (make-eq-hashtable) 0))

  (define (setting-service-register! service owner schema)
    (unless (and (setting-service? service) (owner? owner)
                 (setting-schema? schema))
      (assertion-violation
        'setting-service-register! "invalid SettingSchema registration"
        service owner schema))
    (owner-assert-active 'setting-service-register! owner)
    (let ([name (setting-schema-name schema)])
      (when (hashtable-ref (setting-service-table service) name #f)
        (assertion-violation
          'setting-service-register! "SettingSchema is already registered" name))
      (let ([entry (make-schema-entry owner schema)])
        (hashtable-set! (setting-service-table service) name entry)
        (make-registration
          owner
          (lambda ()
            (when (eq? (hashtable-ref
                         (setting-service-table service) name #f)
                       entry)
              (hashtable-delete! (setting-service-table service) name)))))))

  (define (setting-service-ref service name . default)
    (unless (and (setting-service? service) (symbol? name))
      (assertion-violation
        'setting-service-ref "expected a SettingService and name" service name))
    (let ([entry (hashtable-ref (setting-service-table service) name #f)])
      (if entry
          (schema-entry-schema entry)
          (if (null? default) #f (car default)))))

  (define (setting-service-schemas service)
    (unless (setting-service? service)
      (assertion-violation
        'setting-service-schemas "expected a SettingService" service))
    (call-with-values
      (lambda () (hashtable-entries (setting-service-table service)))
      (lambda (names entries)
        (map schema-entry-schema (vector->list entries)))))

  (define (setting-service-parse service name input scope source)
    (let ([schema (setting-service-ref service name #f)])
      (unless schema
        (assertion-violation
          'setting-service-parse "unknown setting" name))
      (make-setting-value schema input scope source)))

  (define (setting-service-make-reload-operation service owner source)
    (unless (and (setting-service? service) (owner? owner)
                 (configuration-source? source))
      (assertion-violation
        'setting-service-make-reload-operation
        "invalid ConfigurationSource reload" service owner source))
    (owner-assert-active 'setting-service-make-reload-operation owner)
    (make-global-host-operation
      'configuration-source-reload
      (make-configuration-reload-request owner source)))

  (define (parse-source service source)
    (let ([seen (make-hashtable equal-hash equal?)])
      (map
        (lambda (declaration)
          (let ([token
                 (cons (setting-declaration-name declaration)
                       (setting-declaration-scope declaration))])
            (when (hashtable-ref seen token #f)
              (assertion-violation
                'configuration-source-reload
                "duplicate setting declaration in one source"
                (configuration-source-id source) token))
            (hashtable-set! seen token #t)
            (setting-service-parse
              service
              (setting-declaration-name declaration)
              (setting-declaration-input declaration)
              (setting-declaration-scope declaration)
              (setting-declaration-source declaration))))
        (configuration-source-declarations source))))

  (define (remove-source! service id entry)
    (when (eq? (hashtable-ref (setting-service-sources service) id #f) entry)
      (hashtable-delete! (setting-service-sources service) id)))

  ;; Parsing is completed before the source table changes.  A parser or
  ;; validator failure therefore leaves the previous generation observable.
  (define (setting-service-apply-reload! service owner source)
    (unless (and (setting-service? service) (owner? owner)
                 (configuration-source? source))
      (assertion-violation
        'setting-service-apply-reload! "invalid ConfigurationSource reload"
        service owner source))
    (owner-assert-active 'setting-service-apply-reload! owner)
    (let* ([id (configuration-source-id source)]
           [existing (hashtable-ref (setting-service-sources service) id #f)]
           [values (parse-source service source)])
      (when (and existing (not (eq? (source-entry-owner existing) owner)))
        (assertion-violation
          'setting-service-apply-reload!
          "ConfigurationSource belongs to another Owner" id))
      (when (and existing
                 (<= (configuration-source-generation source)
                     (configuration-source-generation
                       (source-entry-source existing))))
        (assertion-violation
          'setting-service-apply-reload!
          "ConfigurationSource generation must increase" id))
      (if existing
          (begin
            (source-entry-source-set! existing source)
            (source-entry-values-set! existing values)
            source)
          (let* ([order (+ 1 (setting-service-next-order service))]
                 [entry (%make-source-entry owner order source values)])
            (setting-service-next-order-set! service order)
            (hashtable-set! (setting-service-sources service) id entry)
            (make-registration
              owner (lambda () (remove-source! service id entry)))
            source))))

  (define (setting-service-apply-reload-request! service request)
    (unless (and (setting-service? service)
                 (configuration-reload-request? request))
      (assertion-violation
        'configuration-source-reload "invalid reload operation" request))
    (setting-service-apply-reload!
      service
      (configuration-reload-request-owner request)
      (configuration-reload-request-source request)))

  (define (setting-service-source service id . default)
    (unless (and (setting-service? service) (symbol? id))
      (assertion-violation
        'setting-service-source "invalid ConfigurationSource lookup" service id))
    (let ([entry (hashtable-ref (setting-service-sources service) id #f)])
      (if entry
          (source-entry-source entry)
          (if (null? default) #f (car default)))))

  (define (source-applies? source context)
    (case (configuration-source-layer source)
      [(application user) #t]
      [(workspace)
       (equal? (configuration-source-target source)
               (configuration-context-workspace context))]
      [(file-local)
       (let ([resource (configuration-context-resource context)])
         (and resource
              (resource=? (configuration-source-target source) resource)))]))

  (define (layer-rank layer)
    (case layer
      [(application) 0]
      [(user) 1]
      [(workspace) 2]
      [(file-local) 3]))

  (define (entry-before? left right)
    (let ([left-rank
           (layer-rank
             (configuration-source-layer (source-entry-source left)))]
          [right-rank
           (layer-rank
             (configuration-source-layer (source-entry-source right)))])
      (or (< left-rank right-rank)
          (and (= left-rank right-rank)
               (< (source-entry-order left) (source-entry-order right))))))

  (define (applicable-entries service context)
    (call-with-values
      (lambda () (hashtable-entries (setting-service-sources service)))
      (lambda (ids entries)
        (list-sort
          entry-before?
          (filter
            (lambda (entry) (source-applies? (source-entry-source entry) context))
            (vector->list entries))))))

  (define (setting-service-resolve service name scope context)
    (unless (and (setting-service? service) (symbol? name)
                 (memq scope '(application workspace buffer view))
                 (configuration-context? context))
      (assertion-violation
        'setting-service-resolve "invalid setting resolution"
        service name scope context))
    (let ([schema (setting-service-ref service name #f)])
      (unless schema
        (assertion-violation 'setting-service-resolve "unknown setting" name))
      (unless (memq scope (setting-schema-scopes schema))
        (assertion-violation
          'setting-service-resolve "setting does not support scope" name scope))
      (let loop ([entries (applicable-entries service context)]
                 [winner #f] [source-id #f] [layer #f])
        (if (null? entries)
            (make-resolved-setting
              (or winner (make-default-setting-value schema scope))
              source-id layer)
            (let* ([entry (car entries)]
                   [source (source-entry-source entry)]
                   [candidate
                    (find
                      (lambda (value)
                        (and (eq? (setting-value-name value) name)
                             (eq? (setting-value-scope value) scope)
                             (eq? (setting-value-schema value) schema)))
                      (source-entry-values entry))])
              (loop
                (cdr entries)
                (or candidate winner)
                (if candidate (configuration-source-id source) source-id)
                (if candidate (configuration-source-layer source) layer)))))))

  (define (symbol-before? left right)
    (string<? (symbol->string left) (symbol->string right)))

  (define (setting-service-resolved-settings service scope context)
    (map
      (lambda (schema)
        (setting-service-resolve
          service (setting-schema-name schema) scope context))
      (list-sort
        (lambda (left right)
          (symbol-before?
            (setting-schema-name left) (setting-schema-name right)))
        (filter
          (lambda (schema) (memq scope (setting-schema-scopes schema)))
          (setting-service-schemas service)))))

  (define (setting-service-extensions service scope context)
    (map
      (lambda (resolved)
        (setting-value-extension (resolved-setting-value resolved)))
      (setting-service-resolved-settings service scope context)))
)
