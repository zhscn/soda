(library (soda core condition)
  (export make-condition-service
          condition-service?
          captured-condition?
          captured-condition-owner
          captured-condition-origin
          captured-condition-value
          captured-condition-continuation
          captured-condition-source-context
          condition-service-capture!
          condition-service-conditions
          condition-service-dismiss!
          call-with-condition-boundary)
  (import (rnrs)
          (soda core value))

  (define-record-type
    (captured-condition %make-captured-condition captured-condition?)
    (fields
      owner origin value continuation source-context
      (mutable registration captured-condition-registration
               captured-condition-registration-set!)))

  (define-record-type
    (condition-service %make-condition-service condition-service?)
    (fields
      (mutable conditions condition-service-conditions*
               condition-service-conditions-set!)))

  (define (make-condition-service)
    (%make-condition-service '()))

  (define (condition-service-capture!
            service owner origin value continuation source-context)
    (unless (condition-service? service)
      (assertion-violation
        'condition-service-capture! "expected a condition service" service))
    (unless (or (not owner) (owner? owner))
      (assertion-violation
        'condition-service-capture! "owner must be an owner or #f" owner))
    (let ([captured
            (%make-captured-condition
              owner origin value continuation source-context #f)])
      (condition-service-conditions-set!
        service
        (cons captured (condition-service-conditions* service)))
      (when owner
        (captured-condition-registration-set!
          captured
          (make-registration
            owner
            (lambda ()
              (condition-service-remove! service captured)))))
      captured))

  (define (condition-service-remove! service captured)
    (let ([before (condition-service-conditions* service)])
      (condition-service-conditions-set!
        service
        (filter (lambda (candidate) (not (eq? candidate captured))) before))
      (not (= (length before)
              (length (condition-service-conditions* service))))))

  (define (condition-service-conditions service)
    (unless (condition-service? service)
      (assertion-violation
        'condition-service-conditions "expected a condition service" service))
    (reverse (condition-service-conditions* service)))

  (define (condition-service-dismiss! service captured)
    (unless (condition-service? service)
      (assertion-violation
        'condition-service-dismiss! "expected a condition service" service))
    (unless (captured-condition? captured)
      (assertion-violation
        'condition-service-dismiss! "expected a captured condition" captured))
    (let ([registration (captured-condition-registration captured)])
      (if (and registration (registration-active? registration))
          (registration-close! registration)
          (condition-service-remove! service captured))))

  (define (call-with-condition-boundary
            service owner origin source-context procedure)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-condition-boundary "expected a procedure" procedure))
    (guard
      (condition
        [else
         (condition-service-capture!
           service owner origin condition #f source-context)])
      (procedure)))
)
