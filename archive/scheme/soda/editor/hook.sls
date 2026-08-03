(library (soda editor hook)
  (export make-hook-registry
          hook-registry?
          hook-registry-add!
          hook-registry-remove!
          hook-registry-names
          hook-registry-procedures
          hook-registry-run!
          hook-registry-add-buffer!
          hook-registry-remove-buffer!
          hook-registry-buffer-names
          hook-registry-buffer-procedures
          hook-registry-run-for-buffer!
          hook-registry-clear-buffer!
          hook-registry-snapshot
          hook-registry-restore!)
  (import (rnrs)
          (soda editor hashtable-state))

  (define-record-type (hook-registry %make-hook-registry hook-registry?)
    (fields entries buffer-entries))

  (define-record-type
    (hook-registry-state %make-hook-registry-state hook-registry-state?)
    (fields entries buffer-entries))

  (define (make-hook-registry)
    (%make-hook-registry
      (make-eq-hashtable)
      (make-hashtable equal-hash equal?)))

  (define (require-registry who registry)
    (unless (hook-registry? registry)
      (assertion-violation who "expected a hook registry" registry)))

  (define (require-phase who phase)
    (unless (symbol? phase)
      (assertion-violation who "hook phase must be a symbol" phase)))

  (define (require-buffer-id who buffer-id)
    (unless
      (and
        (integer? buffer-id)
        (exact? buffer-id)
        (not (negative? buffer-id)))
      (assertion-violation
        who
        "buffer id must be a non-negative exact integer"
        buffer-id)))

  (define (require-hook-name who name)
    (unless (symbol? name)
      (assertion-violation who "hook name must be a symbol" name)))

  (define (replace-named-hook hooks name procedure)
    (append
      (filter
        (lambda (entry) (not (eq? (car entry) name)))
        hooks)
      (list (cons name procedure))))

  (define (buffer-hook-key buffer-id phase)
    (cons buffer-id phase))

  (define (hook-registry-add! registry phase name procedure)
    (require-registry 'hook-registry-add! registry)
    (require-phase 'hook-registry-add! phase)
    (require-hook-name 'hook-registry-add! name)
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
        (replace-named-hook hooks name procedure)))
    name)

  (define (hook-registry-remove! registry phase name)
    (require-registry 'hook-registry-remove! registry)
    (require-phase 'hook-registry-remove! phase)
    (require-hook-name 'hook-registry-remove! name)
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

  (define (hook-registry-add-buffer!
            registry
            buffer-id
            phase
            name
            procedure)
    (require-registry 'hook-registry-add-buffer! registry)
    (require-buffer-id 'hook-registry-add-buffer! buffer-id)
    (require-phase 'hook-registry-add-buffer! phase)
    (require-hook-name 'hook-registry-add-buffer! name)
    (unless (procedure? procedure)
      (assertion-violation
        'hook-registry-add-buffer!
        "hook must be a procedure"
        procedure))
    (let* ([key (buffer-hook-key buffer-id phase)]
           [hooks
             (hashtable-ref
               (hook-registry-buffer-entries registry)
               key
               '())])
      (hashtable-set!
        (hook-registry-buffer-entries registry)
        key
        (replace-named-hook hooks name procedure)))
    name)

  (define (hook-registry-remove-buffer!
            registry
            buffer-id
            phase
            name)
    (require-registry 'hook-registry-remove-buffer! registry)
    (require-buffer-id 'hook-registry-remove-buffer! buffer-id)
    (require-phase 'hook-registry-remove-buffer! phase)
    (require-hook-name 'hook-registry-remove-buffer! name)
    (let* ([key (buffer-hook-key buffer-id phase)]
           [hooks
             (filter
               (lambda (entry) (not (eq? (car entry) name)))
               (hashtable-ref
                 (hook-registry-buffer-entries registry)
                 key
                 '()))])
      (if (null? hooks)
          (hashtable-delete!
            (hook-registry-buffer-entries registry)
            key)
          (hashtable-set!
            (hook-registry-buffer-entries registry)
            key
            hooks)))
    name)

  (define (hook-registry-buffer-procedures
            registry
            buffer-id
            phase)
    (require-registry 'hook-registry-buffer-procedures registry)
    (require-buffer-id 'hook-registry-buffer-procedures buffer-id)
    (require-phase 'hook-registry-buffer-procedures phase)
    (map
      cdr
      (hashtable-ref
        (hook-registry-buffer-entries registry)
        (buffer-hook-key buffer-id phase)
        '())))

  (define (hook-registry-buffer-names registry buffer-id phase)
    (require-registry 'hook-registry-buffer-names registry)
    (require-buffer-id 'hook-registry-buffer-names buffer-id)
    (require-phase 'hook-registry-buffer-names phase)
    (map
      car
      (hashtable-ref
        (hook-registry-buffer-entries registry)
        (buffer-hook-key buffer-id phase)
        '())))

  (define (hook-registry-run-for-buffer!
            registry
            buffer-id
            phase
            . arguments)
    (for-each
      (lambda (procedure) (apply procedure arguments))
      (append
        (hook-registry-procedures registry phase)
        (hook-registry-buffer-procedures
          registry
          buffer-id
          phase))))

  (define (hook-registry-clear-buffer! registry buffer-id)
    (require-registry 'hook-registry-clear-buffer! registry)
    (require-buffer-id 'hook-registry-clear-buffer! buffer-id)
    (let-values
      ([(keys hooks)
        (hashtable-entries
          (hook-registry-buffer-entries registry))])
      (let loop ([index 0])
        (unless (= index (vector-length keys))
          (let ([key (vector-ref keys index)])
            (when (= (car key) buffer-id)
              (hashtable-delete!
                (hook-registry-buffer-entries registry)
                key)))
          (loop (+ index 1)))))
    registry)

  (define (hook-registry-snapshot registry)
    (require-registry 'hook-registry-snapshot registry)
    (%make-hook-registry-state
      (hashtable-copy (hook-registry-entries registry) #t)
      (hashtable-copy (hook-registry-buffer-entries registry) #t)))

  (define (hook-registry-restore! registry snapshot)
    (require-registry 'hook-registry-restore! registry)
    (unless (hook-registry-state? snapshot)
      (assertion-violation
        'hook-registry-restore!
        "expected a hook registry snapshot"
        snapshot))
    (replace-hashtable!
      (hook-registry-entries registry)
      (hook-registry-state-entries snapshot))
    (replace-hashtable!
      (hook-registry-buffer-entries registry)
      (hook-registry-state-buffer-entries snapshot))
    registry))
