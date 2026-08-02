(library (soda editor language-session)
  (export make-language-session-key
          language-session-key?
          language-session-key-language
          language-session-key-provider
          language-session-key-workspace-folders
          language-session-key-configuration
          language-session-key-environment-fingerprint
          language-session-key-client-capabilities
          language-session?
          language-session-id
          language-session-identity
          language-session-generation
          language-session-bump-generation!
          language-attachment?
          language-attachment-id
          language-attachment-buffer-id
          language-attachment-session-id
          language-attachment-provenance
          language-attachment-origin-view-id
          language-attachment-opened-revision
          make-view-language-context
          view-language-context?
          view-language-context-attachment-id
          make-language-session-registry
          language-session-registry?
          language-session-registry-sessions
          language-session-registry-attachments
          language-session-registry-ensure!
          language-session-registry-session-ref
          language-session-registry-attach!
          language-session-registry-attachment-ref
          language-session-registry-buffer-attachments
          language-session-registry-remove-session!
          language-session-registry-detach-buffer!)
  (import (rnrs)
          (soda editor contract))

  (define-record-type
    (language-session-key %make-language-session-key language-session-key?)
    (fields language
            provider
            workspace-folders-data
            configuration-data
            environment-fingerprint-data
            client-capabilities-data))

  (define-record-type
    (language-session %make-language-session language-session?)
    (fields id
            (immutable key language-session-identity)
            (mutable generation
                     language-session-generation
                     language-session-generation-set!)))

  (define-record-type
    (language-attachment %make-language-attachment language-attachment?)
    (fields id
            buffer-id
            session-id
            (mutable provenance
                     language-attachment-provenance
                     language-attachment-provenance-set!)
            (mutable origin-view-id
                     language-attachment-origin-view-id
                     language-attachment-origin-view-id-set!)
            (mutable opened-revision
                     language-attachment-opened-revision
                     language-attachment-opened-revision-set!)))

  (define-record-type view-language-context
    (fields attachment-id))

  (define-record-type
    (language-session-registry
      %make-language-session-registry
      language-session-registry?)
    (fields
      (mutable sessions
               language-session-registry-sessions
               language-session-registry-sessions-set!)
      (mutable attachments
               language-session-registry-attachments
               language-session-registry-attachments-set!)
      (mutable next-session-id
               language-session-registry-next-session-id
               language-session-registry-next-session-id-set!)
      (mutable next-attachment-id
               language-session-registry-next-attachment-id
               language-session-registry-next-attachment-id-set!)))

  (define (snapshot-value value)
    (cond
      [(pair? value)
       (cons (snapshot-value (car value))
             (snapshot-value (cdr value)))]
      [(vector? value)
       (list->vector (map snapshot-value (vector->list value)))]
      [(bytevector? value) (bytevector-copy value)]
      [(string? value) (string-copy value)]
      [else value]))

  (define (language-session-key-workspace-folders key)
    (snapshot-value
      (language-session-key-workspace-folders-data key)))

  (define (language-session-key-configuration key)
    (snapshot-value
      (language-session-key-configuration-data key)))

  (define (language-session-key-environment-fingerprint key)
    (snapshot-value
      (language-session-key-environment-fingerprint-data key)))

  (define (language-session-key-client-capabilities key)
    (snapshot-value
      (language-session-key-client-capabilities-data key)))

  (define make-language-session-key
    (case-lambda
      [(language provider workspace-folders)
       (make-language-session-key
         language provider workspace-folders '() #f '())]
      [(language
         provider
         workspace-folders
         configuration
         environment-fingerprint
         client-capabilities)
       (unless (symbol? language)
         (assertion-violation
           'make-language-session-key
           "language must be a symbol"
           language))
       (unless
         (or
           (symbol? provider)
           (and (string? provider) (positive? (string-length provider))))
         (assertion-violation
           'make-language-session-key
           "provider must be a symbol or non-empty string"
           provider))
       (unless
         (and
           (list? workspace-folders)
           (for-all
             (lambda (folder)
               (and (string? folder) (positive? (string-length folder))))
             workspace-folders))
         (assertion-violation
           'make-language-session-key
           "workspace folders must be strings"
           workspace-folders))
       (%make-language-session-key
         language
         provider
         (snapshot-value workspace-folders)
         (snapshot-value configuration)
         (snapshot-value environment-fingerprint)
         (snapshot-value client-capabilities))]))

  (define (language-session-key=? left right)
    (and
      (eq? (language-session-key-language left)
           (language-session-key-language right))
      (equal? (language-session-key-provider left)
              (language-session-key-provider right))
      (equal? (language-session-key-workspace-folders-data left)
              (language-session-key-workspace-folders-data right))
      (equal? (language-session-key-configuration-data left)
              (language-session-key-configuration-data right))
      (equal? (language-session-key-environment-fingerprint-data left)
              (language-session-key-environment-fingerprint-data right))
      (equal? (language-session-key-client-capabilities-data left)
              (language-session-key-client-capabilities-data right))))

  (define (make-language-session-registry)
    (%make-language-session-registry '() '() 1 1))

  (define (require-registry who registry)
    (unless (language-session-registry? registry)
      (assertion-violation who "expected a LanguageSession registry" registry)))

  (define (language-session-registry-ensure! registry key)
    (require-registry 'language-session-registry-ensure! registry)
    (unless (language-session-key? key)
      (assertion-violation
        'language-session-registry-ensure!
        "expected a LanguageSession key"
        key))
    (or
      (find
        (lambda (session)
          (language-session-key=? (language-session-identity session) key))
        (language-session-registry-sessions registry))
      (let* ([id (language-session-registry-next-session-id registry)]
             [session (%make-language-session id key 0)])
        (language-session-registry-next-session-id-set! registry (+ id 1))
        (language-session-registry-sessions-set!
          registry
          (append
            (language-session-registry-sessions registry)
            (list session)))
        session)))

  (define (language-session-registry-session-ref registry id)
    (require-registry 'language-session-registry-session-ref registry)
    (unless (exact-positive-integer? id)
      (assertion-violation
        'language-session-registry-session-ref
        "session id must be positive"
        id))
    (or
      (find
        (lambda (session) (= (language-session-id session) id))
        (language-session-registry-sessions registry))
      (assertion-violation
        'language-session-registry-session-ref
        "unknown LanguageSession"
        id)))

  (define (language-session-bump-generation! session)
    (unless (language-session? session)
      (assertion-violation
        'language-session-bump-generation!
        "expected a LanguageSession"
        session))
    (language-session-generation-set!
      session
      (+ (language-session-generation session) 1))
    (language-session-generation session))

  (define (language-session-registry-attachment-ref registry id)
    (require-registry 'language-session-registry-attachment-ref registry)
    (unless (exact-positive-integer? id)
      (assertion-violation
        'language-session-registry-attachment-ref
        "attachment id must be positive"
        id))
    (or
      (find
        (lambda (attachment)
          (= (language-attachment-id attachment) id))
        (language-session-registry-attachments registry))
      (assertion-violation
        'language-session-registry-attachment-ref
        "unknown LanguageAttachment"
        id)))

  (define (language-session-registry-attach!
            registry buffer-id session-id provenance origin-view-id revision)
    (require-registry 'language-session-registry-attach! registry)
    (unless (exact-positive-integer? buffer-id)
      (assertion-violation
        'language-session-registry-attach!
        "buffer id must be positive"
        buffer-id))
    (language-session-registry-session-ref registry session-id)
    (unless (memq provenance '(home inherited))
      (assertion-violation
        'language-session-registry-attach!
        "provenance must be home or inherited"
        provenance))
    (unless
      (or (not origin-view-id)
          (exact-non-negative-integer? origin-view-id))
      (assertion-violation
        'language-session-registry-attach!
        "origin View id must be non-negative or #f"
        origin-view-id))
    (unless (exact-non-negative-integer? revision)
      (assertion-violation
        'language-session-registry-attach!
        "opened revision must be non-negative"
        revision))
    (let ([existing
            (find
              (lambda (attachment)
                (and
                  (= (language-attachment-buffer-id attachment) buffer-id)
                  (= (language-attachment-session-id attachment) session-id)))
              (language-session-registry-attachments registry))])
      (if existing
          (begin
            (when (eq? provenance 'home)
              (language-attachment-provenance-set! existing 'home))
            (language-attachment-origin-view-id-set! existing origin-view-id)
            (language-attachment-opened-revision-set! existing revision)
            existing)
          (let* ([id
                   (language-session-registry-next-attachment-id registry)]
                 [attachment
                   (%make-language-attachment
                     id buffer-id session-id provenance origin-view-id revision)])
            (language-session-registry-next-attachment-id-set!
              registry (+ id 1))
            (language-session-registry-attachments-set!
              registry
              (append
                (language-session-registry-attachments registry)
                (list attachment)))
            attachment))))

  (define (language-session-registry-buffer-attachments registry buffer-id)
    (require-registry
      'language-session-registry-buffer-attachments registry)
    (filter
      (lambda (attachment)
        (= (language-attachment-buffer-id attachment) buffer-id))
      (language-session-registry-attachments registry)))

  (define (language-session-registry-remove-session! registry session-id)
    (require-registry 'language-session-registry-remove-session! registry)
    (let* ([session
             (language-session-registry-session-ref registry session-id)]
           [removed
             (filter
               (lambda (attachment)
                 (= (language-attachment-session-id attachment) session-id))
               (language-session-registry-attachments registry))])
      (language-session-registry-sessions-set!
        registry
        (filter
          (lambda (candidate) (not (eq? candidate session)))
          (language-session-registry-sessions registry)))
      (language-session-registry-attachments-set!
        registry
        (filter
          (lambda (attachment)
            (not (= (language-attachment-session-id attachment) session-id)))
          (language-session-registry-attachments registry)))
      removed))

  (define (language-session-registry-detach-buffer! registry buffer-id)
    (require-registry 'language-session-registry-detach-buffer! registry)
    (let ([removed
            (language-session-registry-buffer-attachments
              registry buffer-id)])
      (language-session-registry-attachments-set!
        registry
        (filter
          (lambda (attachment)
            (not (= (language-attachment-buffer-id attachment) buffer-id)))
          (language-session-registry-attachments registry)))
      removed))
)
