(library (soda editor buffer)
  (export make-buffer
          buffer?
          buffer-id
          buffer-document
          buffer-resource
          buffer-set-resource!
          buffer-closed?
          buffer-close!
          buffer-language-catalog
          buffer-setting-store
          buffer-adopt-setting-store!
          buffer-revision
          buffer-file-path
          buffer-set-file-path!
          buffer-saved-revision
          buffer-modified?
          buffer-save-pending?
          buffer-begin-save!
          buffer-finish-save!
          buffer-mark-saved!
          buffer-major-mode-name
          buffer-set-major-mode!
          buffer-refresh-language!
          buffer-mode-generation
          buffer-language-profile
          buffer-language-session
          buffer-language-revision
          buffer-language-error
          buffer-structure-index
          buffer-injection-index
          buffer-highlight-runs
          buffer-setting-ref
          buffer-set-local-setting!
          buffer-clear-local-setting!
          buffer-settings-snapshot
          buffer-restore-settings!
          call-with-buffer-syntax-view
          call-with-buffer-transaction
          buffer-adopt-change!
          buffer-undo!
          buffer-redo!
          buffer-undo-to!)
  (import (rnrs)
          (soda document)
          (soda editor condition)
          (soda editor decoration)
          (soda editor injection)
          (soda editor injection-highlighting)
          (soda editor language)
          (soda editor setting)
          (soda editor structure))

  (define-record-type
    (language-runtime %make-language-runtime language-runtime?)
    (fields
      (immutable profile language-runtime-profile)
      (mutable session language-runtime-session language-runtime-session-set!)
      (mutable revision language-runtime-revision language-runtime-revision-set!)
      (mutable error language-runtime-error language-runtime-error-set!)
      (mutable structure-index
               language-runtime-structure-index
               language-runtime-structure-index-set!)
      (mutable injection-index
               language-runtime-injection-index
               language-runtime-injection-index-set!)
      (mutable injection-highlights
               language-runtime-injection-highlights
               language-runtime-injection-highlights-set!)))

  (define-record-type (buffer %make-buffer buffer?)
    (fields
      (immutable id buffer-id)
      (immutable document buffer-document)
      (mutable resource buffer-resource buffer-resource-set!)
      (immutable local-settings buffer-local-settings)
      (immutable language-catalog buffer-language-catalog)
      (mutable setting-store
               buffer-setting-store
               buffer-setting-store-set!)
      (mutable revision buffer-revision buffer-revision-set!)
      (mutable file-path buffer-file-path buffer-file-path-set!)
      (mutable saved-revision
               buffer-saved-revision
               buffer-saved-revision-set!)
      (mutable saved-undo-node
               buffer-saved-undo-node
               buffer-saved-undo-node-set!)
      (mutable pending-save-revision
               buffer-pending-save-revision
               buffer-pending-save-revision-set!)
      (mutable pending-save-undo-node
               buffer-pending-save-undo-node
               buffer-pending-save-undo-node-set!)
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
    (let* ([provider (language-profile-syntax profile)]
           [session (and provider (syntax-open provider snapshot))]
           [structure (language-profile-structure profile)]
           [injections
             (build-injection-index
               profile session snapshot)])
      (%make-language-runtime
        profile
        session
        (snapshot-revision snapshot)
        #f
        (and
          structure
          (structure-provider-build
            structure
            session
            snapshot))
        injections
        (make-injection-highlight-index
          snapshot injections))))

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
         default-language-catalog
         (make-setting-store))]
      [(id document resource mode-name catalog)
       (make-buffer
         id
         document
         resource
         mode-name
         catalog
         (make-setting-store))]
      [(id document resource mode-name catalog setting-store)
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
       (unless (setting-store? setting-store)
         (assertion-violation
           'make-buffer
           "expected a setting store"
           setting-store))
       ;; A successfully constructed buffer owns the document handle and closes
       ;; it with the language runtime.
       (let ([value
               (%make-buffer
                 id
                 document
                 resource
                 (make-eq-hashtable)
                 catalog
                 setting-store
                 (document-revision document)
                 #f
                 (document-revision document)
                 (document-undo-position document)
                 #f
                 #f
                 'fundamental-mode
                 0
                 #f
                 #f)])
         (install-major-mode! value mode-name)
         value)]))

  (define (buffer-set-file-path! value path)
    (require-open-buffer 'buffer-set-file-path! value)
    (unless (or (not path)
                (and (string? path) (positive? (string-length path))))
      (assertion-violation
        'buffer-set-file-path!
        "file path must be a non-empty string or #f"
        path))
    (buffer-file-path-set! value path)
    path)

  (define (buffer-set-resource! value resource)
    (require-open-buffer 'buffer-set-resource! value)
    (unless (or (not resource) (string? resource))
      (assertion-violation
        'buffer-set-resource!
        "resource must be a string or #f"
        resource))
    (buffer-resource-set! value resource)
    resource)

  (define (buffer-adopt-setting-store! value store)
    (require-open-buffer 'buffer-adopt-setting-store! value)
    (unless (setting-store? store)
      (assertion-violation
        'buffer-adopt-setting-store!
        "expected a setting store"
        store))
    (let-values
      ([(keys settings)
        (hashtable-entries (buffer-local-settings value))])
      (let loop ([index 0])
        (unless (= index (vector-length keys))
          (setting-store-validate
            store
            (vector-ref keys index)
            (vector-ref settings index))
          (loop (+ index 1)))))
    (buffer-setting-store-set! value store)
    value)

  (define (buffer-modified? value)
    (require-open-buffer 'buffer-modified? value)
    (and
      (buffer-setting-ref value 'track-modified? #t)
      (or
        (buffer-setting-ref value 'file-needs-save? #f)
        (not (= (document-undo-position (buffer-document value))
                (buffer-saved-undo-node value))))))

  (define (buffer-save-pending? value)
    (require-open-buffer 'buffer-save-pending? value)
    (and (buffer-pending-save-revision value) #t))

  (define (buffer-begin-save! value revision)
    (require-open-buffer 'buffer-begin-save! value)
    (unless (and (integer? revision)
                 (exact? revision)
                 (not (negative? revision))
                 (= revision (buffer-revision value)))
      (assertion-violation
        'buffer-begin-save!
        "save revision must match the current buffer revision"
        revision
        (buffer-revision value)))
    (when (buffer-save-pending? value)
      (editor-user-error
        'buffer-begin-save!
        "Buffer already has a pending save"
        (buffer-id value)
        (buffer-pending-save-revision value)))
    (buffer-pending-save-revision-set! value revision)
    (buffer-pending-save-undo-node-set!
      value
      (document-undo-position (buffer-document value)))
    revision)

  (define (buffer-finish-save! value revision saved?)
    (require-open-buffer 'buffer-finish-save! value)
    (unless (and (integer? revision)
                 (exact? revision)
                 (not (negative? revision)))
      (assertion-violation
        'buffer-finish-save!
        "save revision must be a non-negative exact integer"
        revision))
    (unless (boolean? saved?)
      (assertion-violation
        'buffer-finish-save!
        "saved status must be a boolean"
        saved?))
    (unless (and (buffer-pending-save-revision value)
                 (= revision (buffer-pending-save-revision value)))
      (assertion-violation
        'buffer-finish-save!
        "save completion does not match the pending revision"
        revision
        (buffer-pending-save-revision value)))
    (buffer-pending-save-revision-set! value #f)
    (when saved?
      (buffer-saved-revision-set! value revision)
      (buffer-saved-undo-node-set!
        value
        (buffer-pending-save-undo-node value)))
    (buffer-pending-save-undo-node-set! value #f)
    value)

  (define (buffer-mark-saved! value)
    (require-open-buffer 'buffer-mark-saved! value)
    (when (buffer-save-pending? value)
      (assertion-violation
        'buffer-mark-saved!
        "buffer has a pending save"
        (buffer-id value)))
    (buffer-saved-revision-set! value (buffer-revision value))
    (buffer-saved-undo-node-set!
      value
      (document-undo-position (buffer-document value)))
    value)

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

  (define (buffer-structure-index value)
    (require-open-buffer 'buffer-structure-index value)
    (let ([runtime (buffer-language-runtime value)])
      (and
        runtime
        (= (buffer-revision value)
           (language-runtime-revision runtime))
        (language-runtime-structure-index runtime))))

  (define (buffer-injection-index value)
    (require-open-buffer 'buffer-injection-index value)
    (let ([runtime (buffer-language-runtime value)])
      (and
        runtime
        (= (buffer-revision value)
           (language-runtime-revision runtime))
        (language-runtime-injection-index runtime))))

  (define (buffer-highlight-runs value start end)
    (require-open-buffer 'buffer-highlight-runs value)
    (unless
      (and (integer? start)
           (exact? start)
           (integer? end)
           (exact? end)
           (<= 0 start end))
      (assertion-violation
        'buffer-highlight-runs
        "invalid highlight range"
        start
        end))
    (let ([runtime (buffer-language-runtime value)])
      (if (not runtime)
          '()
          (let* ([profile (language-runtime-profile runtime)]
                 [provider (language-profile-syntax profile)]
                 [session (language-runtime-session runtime)]
                 [provided
                   (and
                     provider
                     session
                     (= (buffer-revision value)
                        (language-runtime-revision runtime))
                     (guard (condition
                              [else
                               (language-runtime-error-set!
                                 runtime condition)
                               #f])
                       (syntax-highlights
                         provider session start end)))])
            (append
              (if provided provided '())
              (decoration-index-runs-in-range
                (language-runtime-injection-highlights
                  runtime)
                start
                end))))))

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
               (let ([global
                       (setting-store-explicit-ref
                         (buffer-setting-store value)
                         key
                         missing)])
                 (if (eq? global missing)
                     (let ([mode
                             (major-mode-setting-ref
                               (buffer-language-catalog value)
                               (buffer-mode-name value)
                               key
                               missing)])
                       (if (eq? mode missing)
                           (let ([definition
                                   (setting-store-find
                                     (buffer-setting-store value)
                                     key)])
                             (if definition
                                 (setting-definition-default definition)
                                 default))
                           mode))
                     global))
               local)))]))

  (define (buffer-set-local-setting! value key setting)
    (require-open-buffer 'buffer-set-local-setting! value)
    (unless (symbol? key)
      (assertion-violation
        'buffer-set-local-setting!
        "key must be a symbol"
        key))
    (setting-store-validate
      (buffer-setting-store value)
      key
      setting)
    (hashtable-set! (buffer-local-settings value) key setting))

  (define (buffer-clear-local-setting! value key)
    (require-open-buffer 'buffer-clear-local-setting! value)
    (unless (symbol? key)
      (assertion-violation
        'buffer-clear-local-setting!
        "key must be a symbol"
        key))
    (hashtable-delete! (buffer-local-settings value) key))

  (define (buffer-settings-snapshot value)
    (require-open-buffer 'buffer-settings-snapshot value)
    (hashtable-copy (buffer-local-settings value) #t))

  (define (buffer-restore-settings! value snapshot)
    (require-open-buffer 'buffer-restore-settings! value)
    (unless (hashtable? snapshot)
      (assertion-violation
        'buffer-restore-settings!
        "expected a setting snapshot"
        snapshot))
    (hashtable-clear! (buffer-local-settings value))
    (let-values ([(keys settings) (hashtable-entries snapshot)])
      (let loop ([index 0])
        (unless (= index (vector-length keys))
          (hashtable-set!
            (buffer-local-settings value)
            (vector-ref keys index)
            (vector-ref settings index))
          (loop (+ index 1)))))
    value)

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
      (language-runtime-structure-index-set! runtime #f)
      (language-runtime-injection-index-set! runtime #f)
      (language-runtime-injection-highlights-set!
        runtime
        (make-decoration-index '()))
      (language-runtime-error-set! runtime condition)
      (guard (reopen-condition
               [else
                (language-runtime-error-set!
                  runtime
                  (cons condition reopen-condition))])
        (let ([reopened
                (and provider (syntax-open provider snapshot))])
          (language-runtime-session-set! runtime reopened)
          (language-runtime-structure-index-set!
            runtime
            (let ([structure
                    (language-profile-structure profile)])
              (and
                structure
                (structure-provider-build
                  structure
                  reopened
                  snapshot))))
          (language-runtime-injection-index-set!
            runtime
            (build-injection-index
              profile reopened snapshot))
          (language-runtime-injection-highlights-set!
            runtime
            (make-injection-highlight-index
              snapshot
              (language-runtime-injection-index
                runtime)))
          (language-runtime-revision-set!
            runtime
            (snapshot-revision snapshot))))))

  (define (rebuild-structure! runtime snapshot)
    (let* ([profile (language-runtime-profile runtime)]
           [structure (language-profile-structure profile)])
      (language-runtime-structure-index-set!
        runtime
        (and
          structure
          (structure-provider-build
            structure
            (language-runtime-session runtime)
            snapshot)))))

  (define (snapshot-size snapshot)
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda () (text-size text))
        (lambda () (text-close! text)))))

  (define (build-injection-index profile session snapshot)
    (let ([provider (language-profile-syntax profile)])
      (and
        provider
        session
        (memq 'injection
          (syntax-capabilities provider))
        (syntax-captures->injection-index
          snapshot
          (syntax-query
            provider
            session
            'injection
            0
            (snapshot-size snapshot))))))

  (define (rebuild-injections! runtime snapshot)
    (let ([index
            (build-injection-index
              (language-runtime-profile runtime)
              (language-runtime-session runtime)
              snapshot)])
      (language-runtime-injection-index-set!
        runtime index)
      (language-runtime-injection-highlights-set!
        runtime
        (make-injection-highlight-index
          snapshot index))))

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
                   (rebuild-structure! runtime snapshot)
                   (rebuild-injections! runtime snapshot)
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
                     (rebuild-structure! runtime snapshot)
                     (rebuild-injections! runtime snapshot)
                     (language-runtime-revision-set!
                       runtime
                       (snapshot-revision snapshot))
                     (language-runtime-error-set! runtime #f))]
                  [else
                   (guard (condition
                            [else (recover-runtime! runtime snapshot condition)])
                     (syntax-sync! provider session change snapshot)
                     (rebuild-structure! runtime snapshot)
                     (rebuild-injections! runtime snapshot)
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
