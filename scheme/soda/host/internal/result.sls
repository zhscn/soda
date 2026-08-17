(library (soda host internal result)
  (export make-result-service
          result-service?
          result-service-register!
          result-service-publish!
          result-service-ref
          result-service-sources)
  (import (rnrs)
          (soda kernel result)
          (soda host value))

  ;; The registry owns publication order and lifetime only.  ResultSource is
  ;; immutable kernel data, so consumers never receive a mutable package
  ;; model or a presentation-specific result buffer.
  (define-record-type result-entry
    (fields owner
            (mutable source result-entry-source result-entry-source-set!)))

  (define-record-type
    (result-service %make-result-service result-service?)
    (fields (immutable entries result-service-entries)
            (mutable order result-service-order result-service-order-set!)))

  (define (make-result-service)
    (%make-result-service (make-eq-hashtable) '()))

  (define (entry-ref service id)
    (hashtable-ref (result-service-entries service) id #f))

  (define (result-service-register! service owner source)
    (unless (and (result-service? service) (owner? owner) (result-source? source))
      (assertion-violation 'result-service-register!
                           "expected a ResultService, Owner, and ResultSource"
                           service owner source))
    (owner-assert-active 'result-service-register! owner)
    (let* ([id (result-source-id source)]
           [existing (entry-ref service id)])
      (when existing
        (assertion-violation 'result-service-register!
                             "ResultSource id is already registered" id))
      (let ([entry (make-result-entry owner source)])
        (hashtable-set! (result-service-entries service) id entry)
        (result-service-order-set!
          service (append (result-service-order service) (list id)))
        (owner-add-cleanup!
          owner
          (lambda ()
            (when (eq? (entry-ref service id) entry)
              (hashtable-delete! (result-service-entries service) id)
              (result-service-order-set!
                service
                (filter (lambda (candidate) (not (eq? candidate id)))
                        (result-service-order service))))))
        source)))

  (define (result-service-publish! service owner source)
    (unless (and (result-service? service) (owner? owner) (result-source? source))
      (assertion-violation 'result-service-publish!
                           "expected a ResultService, Owner, and ResultSource"
                           service owner source))
    (owner-assert-active 'result-service-publish! owner)
    (let* ([id (result-source-id source)]
           [entry (entry-ref service id)])
      (unless (and entry (eq? owner (result-entry-owner entry)))
        (assertion-violation 'result-service-publish!
                             "Owner does not own ResultSource" id))
      (unless (> (result-source-revision source)
                 (result-source-revision (result-entry-source entry)))
        (assertion-violation 'result-service-publish!
                             "ResultSource revision must advance" id))
      (result-entry-source-set! entry source)
      source))

  (define result-service-ref
    (case-lambda
      [(service id) (result-service-ref service id #f)]
      [(service id default)
       (unless (and (result-service? service) (symbol? id))
         (assertion-violation 'result-service-ref
                              "expected a ResultService and ResultSource id"
                              service id))
       (let ([entry (entry-ref service id)])
         (if entry (result-entry-source entry) default))]))

  (define (result-service-sources service)
    (unless (result-service? service)
      (assertion-violation 'result-service-sources "expected a ResultService" service))
    (let loop ([ids (result-service-order service)] [sources '()])
      (if (null? ids)
          (reverse sources)
          (let ([entry (entry-ref service (car ids))])
            (loop (cdr ids)
                  (if entry (cons (result-entry-source entry) sources) sources))))))
)
