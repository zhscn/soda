(library (soda host internal buffer)
  (export buffer?
          buffer-id
          buffer-owner
          buffer-name
          buffer-lifecycle
          buffer-live?
          buffer-state
          buffer-document
          buffer-publish-state!
          buffer-close!
          make-buffer-key
          buffer-key?
          buffer-key-namespace
          buffer-key-identity
          make-buffer-service
          buffer-service?
          buffer-service-create!
          buffer-service-find-key
          buffer-service-open-or-create!
          buffer-service-bind-key!
          buffer-service-ref
          buffer-service-buffers
          buffer-service-set-close-query-handler!
          buffer-service-set-close-handler!
          buffer-service-add-close-listener!
          buffer-service-close-buffer!)
  (import (rnrs)
          (only (chezscheme) weak-cons bwp-object? equal-hash
                string->immutable-string bytevector->immutable-bytevector)
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
      (mutable lifecycle buffer-lifecycle buffer-lifecycle-set!)))

  ;; A key names a reusable Buffer independently of its presentation name.
  ;; The identity is an immutable-by-contract package value; the service uses
  ;; an internal structural token so callers cannot mutate its table entry.
  (define-record-type
    (buffer-key %make-buffer-key buffer-key?)
    (fields (immutable namespace buffer-key-namespace)
            (immutable identity buffer-key-identity)))

  (define (make-buffer-key namespace identity)
    (unless (symbol? namespace)
      (assertion-violation 'make-buffer-key "namespace must be a symbol" namespace))
    (%make-buffer-key
      namespace
      (cond [(string? identity) (string->immutable-string identity)]
            [(bytevector? identity) (bytevector->immutable-bytevector identity)]
            [else identity])))

  (define (buffer-live? buffer)
    (and (buffer? buffer) (eq? (buffer-lifecycle buffer) 'live)))

  (define (buffer-key-token key)
    (unless (buffer-key? key)
      (assertion-violation 'buffer-key-token "expected a BufferKey" key))
    (list (buffer-key-namespace key) (buffer-key-identity key)))

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
              'live)])
      (owner-add-cleanup! owner (lambda () (on-close buffer)))
      buffer))

  (define (buffer-publish-state! buffer state)
    (unless (buffer-live? buffer)
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
    (if (eq? (buffer-lifecycle buffer) 'closed)
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
          (buffer-lifecycle-set! buffer 'closed)
          #t)))

  (define-record-type
    (buffer-service %make-buffer-service buffer-service?)
    (fields (immutable identities buffer-service-identities)
            (immutable table buffer-service-table)
            (immutable catalog buffer-service-catalog)
            (immutable reverse-catalog buffer-service-reverse-catalog)
            (immutable close-requests buffer-service-close-requests)
            (mutable close-query! buffer-service-close-query-handler
                     buffer-service-close-query-handler-set!)
            (mutable close! buffer-service-close-handler buffer-service-close-handler-set!)
            (mutable close-listeners buffer-service-close-listeners
                     buffer-service-close-listeners-set!)))

  (define (make-buffer-service)
    (%make-buffer-service (make-identity-source) (make-eqv-hashtable)
                          (make-hashtable equal-hash equal?) (make-eqv-hashtable)
                          (make-eqv-hashtable)
                          (lambda (buffer) #t) (lambda (buffer) #t) '()))

  (define (buffer-service-set-close-query-handler! service handler)
    (unless (and (buffer-service? service) (procedure? handler))
      (assertion-violation 'buffer-service-set-close-query-handler!
                           "expected a BufferService and close query handler" service handler))
    (buffer-service-close-query-handler-set! service handler)
    handler)

  (define (buffer-service-set-close-handler! service handler)
    (unless (and (buffer-service? service) (procedure? handler))
      (assertion-violation 'buffer-service-set-close-handler!
                           "expected a BufferService and close handler" service handler))
    (buffer-service-close-handler-set! service handler)
    handler)

  ;; The primary close handler preserves host invariants; package listeners
  ;; run after it and before the Buffer releases its document resources.
  (define (buffer-service-add-close-listener! service owner procedure)
    (unless (and (buffer-service? service) (owner? owner) (procedure? procedure))
      (assertion-violation 'buffer-service-add-close-listener!
                           "expected a BufferService, owner, and procedure"
                           service owner procedure))
    (owner-assert-active 'buffer-service-add-close-listener! owner)
    (let ([listener procedure])
      (buffer-service-close-listeners-set!
        service (append (buffer-service-close-listeners service) (list listener)))
      (make-registration
        owner
        (lambda ()
          (buffer-service-close-listeners-set!
            service
            (filter (lambda (item) (not (eq? item listener)))
                    (buffer-service-close-listeners service)))))))

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

  (define (buffer-service-find-key service key . default)
    (unless (and (buffer-service? service) (buffer-key? key))
      (assertion-violation 'buffer-service-find-key "expected a BufferService and BufferKey"
                           service key))
    (let* ([token (buffer-key-token key)]
           [id (hashtable-ref (buffer-service-catalog service) token #f)]
           [buffer (and id (buffer-service-ref service id #f))])
      (if buffer
          buffer
          (begin
            (when id
              ;; A stale mapping is never observable as a live Buffer.
              (hashtable-delete! (buffer-service-catalog service) token))
            (if (null? default) #f (car default))))))

  (define (buffer-service-bind-key! service key buffer)
    (unless (and (buffer-service? service) (buffer-key? key) (buffer-live? buffer))
      (assertion-violation 'buffer-service-bind-key!
                           "expected a live BufferService, BufferKey, and Buffer"
                           service key buffer))
    (let* ([token (buffer-key-token key)]
           [existing-id (hashtable-ref (buffer-service-catalog service) token #f)]
           [existing (and existing-id (buffer-service-ref service existing-id #f))]
           [bound-key (hashtable-ref (buffer-service-reverse-catalog service)
                                     (buffer-id buffer) #f)])
      (unless (eq? (hashtable-ref (buffer-service-table service) (buffer-id buffer) #f)
                   buffer)
        (assertion-violation 'buffer-service-bind-key!
                             "Buffer does not belong to this BufferService" buffer))
      (when (and existing (not (= (buffer-id existing) (buffer-id buffer))))
        (assertion-violation 'buffer-service-bind-key!
                             "BufferKey is already bound to a live Buffer" key existing))
      (when (and bound-key (not (equal? bound-key token)))
        (assertion-violation 'buffer-service-bind-key!
                             "Buffer is already bound to a different BufferKey" buffer key))
      (hashtable-set! (buffer-service-catalog service) token (buffer-id buffer))
      (hashtable-set! (buffer-service-reverse-catalog service) (buffer-id buffer) token)
      buffer))

  ;; Builders are only evaluated on a catalog miss.  In Soda's single host
  ;; thread this makes lookup, creation, and binding one atomic host action.
  (define (buffer-service-open-or-create! service owner key builder)
    (unless (and (buffer-service? service) (owner? owner) (buffer-key? key)
                 (procedure? builder))
      (assertion-violation 'buffer-service-open-or-create!
                           "expected a BufferService, owner, BufferKey, and builder"
                           service owner key builder))
    (owner-assert-active 'buffer-service-open-or-create! owner)
    (or (buffer-service-find-key service key #f)
        (let ([buffer (builder)])
          (unless (buffer-live? buffer)
            (assertion-violation 'buffer-service-open-or-create!
                                 "builder must return a live Buffer" buffer))
          (buffer-service-bind-key! service key buffer))))

  (define (buffer-service-ref service id . default)
    (let ([buffer (hashtable-ref (buffer-service-table service) id #f)])
      (if (buffer-live? buffer)
          buffer
          (if (null? default) #f (car default)))))

  (define (buffer-service-buffers service)
    (call-with-values
      (lambda () (hashtable-entries (buffer-service-table service)))
      (lambda (ids values)
        (filter buffer-live?
                (vector->list values)))))

  (define (buffer-service-close-buffer! service id)
    (let ([buffer (buffer-service-ref service id #f)])
      (and buffer
           (not (hashtable-contains? (buffer-service-close-requests service) id))
           (dynamic-wind
             (lambda ()
               (hashtable-set! (buffer-service-close-requests service) id #t))
             (lambda ()
               (let ([allowed? ((buffer-service-close-query-handler service) buffer)])
                 (and allowed?
                      (dynamic-wind
                        (lambda () (buffer-lifecycle-set! buffer 'closing))
                        (lambda ()
                          (unless ((buffer-service-close-handler service) buffer)
                            (assertion-violation
                              'buffer-service-close-buffer!
                              "close handler rejected a Buffer after close query" buffer))
                        (for-each
                          (lambda (listener)
                            (guard (ignored [else #f]) (listener buffer)))
                          (buffer-service-close-listeners service))
                        ;; Remove the identity before releasing Document state.
                        (let ([token (hashtable-ref (buffer-service-reverse-catalog service) id #f)])
                          (when token
                            ;; Attachment teardown can synchronously open a replacement
                            ;; for the same key.  Retire only this Buffer's binding.
                            (let ([bound-id
                                   (hashtable-ref (buffer-service-catalog service) token #f)])
                              (when (and bound-id (= bound-id id))
                                (hashtable-delete! (buffer-service-catalog service) token)))
                            (hashtable-delete! (buffer-service-reverse-catalog service) id)))
                        (let ([closed? (buffer-close! buffer)])
                          (when closed?
                            (hashtable-delete! (buffer-service-table service) id))
                          closed?))
                        (lambda ()
                          (when (eq? (buffer-lifecycle buffer) 'closing)
                            (buffer-lifecycle-set! buffer 'live)))))))
             (lambda ()
               (hashtable-delete! (buffer-service-close-requests service) id))))
)))
