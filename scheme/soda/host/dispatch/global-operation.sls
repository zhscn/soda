(library (soda host dispatch global-operation)
  (export make-global-operation-registry
          global-operation-registry?
          global-operation-register!
          global-operation-dispatch)
  (import (rnrs)
          (soda host internal operation)
          (soda host value))

  (define-record-type
    (global-operation-registry %make-global-operation-registry
                               global-operation-registry?)
    (fields (immutable handlers global-operation-registry-handlers)))

  (define-record-type
    (global-operation-handler %make-global-operation-handler
                              global-operation-handler?)
    (fields owner damage procedure))

  (define (make-global-operation-registry)
    (%make-global-operation-registry (make-eq-hashtable)))

  (define (global-operation-register! registry owner kind damage procedure)
    (unless (and (global-operation-registry? registry) (owner? owner)
                 (symbol? kind) (list? damage)
                 (for-all symbol? damage) (procedure? procedure))
      (assertion-violation
        'global-operation-register! "invalid global HostOperation handler"
        registry owner kind damage procedure))
    (owner-assert-active 'global-operation-register! owner)
    (let ([table (global-operation-registry-handlers registry)])
      (when (hashtable-ref table kind #f)
        (assertion-violation
          'global-operation-register!
          "global HostOperation handler is already registered" kind))
      (let ([entry
             (%make-global-operation-handler owner (list-copy damage) procedure)])
        (hashtable-set! table kind entry)
        (make-registration
          owner
          (lambda ()
            (when (eq? (hashtable-ref table kind #f) entry)
              (hashtable-delete! table kind)))))))

  (define (global-operation-dispatch registry operation)
    (unless (and (global-operation-registry? registry)
                 (host-operation? operation)
                 (not (host-operation-surface-id operation)))
      (assertion-violation
        'global-operation-dispatch "invalid global HostOperation"
        registry operation))
    (let ([entry
           (hashtable-ref
             (global-operation-registry-handlers registry)
             (host-operation-kind operation) #f)])
      (unless entry
        (assertion-violation
          'global-operation-dispatch "unsupported global HostOperation" operation))
      (let ([resolution
             ((global-operation-handler-procedure entry)
              (host-operation-value operation))])
        (and resolution
             (make-host-update
               operation #f #f #f resolution
               (global-operation-handler-damage entry))))))
)
