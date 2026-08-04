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
          buffer-service-set-close-handler!
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
      (mutable snapshot-count buffer-snapshot-count buffer-snapshot-count-set!)
      (mutable snapshot-sweep-at buffer-snapshot-sweep-at buffer-snapshot-sweep-at-set!)
      (mutable closed? buffer-closed? buffer-closed?-set!)))

  (define snapshot-sweep-minimum 64)

  (define (make-buffer-record identity-source owner name document configuration on-close)
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
              1
              snapshot-sweep-minimum
              #f)])
      (owner-add-cleanup! owner (lambda () (on-close buffer)))
      buffer))

  (define (buffer-publish-state! buffer state)
    (unless (and (buffer? buffer) (not (buffer-closed? buffer)))
      (assertion-violation 'buffer-publish-state! "buffer is closed" buffer))
    (unless (buffer-state? state)
      (assertion-violation 'buffer-publish-state! "expected a buffer state" state))
    (let* ([snapshot (buffer-state-document state)]
           [references
            (cons (weak-cons snapshot #f) (buffer-snapshots buffer))]
           [count (+ 1 (buffer-snapshot-count buffer))])
      (buffer-snapshots-set!
        buffer references)
      (buffer-snapshot-count-set! buffer count)
      (when (>= count (buffer-snapshot-sweep-at buffer))
        (let* ([live
                (filter
                  (lambda (reference) (not (bwp-object? (car reference))))
                  references)]
               [live-count (length live)])
          (buffer-snapshots-set! buffer live)
          (buffer-snapshot-count-set! buffer live-count)
          (buffer-snapshot-sweep-at-set!
            buffer
            (max snapshot-sweep-minimum (* 2 live-count))))))
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
          (buffer-snapshot-count-set! buffer 0)
          (document-close! (buffer-document buffer))
          (buffer-closed?-set! buffer #t)
          #t)))

  (define-record-type
    (buffer-service %make-buffer-service buffer-service?)
    (fields (immutable identities buffer-service-identities)
            (immutable table buffer-service-table)
            (mutable close! buffer-service-close-handler buffer-service-close-handler-set!)))

  (define (make-buffer-service)
    (%make-buffer-service (make-identity-source) (make-eqv-hashtable)
                          (lambda (buffer) #f)))

  (define (buffer-service-set-close-handler! service handler)
    (unless (and (buffer-service? service) (procedure? handler))
      (assertion-violation 'buffer-service-set-close-handler!
                           "expected a BufferService and close handler" service handler))
    (buffer-service-close-handler-set! service handler)
    handler)

  (define (buffer-service-create! service owner name document configuration)
    (unless (buffer-service? service)
      (assertion-violation 'buffer-service-create! "expected a buffer service" service))
    (let ([buffer (make-buffer-record
                    (buffer-service-identities service)
                    owner name document configuration
                    (lambda (buffer)
                      (buffer-service-close-buffer! service (buffer-id buffer))))])
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
      (and buffer
           (let ([closed?
                  (begin
                    ((buffer-service-close-handler service) buffer)
                    (buffer-close! buffer))])
             (when closed?
               (hashtable-delete! (buffer-service-table service) id))
             closed?))))
)
