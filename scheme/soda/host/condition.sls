(library (soda host condition)
  (export make-condition-service
          condition-service?
          condition-service-capture
          condition-service-dismiss!
          condition-service-resume!)
  (import (rnrs)
          (soda host value))

  (define (find-entry predicate items)
    (cond
      [(null? items) #f]
      [(predicate (car items)) (car items)]
      [else (find-entry predicate (cdr items))]))

  (define-record-type
    (condition-service %make-condition-service condition-service?)
    (fields (mutable entries condition-service-entries condition-service-entries-set!)))

  (define (make-condition-service)
    (%make-condition-service '()))

  (define (condition-service-capture service owner condition continuation restarts)
    (owner-assert-active 'condition-service-capture owner)
    (let ([entry (vector condition continuation restarts 'pending)])
      (condition-service-entries-set!
        service
        (cons (cons (length (condition-service-entries service)) entry)
              (condition-service-entries service)))
      entry))

  (define (condition-service-entry service entry)
    (find-entry (lambda (item) (eq? (cdr item) entry))
                (condition-service-entries service)))

  (define (condition-service-dismiss! service entry)
    (let ([item (condition-service-entry service entry)])
      (if (and item (eq? (vector-ref (cdr item) 3) 'pending))
          (begin (vector-set! (cdr item) 3 'dismissed) #t)
          #f)))

  (define (condition-service-resume! service entry action . arguments)
    (let ([item (condition-service-entry service entry)])
      (if (and item (eq? (vector-ref (cdr item) 3) 'pending))
          (begin
            (vector-set! (cdr item) 3 'resumed)
            (apply action (vector-ref (cdr item) 1) arguments))
          #f)))
)
