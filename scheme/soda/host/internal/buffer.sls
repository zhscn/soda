(library (soda host internal buffer)
  (export buffer?
          buffer-id
          buffer-owner
          buffer-name
          buffer-state
          buffer-document
          buffer-publish-state!
          buffer-close!
          make-buffer-service
          buffer-service?
          buffer-service-create!
          buffer-service-ref
          buffer-service-buffers
          buffer-service-close-buffer!)
  (import (rnrs)
          (only (chezscheme) weak-cons bwp-object?)
          (soda kernel document)
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
      (mutable snapshots buffer-snapshots buffer-snapshots-set!)
      (mutable closed? buffer-closed? buffer-closed?-set!)))

  (define (make-buffer-record identity-source owner name document configuration)
    (owner-assert-active 'buffer-service-create! owner)
    (unless (string? name)
      (assertion-violation 'buffer-service-create! "name must be a string" name))
    (unless (document? document)
      (assertion-violation 'buffer-service-create! "expected a document" document))
    (let* ([snapshot (document-snapshot document)]
           [buffer
            (%make-buffer
              (identity-source-next! identity-source)
              owner name document
              (make-buffer-state snapshot configuration)
              (list (weak-cons snapshot #f))
              #f)])
      (owner-add-cleanup! owner (lambda () (buffer-close! buffer)))
      buffer))

  (define (buffer-publish-state! buffer state)
    (unless (and (buffer? buffer) (not (buffer-closed? buffer)))
      (assertion-violation 'buffer-publish-state! "buffer is closed" buffer))
    (unless (buffer-state? state)
      (assertion-violation 'buffer-publish-state! "expected a buffer state" state))
    (let ([snapshot (buffer-state-document state)])
      (buffer-snapshots-set!
        buffer
        (cons
          (weak-cons snapshot #f)
          (filter
            (lambda (reference)
              (let ([value (car reference)])
                (and (not (bwp-object? value))
                     (not (eq? value snapshot)))))
            (buffer-snapshots buffer)))))
    (buffer-state-set! buffer state)
    state)

  (define (buffer-close! buffer)
    (unless (buffer? buffer)
      (assertion-violation 'buffer-close! "expected a buffer" buffer))
    (if (buffer-closed? buffer)
        #f
        (begin
          (snapshot-reap-unreachable!)
          (for-each
            (lambda (reference)
              (let ([snapshot (car reference)])
                (unless (bwp-object? snapshot)
                  (snapshot-close! snapshot))))
            (buffer-snapshots buffer))
          (buffer-snapshots-set! buffer '())
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
    (let ([buffer (make-buffer-record
                    (buffer-service-identities service)
                    owner name document configuration)])
      (hashtable-set! (buffer-service-table service) (buffer-id buffer) buffer)
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
