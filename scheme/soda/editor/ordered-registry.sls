(library (soda editor ordered-registry)
  (export make-ordered-registry
          ordered-registry?
          ordered-registry-names
          ordered-registry-generation
          ordered-registry-ref
          ordered-registry-contains?
          ordered-registry-values
          ordered-registry-set!
          ordered-registry-remove!
          ordered-registry-snapshot
          ordered-registry-restore!)
  (import (rnrs)
          (soda editor hashtable-state))

  (define-record-type
    (ordered-registry %make-ordered-registry ordered-registry?)
    (fields table
            (mutable names)
            (mutable generation)))

  (define-record-type
    (ordered-registry-state %make-state ordered-registry-state?)
    (fields table names generation))

  (define (make-ordered-registry)
    (%make-ordered-registry (make-eq-hashtable) '() 0))

  (define (ordered-registry-ref registry name)
    (hashtable-ref (ordered-registry-table registry) name #f))

  (define (ordered-registry-contains? registry name)
    (hashtable-contains? (ordered-registry-table registry) name))

  (define (ordered-registry-values registry)
    (map
      (lambda (name) (ordered-registry-ref registry name))
      (ordered-registry-names registry)))

  (define (ordered-registry-set! registry name value)
    (unless (symbol? name)
      (assertion-violation
        'ordered-registry-set! "name must be a symbol" name))
    (unless (ordered-registry-contains? registry name)
      (ordered-registry-names-set!
        registry
        (append (ordered-registry-names registry) (list name))))
    (hashtable-set! (ordered-registry-table registry) name value)
    (ordered-registry-generation-set!
      registry (+ (ordered-registry-generation registry) 1))
    value)

  (define (ordered-registry-remove! registry name)
    (let ([value (ordered-registry-ref registry name)])
      (when value
        (hashtable-delete! (ordered-registry-table registry) name)
        (ordered-registry-names-set!
          registry (remq name (ordered-registry-names registry)))
        (ordered-registry-generation-set!
          registry (+ (ordered-registry-generation registry) 1)))
      value))

  (define (ordered-registry-snapshot registry)
    (%make-state
      (hashtable-copy (ordered-registry-table registry) #t)
      (ordered-registry-names registry)
      (ordered-registry-generation registry)))

  (define (ordered-registry-restore! registry state)
    (unless (ordered-registry-state? state)
      (assertion-violation
        'ordered-registry-restore! "invalid registry snapshot" state))
    (replace-hashtable!
      (ordered-registry-table registry)
      (ordered-registry-state-table state))
    (ordered-registry-names-set! registry (ordered-registry-state-names state))
    (ordered-registry-generation-set!
      registry (ordered-registry-state-generation state))
    registry))
