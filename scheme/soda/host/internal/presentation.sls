(library (soda host internal presentation)
  (export make-buffer-presentation-service
          buffer-presentation-service?
          buffer-presentation-service-generation
          buffer-presentation-service-ref
          buffer-presentation-service-set!
          buffer-presentation-service-register-projector!
          buffer-presentation-service-refresh!
          buffer-presentation-service-discard!)
  (import (rnrs)
          (soda host value))

  (define-record-type presentation-projector
    (fields key procedure))

  ;; Presentation attributes are semantic chrome inputs published by the
  ;; subsystem that owns their truth.  They are separate from BufferState so
  ;; saving a file does not manufacture an editor transaction, and separate
  ;; from rendering so a Frame never queries package-owned mutable services.
  (define-record-type
    (buffer-presentation-service %make-buffer-presentation-service
                                 buffer-presentation-service?)
    (fields table
            (mutable projectors buffer-presentation-service-projectors
                     buffer-presentation-service-projectors-set!)
            (mutable generation buffer-presentation-service-generation
                     buffer-presentation-service-generation-set!)))

  (define (make-buffer-presentation-service)
    (%make-buffer-presentation-service (make-eqv-hashtable) '() 0))

  (define (buffer-id? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (buffer-presentation-service-ref service buffer-id key default)
    (unless (and (buffer-presentation-service? service)
                 (buffer-id? buffer-id) (symbol? key))
      (assertion-violation 'buffer-presentation-service-ref
                           "invalid presentation lookup" service buffer-id key))
    (let* ([attributes
            (hashtable-ref (buffer-presentation-service-table service)
                           buffer-id '())]
           [entry (assq key attributes)])
      (if entry (cdr entry) default)))

  (define (buffer-presentation-service-set! service buffer-id key value)
    (unless (and (buffer-presentation-service? service)
                 (buffer-id? buffer-id) (symbol? key))
      (assertion-violation 'buffer-presentation-service-set!
                           "invalid presentation update" service buffer-id key))
    (let* ([table (buffer-presentation-service-table service)]
           [attributes (hashtable-ref table buffer-id '())]
           [entry (assq key attributes)])
      (if (and entry (equal? (cdr entry) value))
          #f
          (begin
            (hashtable-set!
              table buffer-id
              (cons (cons key value)
                    (filter (lambda (item) (not (eq? (car item) key)))
                            attributes)))
            (buffer-presentation-service-generation-set!
              service (+ 1 (buffer-presentation-service-generation service)))
            #t))))

  (define (buffer-presentation-service-register-projector!
            service owner key procedure)
    (unless (and (buffer-presentation-service? service) (owner? owner)
                 (symbol? key) (procedure? procedure))
      (assertion-violation 'buffer-presentation-service-register-projector!
                           "invalid presentation projector"
                           service owner key procedure))
    (owner-assert-active 'buffer-presentation-service-register-projector! owner)
    (when (exists
            (lambda (projector)
              (eq? (presentation-projector-key projector) key))
            (buffer-presentation-service-projectors service))
      (assertion-violation 'buffer-presentation-service-register-projector!
                           "presentation attribute already has a projector" key))
    (let ([projector (make-presentation-projector key procedure)])
      (buffer-presentation-service-projectors-set!
        service
        (append (buffer-presentation-service-projectors service)
                (list projector)))
      (make-registration
        owner
        (lambda ()
          (buffer-presentation-service-projectors-set!
            service
            (filter
              (lambda (candidate) (not (eq? candidate projector)))
              (buffer-presentation-service-projectors service)))
          (let ([changed? #f]
                [table (buffer-presentation-service-table service)])
            (call-with-values
              (lambda () (hashtable-entries table))
              (lambda (ids values)
                (let loop ([index 0])
                  (when (< index (vector-length ids))
                    (let* ([buffer-id (vector-ref ids index)]
                           [attributes (vector-ref values index)]
                           [retained
                            (filter
                              (lambda (item) (not (eq? (car item) key)))
                              attributes)])
                      (unless (= (length retained) (length attributes))
                        (set! changed? #t)
                        (if (null? retained)
                            (hashtable-delete! table buffer-id)
                            (hashtable-set! table buffer-id retained)))
                      (loop (+ index 1)))))))
            (when changed?
              (buffer-presentation-service-generation-set!
                service
                (+ 1 (buffer-presentation-service-generation service)))))))))

  (define (buffer-presentation-service-refresh! service buffer-id buffer)
    (unless (and (buffer-presentation-service? service) (buffer-id? buffer-id))
      (assertion-violation 'buffer-presentation-service-refresh!
                           "invalid presentation refresh" service buffer-id))
    (for-each
      (lambda (projector)
        (buffer-presentation-service-set!
          service buffer-id
          (presentation-projector-key projector)
          ((presentation-projector-procedure projector) buffer)))
      (buffer-presentation-service-projectors service))
    #t)

  (define (buffer-presentation-service-discard! service buffer-id)
    (unless (and (buffer-presentation-service? service)
                 (buffer-id? buffer-id))
      (assertion-violation 'buffer-presentation-service-discard!
                           "invalid presentation discard" service buffer-id))
    (if (hashtable-contains? (buffer-presentation-service-table service) buffer-id)
        (begin
          (hashtable-delete! (buffer-presentation-service-table service) buffer-id)
          (buffer-presentation-service-generation-set!
            service (+ 1 (buffer-presentation-service-generation service)))
          #t)
        #f))
)
