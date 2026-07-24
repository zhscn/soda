(library (soda editor buffer)
  (export make-buffer
          buffer?
          buffer-id
          buffer-document
          buffer-resource
          buffer-closed?
          buffer-close!
          buffer-language-catalog
          buffer-revision
          buffer-major-mode-name
          buffer-set-major-mode!
          buffer-refresh-language!
          buffer-mode-generation
          buffer-language-profile
          buffer-language-session
          buffer-language-revision
          buffer-language-error
          buffer-setting-ref
          buffer-set-local-setting!
          buffer-clear-local-setting!
          call-with-buffer-syntax-view
          call-with-buffer-transaction
          buffer-adopt-change!
          buffer-undo!
          buffer-redo!
          buffer-undo-to!)
  (import (rnrs)
          (soda document)
          (soda editor language))

  (define-record-type
    (language-runtime %make-language-runtime language-runtime?)
    (fields
      (immutable profile language-runtime-profile)
      (mutable session language-runtime-session language-runtime-session-set!)
      (mutable revision language-runtime-revision language-runtime-revision-set!)
      (mutable error language-runtime-error language-runtime-error-set!)))

  (define-record-type (buffer %make-buffer buffer?)
    (fields
      (immutable id buffer-id)
      (immutable document buffer-document)
      (immutable resource buffer-resource)
      (immutable local-settings buffer-local-settings)
      (immutable language-catalog buffer-language-catalog)
      (mutable revision buffer-revision buffer-revision-set!)
      (mutable mode-name buffer-mode-name buffer-mode-name-set!)
      (mutable mode-generation buffer-mode-generation buffer-mode-generation-set!)
      (mutable language-runtime
               buffer-language-runtime
               buffer-language-runtime-set!)
      (mutable closed? buffer-closed? buffer-closed?-set!)))

  (define (require-open-buffer who value)
    (unless (buffer? value)
      (assertion-violation who "expected a buffer" value))
    (when (buffer-closed? value)
      (assertion-violation who "buffer is closed" value)))

  (define (close-runtime! runtime)
    (when runtime
      (let* ([profile (language-runtime-profile runtime)]
             [provider (language-profile-syntax profile)]
             [session (language-runtime-session runtime)])
        (when (and provider session)
          (guard (condition [else #f])
            (syntax-close! provider session)))
        (language-runtime-session-set! runtime #f))))

  (define (open-runtime profile snapshot)
    (let ([provider (language-profile-syntax profile)])
      (%make-language-runtime
        profile
        (and provider (syntax-open provider snapshot))
        (snapshot-revision snapshot)
        #f)))

  (define (profile-for-mode catalog mode-name)
    (let ([language
            (resolve-major-mode-language catalog mode-name)])
      (and language (language-profile-ref catalog language))))

  (define (install-major-mode! value mode-name)
    (unless (= (buffer-revision value)
               (document-revision (buffer-document value)))
      (assertion-violation
        'buffer-set-major-mode!
        "document has a change that the buffer has not adopted"
        (buffer-revision value)
        (document-revision (buffer-document value))))
    (let* ([catalog (buffer-language-catalog value)]
           [mode (major-mode-ref catalog mode-name)]
           [profile (profile-for-mode catalog (major-mode-name mode))]
           [snapshot (document-snapshot (buffer-document value))]
           [new-runtime
             (dynamic-wind
               (lambda () #f)
               (lambda () (and profile (open-runtime profile snapshot)))
               (lambda () (snapshot-close! snapshot)))])
      (close-runtime! (buffer-language-runtime value))
      (buffer-mode-name-set! value (major-mode-name mode))
      (buffer-language-runtime-set! value new-runtime)
      (buffer-mode-generation-set!
        value
        (+ (buffer-mode-generation value) 1))))

  (define make-buffer
    (case-lambda
      [(id document resource mode-name)
       (make-buffer
         id
         document
         resource
         mode-name
         default-language-catalog)]
      [(id document resource mode-name catalog)
       (unless (and (integer? id) (exact? id) (not (negative? id)))
         (assertion-violation
           'make-buffer
           "id must be a non-negative exact integer"
           id))
       (unless (document? document)
         (assertion-violation
           'make-buffer
           "expected a document"
           document))
       (unless (language-catalog? catalog)
         (assertion-violation
           'make-buffer
           "expected a language catalog"
           catalog))
       ;; A successfully constructed buffer owns the document handle and closes
       ;; it with the language runtime.
       (let ([value
               (%make-buffer
                 id
                 document
                 resource
                 (make-eq-hashtable)
                 catalog
                 (document-revision document)
                 'fundamental-mode
                 0
                 #f
                 #f)])
         (install-major-mode! value mode-name)
         value)]))

  (define (buffer-close! value)
    (when (and (buffer? value) (not (buffer-closed? value)))
      (close-runtime! (buffer-language-runtime value))
      (buffer-language-runtime-set! value #f)
      (document-close! (buffer-document value))
      (buffer-closed?-set! value #t)))

  (define (buffer-major-mode-name value)
    (require-open-buffer 'buffer-major-mode-name value)
    (buffer-mode-name value))

  (define (buffer-set-major-mode! value mode-name)
    (require-open-buffer 'buffer-set-major-mode! value)
    (install-major-mode! value mode-name))

  (define (buffer-refresh-language! value)
    (require-open-buffer 'buffer-refresh-language! value)
    (install-major-mode! value (buffer-mode-name value)))

  (define (buffer-language-profile value)
    (require-open-buffer 'buffer-language-profile value)
    (let ([runtime (buffer-language-runtime value)])
      (and runtime (language-runtime-profile runtime))))

  (define (buffer-language-session value)
    (require-open-buffer 'buffer-language-session value)
    (let ([runtime (buffer-language-runtime value)])
      (and runtime (language-runtime-session runtime))))

  (define (buffer-language-revision value)
    (require-open-buffer 'buffer-language-revision value)
    (let ([runtime (buffer-language-runtime value)])
      (and runtime (language-runtime-revision runtime))))

  (define (buffer-language-error value)
    (require-open-buffer 'buffer-language-error value)
    (let ([runtime (buffer-language-runtime value)])
      (and runtime (language-runtime-error runtime))))

  (define buffer-setting-ref
    (case-lambda
      [(value key) (buffer-setting-ref value key #f)]
      [(value key default)
       (require-open-buffer 'buffer-setting-ref value)
       (unless (symbol? key)
         (assertion-violation 'buffer-setting-ref "key must be a symbol" key))
       (let ([missing (list 'missing)])
         (let ([local
                 (hashtable-ref (buffer-local-settings value) key missing)])
           (if (eq? local missing)
               (major-mode-setting-ref
                 (buffer-language-catalog value)
                 (buffer-mode-name value)
                 key
                 default)
               local)))]))

  (define (buffer-set-local-setting! value key setting)
    (require-open-buffer 'buffer-set-local-setting! value)
    (unless (symbol? key)
      (assertion-violation
        'buffer-set-local-setting!
        "key must be a symbol"
        key))
    (hashtable-set! (buffer-local-settings value) key setting))

  (define (buffer-clear-local-setting! value key)
    (require-open-buffer 'buffer-clear-local-setting! value)
    (unless (symbol? key)
      (assertion-violation
        'buffer-clear-local-setting!
        "key must be a symbol"
        key))
    (hashtable-delete! (buffer-local-settings value) key))

  (define (recover-runtime! runtime snapshot condition)
    ;; Text commits remain authoritative when a derived syntax session fails.
    ;; Reopening from the committed snapshot restores a revision-consistent
    ;; session; the condition remains available through buffer-language-error.
    (let* ([profile (language-runtime-profile runtime)]
           [provider (language-profile-syntax profile)]
           [session (language-runtime-session runtime)])
      (when (and provider session)
        (guard (close-condition [else #f])
          (syntax-close! provider session)))
      (language-runtime-session-set! runtime #f)
      (language-runtime-revision-set! runtime #f)
      (language-runtime-error-set! runtime condition)
      (when provider
        (guard (reopen-condition
                 [else
                  (language-runtime-error-set!
                    runtime
                    (cons condition reopen-condition))])
          (language-runtime-session-set!
            runtime
            (syntax-open provider snapshot))
          (language-runtime-revision-set!
            runtime
            (snapshot-revision snapshot))))))

  (define (sync-change! value change)
    (let ([runtime (buffer-language-runtime value)])
      (when runtime
        (let ([snapshot (document-snapshot (buffer-document value))])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let* ([profile (language-runtime-profile runtime)]
                     [provider (language-profile-syntax profile)]
                     [session (language-runtime-session runtime)])
                (cond
                  [(not provider)
                   (language-runtime-revision-set!
                     runtime
                     (snapshot-revision snapshot))
                   (language-runtime-error-set! runtime #f)]
                  [(not session)
                   (guard (condition
                            [else
                             (language-runtime-revision-set! runtime #f)
                             (language-runtime-error-set! runtime condition)])
                     (language-runtime-session-set!
                       runtime
                       (syntax-open provider snapshot))
                     (language-runtime-revision-set!
                       runtime
                       (snapshot-revision snapshot))
                     (language-runtime-error-set! runtime #f))]
                  [else
                   (guard (condition
                            [else (recover-runtime! runtime snapshot condition)])
                     (syntax-sync! provider session change snapshot)
                     (language-runtime-revision-set!
                       runtime
                       (snapshot-revision snapshot))
                     (language-runtime-error-set! runtime #f))])))
            (lambda () (snapshot-close! snapshot)))))))

  (define (transaction-pending-edits transaction)
    (let* ([count (transaction-pending-edit-count transaction)]
           [edits (make-vector count)])
      (do ([index 0 (+ index 1)])
          ((= index count) edits)
        (let ([range (transaction-pending-edit-range transaction index)])
          (vector-set!
            edits
            index
            (vector
              (car range)
              (cdr range)
              (transaction-pending-edit-text transaction index)))))))

  (define (call-with-buffer-syntax-view value transaction procedure)
    (require-open-buffer 'call-with-buffer-syntax-view value)
    (unless (transaction? transaction)
      (assertion-violation
        'call-with-buffer-syntax-view
        "expected a transaction"
        transaction))
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-buffer-syntax-view
        "expected a procedure"
        procedure))
    (let ([runtime (buffer-language-runtime value)])
      (if (not runtime)
          (procedure #f)
          (let* ([profile (language-runtime-profile runtime)]
                 [provider (language-profile-syntax profile)]
                 [session (language-runtime-session runtime)])
            (if (or (not provider) (not session))
                (procedure #f)
                (begin
                  (unless (= (transaction-base-revision transaction)
                             (language-runtime-revision runtime))
                    (assertion-violation
                      'call-with-buffer-syntax-view
                      "transaction and syntax session revisions differ"
                      (transaction-base-revision transaction)
                      (language-runtime-revision runtime)))
                  (let ([snapshot (transaction-snapshot transaction)]
                        [view #f])
                    (dynamic-wind
                      (lambda () #f)
                      (lambda ()
                        (unless (= (snapshot-document-id snapshot)
                                   (document-id (buffer-document value)))
                          (assertion-violation
                            'call-with-buffer-syntax-view
                            "transaction belongs to another document"
                            (snapshot-document-id snapshot)
                            (document-id (buffer-document value))))
                        (set! view
                          (syntax-view
                            provider
                            session
                            snapshot
                            (transaction-pending-edits transaction)))
                        (procedure view))
                      (lambda ()
                        (guard (condition [else #f])
                          (syntax-close-view! provider view))
                        (snapshot-close! snapshot))))))))))

  (define (call-with-buffer-transaction value procedure)
    (require-open-buffer 'call-with-buffer-transaction value)
    (unless (procedure? procedure)
      (assertion-violation
        'call-with-buffer-transaction
        "expected a procedure"
        procedure))
    (unless (= (buffer-revision value)
               (document-revision (buffer-document value)))
      (assertion-violation
        'call-with-buffer-transaction
        "document has a change that the buffer has not adopted"
        (buffer-revision value)
        (document-revision (buffer-document value))))
    (let ([transaction
            (document-begin-transaction (buffer-document value))]
          [committed? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([result (procedure transaction)]
                 [change (transaction-commit! transaction)])
            (set! committed? #t)
            (buffer-revision-set!
              value
              (change-new-revision change))
            (when (not (= (change-old-revision change)
                          (change-new-revision change)))
              (sync-change! value change))
            (values result change)))
        (lambda ()
          (unless committed?
            (guard (condition [else #f])
              (transaction-abort! transaction)))
          (transaction-close! transaction)))))

  (define (buffer-adopt-change! value change)
    (require-open-buffer 'buffer-adopt-change! value)
    (unless (change? change)
      (assertion-violation
        'buffer-adopt-change!
        "expected a document change"
        change))
    (let ([old-revision (change-old-revision change)]
          [new-revision (change-new-revision change)])
      (unless (= old-revision (buffer-revision value))
        (assertion-violation
          'buffer-adopt-change!
          "change does not begin at the buffer revision"
          old-revision
          (buffer-revision value)))
      (unless (= new-revision
                 (document-revision (buffer-document value)))
        (assertion-violation
          'buffer-adopt-change!
          "change does not end at the document revision"
          new-revision
          (document-revision (buffer-document value))))
      (buffer-revision-set! value new-revision)
      (when (not (= old-revision new-revision))
        (sync-change! value change))
      change))

  (define (sync-optional-change! value change)
    (when change
      (buffer-adopt-change! value change))
    change)

  (define (buffer-undo! value)
    (require-open-buffer 'buffer-undo! value)
    (unless (= (buffer-revision value)
               (document-revision (buffer-document value)))
      (assertion-violation
        'buffer-undo!
        "document has a change that the buffer has not adopted"))
    (sync-optional-change!
      value
      (document-undo! (buffer-document value))))

  (define (buffer-redo! value)
    (require-open-buffer 'buffer-redo! value)
    (unless (= (buffer-revision value)
               (document-revision (buffer-document value)))
      (assertion-violation
        'buffer-redo!
        "document has a change that the buffer has not adopted"))
    (sync-optional-change!
      value
      (document-redo! (buffer-document value))))

  (define (buffer-undo-to! value node)
    (require-open-buffer 'buffer-undo-to! value)
    (unless (= (buffer-revision value)
               (document-revision (buffer-document value)))
      (assertion-violation
        'buffer-undo-to!
        "document has a change that the buffer has not adopted"))
    (sync-optional-change!
      value
      (document-undo-to! (buffer-document value) node))))
