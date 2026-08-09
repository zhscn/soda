(library (soda host internal setting)
  (export make-setting-service
          setting-service?
          setting-service-register!
          setting-service-ref
          setting-service-schemas
          setting-service-parse)
  (import (rnrs)
          (soda host setting)
          (soda host value))

  (define-record-type schema-entry
    (fields owner schema))

  (define-record-type
    (setting-service %make-setting-service setting-service?)
    (fields table))

  (define (make-setting-service)
    (%make-setting-service (make-eq-hashtable)))

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
)
