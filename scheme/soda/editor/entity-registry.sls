(library (soda editor entity-registry)
  (export make-entity-registry
          entity-registry-ids
          entity-registry-values
          entity-registry-ref
          entity-registry-contains?
          entity-registry-next-id
          entity-registry-register!
          entity-registry-remove!)
  (import (rnrs)
          (soda editor contract))

  (define-record-type
    (entity-registry %make-entity-registry entity-registry?)
    (fields
      (immutable table entity-registry-table)
      (mutable ids entity-registry-ids entity-registry-ids-set!)
      (mutable next-id
               entity-registry-next-id
               entity-registry-next-id-set!)))

  (define (make-entity-registry next-id)
    (unless (exact-non-negative-integer? next-id)
      (assertion-violation
        'make-entity-registry
        "next id must be a non-negative exact integer"
        next-id))
    (%make-entity-registry (make-eqv-hashtable) '() next-id))

  (define (entity-registry-values registry)
    (map
      (lambda (id)
        (hashtable-ref (entity-registry-table registry) id #f))
      (entity-registry-ids registry)))

  (define (entity-registry-ref registry id)
    (hashtable-ref (entity-registry-table registry) id #f))

  (define (entity-registry-contains? registry id)
    (hashtable-contains? (entity-registry-table registry) id))

  (define (entity-registry-register! registry id value)
    (unless (exact-non-negative-integer? id)
      (assertion-violation
        'entity-registry-register!
        "id must be a non-negative exact integer"
        id))
    (when (entity-registry-contains? registry id)
      (assertion-violation
        'entity-registry-register!
        "id is already registered"
        id))
    (hashtable-set! (entity-registry-table registry) id value)
    (entity-registry-ids-set!
      registry
      (append (entity-registry-ids registry) (list id)))
    (when (>= id (entity-registry-next-id registry))
      (entity-registry-next-id-set! registry (+ id 1)))
    value)

  (define (entity-registry-remove! registry id)
    (let ([value (entity-registry-ref registry id)])
      (when value
        (hashtable-delete! (entity-registry-table registry) id)
        (entity-registry-ids-set!
          registry
          (remv id (entity-registry-ids registry))))
      value)))
