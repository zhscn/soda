(library (soda host internal buffer-attachment)
  (export buffer-attachment?
          buffer-attachment-key
          buffer-attachment-owner
          buffer-attachment-buffer-id
          buffer-attachment-generation
          buffer-attachment-close-query
          buffer-attachment-refresh
          make-buffer-attachment-service
          buffer-attachment-service?
          buffer-attachment-service-install!
          buffer-attachment-service-ref
          buffer-attachment-service-attachments
          buffer-attachment-service-prepare-close!
          buffer-attachment-service-destroy-buffer!)
  (import (rnrs)
          (only (chezscheme) equal-hash)
          (soda host internal buffer)
          (soda host value))

  ;; Attachments own mutable host resources that must not enter BufferState:
  ;; process handles, watchers, pending requests, and refresh producers.  The
  ;; key is package-local and has structural equality only within one Buffer.
  (define-record-type
    (buffer-attachment %make-buffer-attachment buffer-attachment?)
    (fields (immutable key buffer-attachment-key)
            (immutable owner buffer-attachment-owner)
            (immutable buffer-id buffer-attachment-buffer-id)
            (immutable generation buffer-attachment-generation)
            (immutable close-query buffer-attachment-close-query)
            (immutable refresh buffer-attachment-refresh)
            (immutable destroy buffer-attachment-destroy)
            (mutable registration buffer-attachment-registration
                     buffer-attachment-registration-set!)
            (mutable destroyed? buffer-attachment-destroyed?
                     buffer-attachment-destroyed?-set!)))

  (define-record-type
    (buffer-attachment-service %make-buffer-attachment-service buffer-attachment-service?)
    (fields (immutable buffers buffer-attachment-service-buffers)
            (immutable table buffer-attachment-service-table)))

  (define (attachment-token buffer-id key)
    (list buffer-id key))

  (define (valid-generation? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (optional-procedure? value)
    (or (not value) (procedure? value)))

  (define (make-buffer-attachment-service buffers)
    (unless (buffer-service? buffers)
      (assertion-violation 'make-buffer-attachment-service
                           "expected a BufferService" buffers))
    (%make-buffer-attachment-service buffers (make-hashtable equal-hash equal?)))

  (define (remove-from-table! service attachment)
    (let* ([token (attachment-token (buffer-attachment-buffer-id attachment)
                                    (buffer-attachment-key attachment))]
           [current (hashtable-ref (buffer-attachment-service-table service) token #f)])
      (when (eq? current attachment)
        (hashtable-delete! (buffer-attachment-service-table service) token))))

  (define (destroy-attachment! service attachment)
    (unless (buffer-attachment-destroyed? attachment)
      (buffer-attachment-destroyed?-set! attachment #t)
      (remove-from-table! service attachment)
      ;; Resource cleanup cannot leave the owning Buffer half-closed.  Package
      ;; entry points report operational errors before requesting close; an
      ;; attachment destructor is best-effort and always retires its entry.
      (guard (ignored [else #f])
        ((buffer-attachment-destroy attachment))))
    #t)

  (define (detach-attachment! service attachment)
    (unless (buffer-attachment? attachment)
      (assertion-violation 'detach-attachment! "expected a BufferAttachment" attachment))
    (let ([registration (buffer-attachment-registration attachment)])
      (when registration (registration-close! registration)))
    (destroy-attachment! service attachment))

  (define (buffer-attachment-service-install!
           service owner buffer key generation close-query refresh destroy)
    (unless (and (buffer-attachment-service? service) (owner? owner)
                 (buffer? buffer) (buffer-live? buffer) (valid-generation? generation)
                 (optional-procedure? close-query) (optional-procedure? refresh)
                 (procedure? destroy))
      (assertion-violation 'buffer-attachment-service-install!
                           "invalid BufferAttachment declaration"
                           service owner buffer key generation close-query refresh destroy))
    (owner-assert-active 'buffer-attachment-service-install! owner)
    (let* ([token (attachment-token (buffer-id buffer) key)]
           [table (buffer-attachment-service-table service)])
      (when (hashtable-ref table token #f)
        (assertion-violation 'buffer-attachment-service-install!
                             "attachment key is already installed for Buffer" key (buffer-id buffer)))
      (let ([attachment
             (%make-buffer-attachment key owner (buffer-id buffer) generation
                                      close-query refresh destroy #f #f)])
        (hashtable-set! table token attachment)
        (buffer-attachment-registration-set!
          attachment
          (make-registration
            owner
            (lambda () (detach-attachment! service attachment))))
        attachment)))

  (define (buffer-attachment-service-ref service buffer-id key . default)
    (unless (and (buffer-attachment-service? service) (valid-generation? buffer-id))
      (assertion-violation 'buffer-attachment-service-ref
                           "expected a BufferAttachmentService and Buffer id" service buffer-id))
    (let ([attachment
           (hashtable-ref (buffer-attachment-service-table service)
                          (attachment-token buffer-id key) #f)])
      (if (and attachment (not (buffer-attachment-destroyed? attachment)))
          attachment
          (if (null? default) #f (car default)))))

  (define (buffer-attachment-service-attachments service buffer-id)
    (unless (and (buffer-attachment-service? service) (valid-generation? buffer-id))
      (assertion-violation 'buffer-attachment-service-attachments
                           "expected a BufferAttachmentService and Buffer id" service buffer-id))
    (call-with-values
      (lambda () (hashtable-entries (buffer-attachment-service-table service)))
      (lambda (keys values)
        (filter (lambda (attachment)
                  (and (= (buffer-attachment-buffer-id attachment) buffer-id)
                       (not (buffer-attachment-destroyed? attachment))))
                (vector->list values)))))

  ;; Close queries are deliberately synchronous host predicates.  A package
  ;; that needs user interaction leaves the Buffer live, starts an ordinary
  ;; interaction command, then retries close after its continuation resolves.
  (define (buffer-attachment-service-prepare-close! service buffer)
    (unless (and (buffer-attachment-service? service) (buffer? buffer))
      (assertion-violation 'buffer-attachment-service-prepare-close!
                           "expected a BufferAttachmentService and Buffer" service buffer))
    (let loop ([attachments
                (buffer-attachment-service-attachments service (buffer-id buffer))])
      (or (null? attachments)
          (let ([query (buffer-attachment-close-query (car attachments))])
            (and (or (not query) (query (car attachments)))
                 (loop (cdr attachments)))))))

  (define (buffer-attachment-service-destroy-buffer! service buffer)
    (unless (and (buffer-attachment-service? service) (buffer? buffer))
      (assertion-violation 'buffer-attachment-service-destroy-buffer!
                           "expected a BufferAttachmentService and Buffer" service buffer))
    (for-each
      (lambda (attachment) (detach-attachment! service attachment))
      (buffer-attachment-service-attachments service (buffer-id buffer)))
    #t)
)
