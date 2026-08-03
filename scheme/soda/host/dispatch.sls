(library (soda host dispatch)
  (export make-editor-update
          editor-update?
          editor-update-buffer-id
          editor-update-old-buffer-state
          editor-update-new-buffer-state
          editor-update-views
          editor-update-changes
          editor-update-annotations
          editor-update-scroll-request
          editor-update-damage
          view-state-update?
          view-state-update-view-id
          view-state-update-old-state
          view-state-update-new-state
          make-dispatcher
          dispatcher?
          dispatcher-dispatch!
          dispatcher-dispatch-specs!
          dispatcher-dispatch-view!
          dispatcher-dispatch-host!
          dispatcher-set-listener!
          dispatcher-set-host-listener!)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel extension)
          (soda kernel state)
          (soda kernel view-state)
          (soda host internal buffer)
          (soda host internal view)
          (soda host context)
          (soda host internal operation)
          (soda host surface)
          (soda host value)
          (soda view plugin))

  (define-record-type
    (view-state-update %make-view-state-update view-state-update?)
    (fields
      (immutable view-id view-state-update-view-id)
      (immutable old-state view-state-update-old-state)
      (immutable new-state view-state-update-new-state)))

  (define-record-type
    (editor-update %make-editor-update editor-update?)
    (fields
      (immutable buffer-id editor-update-buffer-id)
      (immutable old-buffer-state editor-update-old-buffer-state)
      (immutable new-buffer-state editor-update-new-buffer-state)
      (immutable views editor-update-views)
      (immutable changes editor-update-changes)
      (immutable annotations editor-update-annotations)
      (immutable scroll-request editor-update-scroll-request)
      (immutable damage editor-update-damage)))

  (define (make-editor-update buffer-id old-state new-state views changes annotations
                              scroll-request damage)
    (%make-editor-update
      buffer-id old-state new-state (list-copy views) changes
      (list-copy annotations) scroll-request (list-copy damage)))

  (define-record-type
    (dispatcher %make-dispatcher dispatcher?)
    (fields
      (immutable buffers dispatcher-buffers)
      (immutable views dispatcher-views)
      (immutable surfaces dispatcher-surfaces)
      (mutable listener dispatcher-listener dispatcher-listener-set!)
      (mutable host-listener dispatcher-host-listener dispatcher-host-listener-set!)))

  (define make-dispatcher
    (case-lambda
      [(buffers views)
       (make-dispatcher buffers views #f #f)]
      [(buffers views third)
       (if (surface-service? third)
           (make-dispatcher buffers views third #f)
           (make-dispatcher buffers views #f third))]
      [(buffers views surfaces listener)
    (unless (and (buffer-service? buffers) (view-service? views))
      (assertion-violation 'make-dispatcher "expected buffer and view services"))
    (unless (or (not surfaces) (surface-service? surfaces))
      (assertion-violation 'make-dispatcher "expected a SurfaceService or #f" surfaces))
    (unless (or (not listener) (procedure? listener))
      (assertion-violation 'make-dispatcher "expected a listener or #f" listener))
    (%make-dispatcher
      buffers views surfaces listener #f)]))

  (define (dispatcher-set-listener! dispatcher listener)
    (unless (or (not listener) (procedure? listener))
      (assertion-violation 'dispatcher-set-listener! "listener must be a procedure" listener))
    (dispatcher-listener-set! dispatcher listener)
    listener)

  (define (dispatcher-set-host-listener! dispatcher listener)
    (unless (or (not listener) (procedure? listener))
      (assertion-violation 'dispatcher-set-host-listener!
                           "expected a listener or #f" listener))
    (dispatcher-host-listener-set! dispatcher listener)
    listener)

  (define (dispatcher-dispatch-host! dispatcher operation)
    (unless (and (dispatcher? dispatcher) (host-operation? operation))
      (assertion-violation 'dispatcher-dispatch-host!
                           "expected a Dispatcher and HostOperation"
                           dispatcher operation))
    (let ([surfaces (dispatcher-surfaces dispatcher)])
      (unless surfaces
        (assertion-violation 'dispatcher-dispatch-host!
                             "Dispatcher has no SurfaceService" dispatcher))
      (let ([surface
             (surface-service-ref surfaces (host-operation-surface-id operation) #f)])
        (and surface
             (let* ([start-generation (surface-generation surface)]
                    [old-context (surface-active-context surface (dispatcher-views dispatcher))]
                    [resolution
                     (case (host-operation-kind operation)
                       [(focus-view)
                        (surface-select-view! surface (dispatcher-views dispatcher)
                                              (host-operation-value operation))]
                       [(split-view)
                        (let ([value (host-operation-value operation)])
                          (surface-split-view! surface (dispatcher-views dispatcher)
                                               (car value) (cadr value) (caddr value)))]
                       [(remove-window)
                        (surface-remove-view-window! surface (dispatcher-views dispatcher)
                                                     (host-operation-value operation))]
                       [(push-interaction)
                        (let ([value (host-operation-value operation)])
                          (surface-push-interaction-view!
                            surface (dispatcher-views dispatcher) (car value) (cadr value)))]
                       [(pop-interaction)
                        (surface-pop-interaction-view! surface (dispatcher-views dispatcher))]
                       [(display-request)
                        (surface-route-display-request!
                          surface (dispatcher-views dispatcher)
                          (host-operation-value operation))]
                       [else
                        (assertion-violation 'dispatcher-dispatch-host!
                                             "unsupported HostOperation" operation)])]
                    [new-context (surface-active-context surface (dispatcher-views dispatcher))])
               (and resolution
                    (let ([update
                           (make-host-update
                             operation (surface-id surface) old-context new-context resolution
                             (if (= start-generation (surface-generation surface))
                                 '()
                                 '(chrome)))])
                      (let ([listener (dispatcher-host-listener dispatcher)])
                        (when listener (listener update)))
                      update)))))))

  (define (notify-view-plugins! dispatcher update)
    (for-each
      (lambda (state-update)
        (let ([view
                (view-service-ref
                  (dispatcher-views dispatcher)
                  (view-state-update-view-id state-update)
                  #f)])
          (when view
            (view-update-plugins!
              view
              (make-view-update
                (view-id view)
                (view-state-update-old-state state-update)
                (view-state-update-new-state state-update)
                update
                (editor-update-damage update))))))
      (editor-update-views update))
    update)

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

  (define (effects-for-view effects origin?)
    (filter
      (lambda (effect) (state-effect-for-view? effect origin?))
      effects))

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

  (define (dispatcher-dispatch-resolved-internal! dispatcher resolved)
    (unless (and (dispatcher? dispatcher)
                 (resolved-transaction? resolved))
      (assertion-violation
        'dispatcher-dispatch-specs!
        "expected a dispatcher and resolved transaction"))
    (let* ([buffers (dispatcher-buffers dispatcher)]
           [views (dispatcher-views dispatcher)]
           [buffer (buffer-service-ref
                     buffers
                     (resolved-transaction-buffer-id resolved)
                     #f)])
      (unless buffer
        (assertion-violation
          'dispatcher-dispatch-specs! "target buffer is not live"
          (resolved-transaction-buffer-id resolved)))
      (let* ([old-state (buffer-state buffer)]
             [expected (resolved-transaction-start-generation resolved)])
        (unless (= expected (buffer-state-generation old-state))
          (assertion-violation
            'dispatcher-dispatch-specs!
            "transaction starts from a stale buffer generation"
            expected (buffer-state-generation old-state)))
        (assert-view-generations!
          views (buffer-id buffer) (buffer-state-generation old-state))
        (let ([native #f]
              [new-snapshot #f]
              [published? #f])
          (guard
            (condition
              [else
               (unless published?
                 (when new-snapshot
                   (guard (ignored [else #f])
                     (snapshot-close! new-snapshot)))
                 (when native
                   (guard (ignored [else #f])
                     (document-transaction-abort! native))))
               (raise condition)])
          (let* ([changes (resolved-transaction-changes resolved)]
               [origin (view-for-origin
                         views
                         (resolved-transaction-origin-view-id resolved)
                         (buffer-id buffer))]
               [document-length
                (snapshot-byte-size (buffer-state-document old-state))]
               [_validated-length
                (unless (= document-length (change-set-old-length changes))
                  (assertion-violation
                    'dispatcher-dispatch-specs!
                    "change set does not match the current document length"
                    (change-set-old-length changes)
                    document-length))]
               [prepared (prepare-native-change! (buffer-document buffer) changes)]
               [_native (set! native (car prepared))]
               [_snapshot (set! new-snapshot (cdr prepared))]
               [transaction
                (make-transaction-from-resolved
                  old-state resolved new-snapshot)]
               [new-buffer-state (transaction-new-buffer-state transaction)]
               [pending-views
                (map
                  (lambda (view)
                    (let* ([current (view-state view)]
                           [selection
                            (if (and origin (= (view-id view) (view-id origin))
                                     (transaction-selection transaction))
                                (transaction-selection transaction)
                                (selection-map-change
                                  (view-state-selection current) changes))]
                           [origin?
                            (and origin (= (view-id view) (view-id origin)))]
                           [new-state
                            (view-state-advance
                              current
                              (make-view-update-context
                                (view-id view) (and origin? #t)
                                transaction current selection
                                (view-state-viewport current)
                                (view-state-input-state current)
                                (effects-for-view
                                  (transaction-effects transaction)
                                  (and origin? #t))
                                (transaction-annotations transaction)))])
                      (list view current new-state)))
                  (views-for-buffer views (buffer-id buffer)))])
          (when native
            (let ([change (document-transaction-commit! native)])
              (change-close! change)))
          (buffer-publish-state! buffer new-buffer-state)
          ;; Compute all immutable view states before entering the publication
          ;; boundary.  A native commit failure therefore cannot leave one
          ;; shared view observing a state that the buffer did not publish.
          (for-each
            (lambda (entry)
              (view-publish-state! (car entry) (caddr entry)))
            pending-views)
          (set! published? #t)
          (let ([update
                  (make-editor-update
                    (buffer-id buffer) old-state new-buffer-state
                    (map
                      (lambda (entry)
                        (%make-view-state-update
                          (view-id (car entry))
                          (cadr entry)
                          (caddr entry)))
                      pending-views)
                    changes
                    (transaction-annotations transaction)
                    (resolved-transaction-scroll-request resolved)
                    (if (change-set-empty? changes) '(selection) '(document selection)))])
            (notify-view-plugins! dispatcher update)
            (let ([listener (dispatcher-listener dispatcher)])
              (when listener (listener update)))
            (for-each
              (lambda (listener) (listener update))
              (configuration-facet
                (buffer-state-configuration new-buffer-state)
                update-listeners-facet
                'buffer))
            update)))))))

  (define (apply-resolved-transaction-extension dispatcher resolved facet)
    (let ([buffer
            (buffer-service-ref
              (dispatcher-buffers dispatcher)
              (resolved-transaction-buffer-id resolved) #f)])
      (if (not buffer)
          resolved
          (let loop ([extensions
                       (configuration-facet
                         (buffer-state-configuration (buffer-state buffer))
                         facet
                         'buffer)]
                     [current resolved])
            (if (null? extensions)
                current
                (let ([next ((car extensions) current)])
                  (cond
                    [(not next) #f]
                    [(resolved-transaction? next)
                     (unless
                       (and
                         (equal? (resolved-transaction-buffer-id next)
                                 (resolved-transaction-buffer-id current))
                         (equal? (resolved-transaction-origin-view-id next)
                                 (resolved-transaction-origin-view-id current))
                         (= (resolved-transaction-start-generation next)
                            (resolved-transaction-start-generation current))
                         (= (change-set-old-length
                              (resolved-transaction-changes next))
                            (change-set-old-length
                              (resolved-transaction-changes current))))
                       (assertion-violation
                         'dispatcher-dispatch!
                         "transaction extensions cannot retarget their baseline"
                         current next))
                     (loop (cdr extensions) next)]
                    [else
                     (assertion-violation
                       'dispatcher-dispatch!
                       "transaction extension returned an invalid value"
                       next)])))))))

  (define (dispatcher-dispatch-specs! dispatcher specs)
    (unless (and (dispatcher? dispatcher)
                 (list? specs)
                 (for-all transaction-spec? specs))
      (assertion-violation
        'dispatcher-dispatch-specs!
        "expected a dispatcher and a list of transaction specs"))
    (if (null? specs)
        #f
        (let* ([first (car specs)]
               [buffer
                (buffer-service-ref
                  (dispatcher-buffers dispatcher)
                  (transaction-spec-buffer-id first)
                  #f)])
          (unless buffer
            (assertion-violation
              'dispatcher-dispatch-specs!
              "target buffer is not live"
              (transaction-spec-buffer-id first)))
          (let* ([old-length
                  (snapshot-byte-size
                    (buffer-state-document (buffer-state buffer)))]
                 [resolved (resolve-transaction-specs specs old-length)]
                 [filtered
                  (if (resolved-transaction-filter-disabled? resolved)
                      resolved
                      (apply-resolved-transaction-extension
                        dispatcher resolved transaction-filters-facet))]
                 [extended
                  (and filtered
                       (apply-resolved-transaction-extension
                         dispatcher filtered transaction-extenders-facet))])
            (and extended
                 (dispatcher-dispatch-resolved-internal!
                   dispatcher extended))))))

  (define (dispatcher-dispatch! dispatcher spec)
    (unless (and (dispatcher? dispatcher) (transaction-spec? spec))
      (assertion-violation 'dispatcher-dispatch! "expected a dispatcher and transaction spec"))
    (dispatcher-dispatch-specs! dispatcher (list spec)))

  (define (selection-within-length? selection length)
    (for-all
      (lambda (range)
        (and (<= (selection-range-anchor range) length)
             (<= (selection-range-head range) length)))
      (selection-ranges selection)))

  (define (dispatcher-dispatch-view! dispatcher spec)
    (unless (and (dispatcher? dispatcher) (view-transaction-spec? spec))
      (assertion-violation
        'dispatcher-dispatch-view!
        "expected a dispatcher and ViewTransactionSpec"))
    (let* ([view
            (view-service-ref
              (dispatcher-views dispatcher)
              (view-transaction-spec-view-id spec)
              #f)])
      (unless view
        (assertion-violation
          'dispatcher-dispatch-view! "target view is not live"
          (view-transaction-spec-view-id spec)))
      (let* ([buffer (view-buffer view)]
             [buffer-state (buffer-state buffer)]
             [old-state (view-state view)]
             [expected (view-transaction-spec-start-generation spec)])
        (unless (= expected (view-state-generation old-state))
          (assertion-violation
            'dispatcher-dispatch-view!
            "transaction starts from a stale view generation"
            expected (view-state-generation old-state)))
        (unless (= (view-state-buffer-generation old-state)
                   (buffer-state-generation buffer-state))
          (assertion-violation
            'dispatcher-dispatch-view!
            "view observes a stale buffer generation"
            (view-id view)))
        (let* ([selection
                (or (view-transaction-spec-selection spec)
                    (view-state-selection old-state))]
               [document-length
                (snapshot-byte-size (buffer-state-document buffer-state))]
               [_selection-valid
                (unless (selection-within-length? selection document-length)
                  (assertion-violation
                    'dispatcher-dispatch-view!
                    "selection is outside the current document"
                    selection document-length))]
               [effects
                (effects-for-view
                  (view-transaction-spec-effects spec) #t)]
               [_targets-valid
                (unless (= (length effects)
                           (length (view-transaction-spec-effects spec)))
                  (assertion-violation
                    'dispatcher-dispatch-view!
                    "view transaction contains a buffer-targeted effect"
                    (view-transaction-spec-effects spec)))]
               [context
                (make-view-update-context
                  (view-id view) #t #f old-state selection
                  (or (view-transaction-spec-viewport spec)
                      (view-state-viewport old-state))
                  (or (view-transaction-spec-input-state spec)
                      (view-state-input-state old-state))
                  effects
                  (view-transaction-spec-annotations spec))]
               [new-state (view-state-advance old-state context)]
               [damage
                (append
                  (if (view-transaction-spec-selection spec) '(selection) '())
                  (if (view-transaction-spec-viewport spec) '(viewport) '())
                  (if (view-transaction-spec-input-state spec) '(input) '())
                  (if (pair? effects) '(configuration) '()))]
               [update
                (make-editor-update
                  (buffer-id buffer) buffer-state buffer-state
                  (list (%make-view-state-update
                          (view-id view) old-state new-state))
                  (make-change-set document-length '())
                  (view-transaction-spec-annotations spec)
                  (view-transaction-spec-scroll-request spec)
                  damage)])
          (view-publish-state! view new-state)
          (notify-view-plugins! dispatcher update)
          (let ([listener (dispatcher-listener dispatcher)])
            (when listener (listener update)))
          (for-each
            (lambda (listener) (listener update))
            (configuration-facet
              (buffer-state-configuration buffer-state)
              update-listeners-facet
              'buffer))
          update))))
)
