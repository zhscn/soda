(library (soda editor hook)
  (export make-hook-registry
          hook-registry?
          hook-registry-add!
          hook-registry-remove!
          hook-registry-names
          hook-registry-procedures
          hook-registry-run!
          hook-registry-snapshot
          hook-registry-restore!)
  (import (rnrs))

  (define-record-type (hook-registry %make-hook-registry hook-registry?)
    (fields entries))

  (define-record-type
    (hook-registry-state %make-hook-registry-state hook-registry-state?)
    (fields entries))

  (define (make-hook-registry)
    (%make-hook-registry (make-eq-hashtable)))

  (define (require-registry who registry)
    (unless (hook-registry? registry)
      (assertion-violation who "expected a hook registry" registry)))

  (define (require-phase who phase)
    (unless (symbol? phase)
      (assertion-violation who "hook phase must be a symbol" phase)))

  (define (hook-registry-add! registry phase name procedure)
    (require-registry 'hook-registry-add! registry)
    (require-phase 'hook-registry-add! phase)
    (unless (symbol? name)
      (assertion-violation
        'hook-registry-add!
        "hook name must be a symbol"
        name))
    (unless (procedure? procedure)
      (assertion-violation
        'hook-registry-add!
        "hook must be a procedure"
        procedure))
    (let ([hooks
            (hashtable-ref
              (hook-registry-entries registry)
              phase
              '())])
      (hashtable-set!
        (hook-registry-entries registry)
        phase
        (append
          (filter
            (lambda (entry) (not (eq? (car entry) name)))
            hooks)
          (list (cons name procedure)))))
    name)

  (define (hook-registry-remove! registry phase name)
    (require-registry 'hook-registry-remove! registry)
    (require-phase 'hook-registry-remove! phase)
    (unless (symbol? name)
      (assertion-violation
        'hook-registry-remove!
        "hook name must be a symbol"
        name))
    (let ([hooks
            (hashtable-ref
              (hook-registry-entries registry)
              phase
              '())])
      (hashtable-set!
        (hook-registry-entries registry)
        phase
        (filter
          (lambda (entry) (not (eq? (car entry) name)))
          hooks)))
    name)

  (define (hook-registry-names registry phase)
    (require-registry 'hook-registry-names registry)
    (require-phase 'hook-registry-names phase)
    (map
      car
      (hashtable-ref
        (hook-registry-entries registry)
        phase
        '())))

  (define (hook-registry-procedures registry phase)
    (require-registry 'hook-registry-procedures registry)
    (require-phase 'hook-registry-procedures phase)
    (map
      cdr
      (hashtable-ref
        (hook-registry-entries registry)
        phase
        '())))

  (define (hook-registry-run! registry phase . arguments)
    (for-each
      (lambda (procedure) (apply procedure arguments))
      (hook-registry-procedures registry phase)))

  (define (hook-registry-snapshot registry)
    (require-registry 'hook-registry-snapshot registry)
    (%make-hook-registry-state
      (hashtable-copy (hook-registry-entries registry) #t)))

  (define (hook-registry-restore! registry snapshot)
    (require-registry 'hook-registry-restore! registry)
    (unless (hook-registry-state? snapshot)
      (assertion-violation
        'hook-registry-restore!
        "expected a hook registry snapshot"
        snapshot))
    (hashtable-clear! (hook-registry-entries registry))
    (let-values
      ([(phases hooks)
        (hashtable-entries (hook-registry-state-entries snapshot))])
      (let loop ([index 0])
        (unless (= index (vector-length phases))
          (hashtable-set!
            (hook-registry-entries registry)
            (vector-ref phases index)
            (vector-ref hooks index))
          (loop (+ index 1)))))
    registry))
