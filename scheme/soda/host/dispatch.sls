(library (soda host dispatch)
  (export make-editor-update
          editor-update?
          editor-update-buffer-id
          editor-update-old-buffer-state
          editor-update-new-buffer-state
          editor-update-views
          editor-update-changes
          editor-update-annotations
          editor-update-damage
          make-dispatcher
          dispatcher?
          dispatcher-dispatch!
          dispatcher-set-listener!)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel extension)
          (soda kernel state)
          (soda host buffer)
          (soda host value)
          (soda host view))

  (define-record-type
    (editor-update %make-editor-update editor-update?)
    (fields
      (immutable buffer-id editor-update-buffer-id)
      (immutable old-buffer-state editor-update-old-buffer-state)
      (immutable new-buffer-state editor-update-new-buffer-state)
      (immutable views editor-update-views)
      (immutable changes editor-update-changes)
      (immutable annotations editor-update-annotations)
      (immutable damage editor-update-damage)))

  (define (make-editor-update buffer-id old-state new-state views changes annotations damage)
    (%make-editor-update
      buffer-id old-state new-state (list-copy views) changes
      (list-copy annotations) (list-copy damage)))

  (define-record-type
    (dispatcher %make-dispatcher dispatcher?)
    (fields
      (immutable buffers dispatcher-buffers)
      (immutable views dispatcher-views)
      (mutable listener dispatcher-listener dispatcher-listener-set!)))

  (define (make-dispatcher buffers views . listener)
    (unless (and (buffer-service? buffers) (view-service? views))
      (assertion-violation 'make-dispatcher "expected buffer and view services"))
    (%make-dispatcher
      buffers views (if (null? listener) #f (car listener))))

  (define (dispatcher-set-listener! dispatcher listener)
    (unless (or (not listener) (procedure? listener))
      (assertion-violation 'dispatcher-set-listener! "listener must be a procedure" listener))
    (dispatcher-listener-set! dispatcher listener)
    listener)

  (define (prepare-native-change! document changes)
    (if (change-set-empty? changes)
        (cons #f (document-snapshot document))
        (let ([native (make-document-transaction document)])
          (guard
            (condition
              [else
               (guard (condition [else #f])
                 (document-transaction-abort! native))
               (raise condition)])
            ;; Native transactions use current-pending coordinates. Applying
            ;; normalized old coordinates from right to left preserves them.
            (for-each
              (lambda (change)
                (document-transaction-replace!
                  native
                  (text-change-from change)
                  (text-change-to change)
                  (text-change-insert change)))
              (reverse (change-set-changes changes)))
            (cons native (document-transaction-snapshot native))))))

  (define (view-for-origin views origin-id target-buffer-id)
    (let ([view (and origin-id (view-service-ref views origin-id #f))])
      (and view (= (buffer-id (view-buffer view)) target-buffer-id) view)))

  (define (views-for-buffer views target-buffer-id)
    (filter
      (lambda (view)
        (= (buffer-id (view-buffer view)) target-buffer-id))
      (view-service-views views)))

  (define (assert-view-generations! views buffer-id generation)
    (for-each
      (lambda (view)
        (let ([state (view-state view)])
          (unless (= (view-state-buffer-generation state) generation)
            (assertion-violation
              'dispatcher-dispatch!
              "view observes a stale buffer generation"
              (view-id view)
              (view-state-buffer-generation state)
              generation))))
      (views-for-buffer views buffer-id)))

  (define (dispatcher-dispatch-internal! dispatcher spec)
    (unless (and (dispatcher? dispatcher) (transaction-spec? spec))
      (assertion-violation 'dispatcher-dispatch! "expected a dispatcher and transaction spec"))
    (let* ([buffers (dispatcher-buffers dispatcher)]
           [views (dispatcher-views dispatcher)]
           [buffer (buffer-service-ref buffers (transaction-spec-buffer-id spec) #f)])
      (unless buffer
        (assertion-violation
          'dispatcher-dispatch! "target buffer is not live"
          (transaction-spec-buffer-id spec)))
      (let* ([old-state (buffer-state buffer)]
             [expected (transaction-spec-start-generation spec)])
        (when (and expected (not (= expected (buffer-state-generation old-state))))
          (assertion-violation
            'dispatcher-dispatch! "transaction starts from a stale buffer generation"
            expected (buffer-state-generation old-state)))
        (assert-view-generations!
          views (buffer-id buffer) (buffer-state-generation old-state))
        (let* ([changes (transaction-spec-changes spec)]
               [origin (view-for-origin
                         views (transaction-spec-origin-view-id spec) (buffer-id buffer))]
               [old-view-state (and origin (view-state origin))]
               [prepared (prepare-native-change! (buffer-document buffer) changes)]
               [native (car prepared)]
               [new-snapshot (cdr prepared)]
               [transaction
                (guard
                  (condition
                    [else
                     (when native
                       (guard (condition [else #f])
                         (document-transaction-abort! native)))
                     (raise condition)])
                  (make-transaction
                    old-state old-view-state changes
                    (transaction-spec-selection spec)
                    (transaction-spec-effects spec)
                    (transaction-spec-annotations spec)
                    new-snapshot))]
               [new-buffer-state (transaction-new-buffer-state transaction)]
               [pending-views
                (map
                  (lambda (view)
                    (let* ([current (view-state view)]
                           [selection
                            (if (and origin (= (view-id view) (view-id origin))
                                     (transaction-new-view-state transaction))
                                (view-state-selection (transaction-new-view-state transaction))
                                (selection-map-change
                                  (view-state-selection current) changes))]
                           [new-state
                            (if (and origin (= (view-id view) (view-id origin)))
                                (transaction-new-view-state transaction)
                                (view-state-advance current selection transaction))])
                      (cons view new-state)))
                  (views-for-buffer views (buffer-id buffer)))])
          (when native
            (guard
              (condition
                [else
                 ;; A failed native commit leaves the opaque transaction
                 ;; handle active.  Abort it before propagating so the
                 ;; document can accept a later dispatch.
                 (guard (condition [else #f])
                   (document-transaction-abort! native))
                 (raise condition)])
              (document-transaction-commit! native)))
          (buffer-publish-state! buffer new-buffer-state)
          ;; Compute all immutable view states before entering the publication
          ;; boundary.  A native commit failure therefore cannot leave one
          ;; shared view observing a state that the buffer did not publish.
          (for-each
            (lambda (entry)
              (view-publish-state! (car entry) (cdr entry)))
            pending-views)
          (let ([update
                  (make-editor-update
                    (buffer-id buffer) old-state new-buffer-state
                    (map
                      (lambda (entry)
                        (cons (view-id (car entry)) (cdr entry)))
                      pending-views)
                    changes
                    (transaction-annotations transaction)
                    (if (change-set-empty? changes) '(selection) '(document selection)))])
            (let ([listener (dispatcher-listener dispatcher)])
              (when listener (listener update)))
            (for-each
              (lambda (listener) (listener update))
              (configuration-facet
                (buffer-state-configuration new-buffer-state)
                update-listeners-facet))
            update)))))

  (define (apply-transaction-extension dispatcher spec facet)
    (let ([buffer
            (buffer-service-ref
              (dispatcher-buffers dispatcher)
              (transaction-spec-buffer-id spec) #f)])
      (if (not buffer)
          spec
          (let loop ([extensions
                       (configuration-facet
                         (buffer-state-configuration (buffer-state buffer))
                         facet)]
                     [current spec])
            (if (null? extensions)
                current
                (let ([next ((car extensions) current)])
                  (cond
                    [(not next) #f]
                    [(transaction-spec? next) (loop (cdr extensions) next)]
                    [else
                     (assertion-violation
                       'dispatcher-dispatch! "transaction extension returned an invalid value"
                       next)])))))))

  (define (apply-transaction-filters dispatcher spec)
    (apply-transaction-extension dispatcher spec transaction-filters-facet))

  (define (apply-transaction-extenders dispatcher spec)
    (apply-transaction-extension dispatcher spec transaction-extenders-facet))

  (define (dispatcher-dispatch! dispatcher spec)
    (unless (and (dispatcher? dispatcher) (transaction-spec? spec))
      (assertion-violation 'dispatcher-dispatch! "expected a dispatcher and transaction spec"))
    (let* ([filtered (apply-transaction-filters dispatcher spec)]
           [extended (and filtered (apply-transaction-extenders dispatcher filtered))])
      (and extended (dispatcher-dispatch-internal! dispatcher extended))))
)
