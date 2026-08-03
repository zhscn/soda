(library (soda host package)
  (export make-package-manifest
          package-manifest?
          package-manifest-name
          package-manifest-owner
          package-manifest-capabilities
          package-manifest-activate
          package-manifest-deactivate
          package-manifest-active?
          make-package-service
          package-service?
          package-service-activate!
          package-service-deactivate!
          package-service-manifests
          package-service-close!)
  (import (rnrs)
          (soda host value))

  (define (copy-list value)
    (if (null? value) '() (cons (car value) (copy-list (cdr value)))))

  (define-record-type
    (package-manifest %make-package-manifest package-manifest?)
    (fields
      (immutable name package-manifest-name)
      (immutable owner package-manifest-owner)
      (immutable capabilities package-manifest-capabilities)
      (immutable activate package-manifest-activate)
      (immutable deactivate package-manifest-deactivate)
      (mutable active? package-manifest-active? package-manifest-active?-set!)))

  (define (make-package-manifest name owner capabilities activate . deactivate)
    (unless (and (symbol? name) (owner? owner) (list? capabilities)
                 (procedure? activate))
      (assertion-violation 'make-package-manifest "invalid package manifest" name))
    (%make-package-manifest
      name owner (copy-list capabilities) activate
      (if (null? deactivate) (lambda arguments #t) (car deactivate))
      #f))

  (define-record-type
    (package-service %make-package-service package-service?)
    (fields (immutable table package-service-table)))

  (define (make-package-service)
    (%make-package-service (make-eq-hashtable)))

  (define (package-service-activate! service manifest)
    (unless (and (package-service? service) (package-manifest? manifest))
      (assertion-violation 'package-service-activate! "invalid package activation" manifest))
    (let ([name (package-manifest-name manifest)])
      (when (hashtable-contains? (package-service-table service) name)
        (assertion-violation 'package-service-activate! "package is already active" name))
      (guard
        (condition
          [else
           (guard (condition [else #f]) (owner-close! (package-manifest-owner manifest)))
           (raise condition)])
        ((package-manifest-activate manifest) manifest)
        (package-manifest-active?-set! manifest #t)
        (hashtable-set! (package-service-table service) name manifest)
        manifest)))

  (define (package-service-deactivate! service name)
    (unless (package-service? service)
      (assertion-violation 'package-service-deactivate! "expected a package service" service))
    (let ([manifest (hashtable-ref (package-service-table service) name #f)])
      (if (not manifest)
          #f
          (begin
            ((package-manifest-deactivate manifest) manifest)
            (package-manifest-active?-set! manifest #f)
            (hashtable-delete! (package-service-table service) name)
            (owner-close! (package-manifest-owner manifest))
            #t))))

  (define (package-service-manifests service)
    (call-with-values
      (lambda () (hashtable-entries (package-service-table service)))
      (lambda (keys values) (vector->list values))))

  (define (package-service-close! service)
    (for-each
      (lambda (manifest)
        (package-service-deactivate! service (package-manifest-name manifest)))
      (package-service-manifests service))
    #t)
)
