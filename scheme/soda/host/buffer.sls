(library (soda host buffer)
  (export make-buffer
          buffer?
          buffer-id
          buffer-owner
          buffer-name
          buffer-state
          buffer-document
          buffer-generation
          buffer-set-state!
          buffer-close!
          make-buffer-service
          buffer-service?
          buffer-service-create!
          buffer-service-ref
          buffer-service-buffers
          buffer-service-close-buffer!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel state)
          (soda kernel value)
          (soda host value))

  (define-record-type
    (buffer %make-buffer buffer?)
    (fields
      (immutable id buffer-id)
      (immutable owner buffer-owner)
      (immutable name buffer-name)
      (immutable document buffer-document)
      (mutable state buffer-state buffer-state-set!)
      (mutable generation buffer-generation buffer-generation-set!)
      (mutable closed? buffer-closed? buffer-closed?-set!)))

  (define (make-buffer owner name document configuration)
    (owner-assert-active 'make-buffer owner)
    (unless (string? name)
      (assertion-violation 'make-buffer "name must be a string" name))
    (unless (document? document)
      (assertion-violation 'make-buffer "expected a document" document))
    (let ([buffer
            (%make-buffer
              (identity-source-next! buffer-identities)
              owner name document
              (make-buffer-state (document-snapshot document) configuration)
              0 #f)])
      (owner-add-cleanup! owner (lambda () (buffer-close! buffer)))
      buffer))

  (define buffer-identities (make-identity-source))

  (define (buffer-set-state! buffer state)
    (unless (and (buffer? buffer) (not (buffer-closed? buffer)))
      (assertion-violation 'buffer-set-state! "buffer is closed" buffer))
    (unless (buffer-state? state)
      (assertion-violation 'buffer-set-state! "expected a buffer state" state))
    (buffer-state-set! buffer state)
    (buffer-generation-set! buffer (+ 1 (buffer-generation buffer)))
    state)

  (define (buffer-close! buffer)
    (unless (buffer? buffer)
      (assertion-violation 'buffer-close! "expected a buffer" buffer))
    (if (buffer-closed? buffer)
        #f
        (begin
          (snapshot-close! (buffer-state-document (buffer-state buffer)))
          (document-close! (buffer-document buffer))
          (buffer-closed?-set! buffer #t)
          #t)))

  (define-record-type
    (buffer-service %make-buffer-service buffer-service?)
    (fields (immutable identities buffer-service-identities)
            (immutable table buffer-service-table)))

  (define (make-buffer-service)
    (%make-buffer-service (make-identity-source) (make-eqv-hashtable)))

  (define (buffer-service-create! service owner name document configuration)
    (unless (buffer-service? service)
      (assertion-violation 'buffer-service-create! "expected a buffer service" service))
    (let ([buffer
            (let ([buffer-identities (buffer-service-identities service)])
              (owner-assert-active 'buffer-service-create! owner)
              (%make-buffer
                (identity-source-next! buffer-identities)
                owner name document
                (make-buffer-state (document-snapshot document) configuration)
                0 #f))])
      (hashtable-set! (buffer-service-table service) (buffer-id buffer) buffer)
      (owner-add-cleanup! owner (lambda () (buffer-close! buffer)))
      buffer))

  (define (buffer-service-ref service id . default)
    (let ([buffer (hashtable-ref (buffer-service-table service) id #f)])
      (if (and buffer (not (buffer-closed? buffer)))
          buffer
          (if (null? default) #f (car default)))))

  (define (buffer-service-buffers service)
    (call-with-values
      (lambda () (hashtable-entries (buffer-service-table service)))
      (lambda (ids values)
        (filter (lambda (buffer) (not (buffer-closed? buffer)))
                (vector->list values)))))

  (define (buffer-service-close-buffer! service id)
    (let ([buffer (buffer-service-ref service id #f)])
      (and buffer (buffer-close! buffer))))
)
