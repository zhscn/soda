(library (soda host dispatch internal)
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
          dispatcher-dispatch-view-with-host!
          dispatcher-dispatch-host!
          dispatcher-publish-buffer-damage!
          dispatcher-set-error-reporter!
          dispatcher-set-listener!
          dispatcher-set-host-listener!
          dispatcher-add-commit-participant!
          dispatcher-add-listener!
          dispatcher-add-host-listener!
          dispatcher-register-global-operation-handler!)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel extension)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host internal buffer)
          (soda host internal view)
          (soda host internal operation)
          (soda host internal surface)
          (soda host dispatch buffer-transaction)
          (soda host dispatch global-operation)
          (soda host dispatch publication)
          (soda host dispatch surface-operation)
          (soda host dispatch update)
          (soda host dispatch view-transaction)
          (soda view plugin))

  (define-record-type
    (dispatcher %make-dispatcher dispatcher?)
    (fields
      (immutable buffers dispatcher-buffers)
      (immutable views dispatcher-views)
      (immutable surfaces dispatcher-surfaces)
      (immutable publication dispatcher-publication)
      (immutable global-handlers dispatcher-global-handlers)))

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
      buffers views surfaces (make-dispatch-publication listener)
      (make-global-operation-registry))]))

  (define (dispatcher-run! dispatcher thunk)
    (dispatch-publication-run! (dispatcher-publication dispatcher) thunk))

  (define (dispatcher-set-listener! dispatcher listener)
    (dispatch-publication-set-editor-listener!
      (dispatcher-publication dispatcher) listener))

  (define (dispatcher-set-error-reporter! dispatcher reporter)
    (unless (dispatcher? dispatcher)
      (assertion-violation 'dispatcher-set-error-reporter!
                           "expected a dispatcher" dispatcher))
    (dispatch-publication-set-error-reporter!
      (dispatcher-publication dispatcher) reporter))

  (define (dispatcher-set-host-listener! dispatcher listener)
    (unless (dispatcher? dispatcher)
      (assertion-violation 'dispatcher-set-host-listener!
                           "expected a dispatcher" dispatcher))
    (dispatch-publication-set-host-listener!
      (dispatcher-publication dispatcher) listener))

  (define (dispatcher-add-listener! dispatcher owner listener)
    (unless (dispatcher? dispatcher)
      (assertion-violation 'dispatcher-add-listener!
                           "expected a dispatcher" dispatcher))
    (dispatch-publication-add-editor-listener!
      (dispatcher-publication dispatcher) owner listener))

  (define (dispatcher-add-commit-participant! dispatcher owner listener)
    (unless (dispatcher? dispatcher)
      (assertion-violation 'dispatcher-add-commit-participant!
                           "expected a dispatcher" dispatcher))
    (dispatch-publication-add-commit-participant!
      (dispatcher-publication dispatcher) owner listener))

  (define (dispatcher-add-host-listener! dispatcher owner listener)
    (unless (dispatcher? dispatcher)
      (assertion-violation 'dispatcher-add-host-listener!
                           "expected a dispatcher" dispatcher))
    (dispatch-publication-add-host-listener!
      (dispatcher-publication dispatcher) owner listener))

  (define (dispatcher-register-global-operation-handler!
           dispatcher owner kind damage procedure)
    (unless (dispatcher? dispatcher)
      (assertion-violation
        'dispatcher-register-global-operation-handler!
        "expected a Dispatcher" dispatcher))
    (global-operation-register!
      (dispatcher-global-handlers dispatcher) owner kind damage procedure))

  (define (notify-host-update! dispatcher update)
    (dispatch-publication-publish-host!
      (dispatcher-publication dispatcher) update))

  (define (dispatcher-dispatch-host-now! dispatcher operation)
    (unless (and (dispatcher? dispatcher) (host-operation? operation))
      (assertion-violation
        'dispatcher-dispatch-host! "expected a Dispatcher and HostOperation"
        dispatcher operation))
    (let ([update
           (if (host-operation-surface-id operation)
               (let ([surfaces (dispatcher-surfaces dispatcher)])
                 (unless surfaces
                   (assertion-violation
                     'dispatcher-dispatch-host!
                     "Dispatcher has no SurfaceService" dispatcher))
                 (dispatch-surface-operation!
                   surfaces (dispatcher-views dispatcher) operation))
               (global-operation-dispatch
                 (dispatcher-global-handlers dispatcher) operation))])
      (and update (notify-host-update! dispatcher update))))

  (define (dispatcher-dispatch-host! dispatcher operation)
    (unless (and (dispatcher? dispatcher) (host-operation? operation))
      (assertion-violation 'dispatcher-dispatch-host!
                           "expected a Dispatcher and HostOperation"
                           dispatcher operation))
    (dispatcher-run! dispatcher
                     (lambda () (dispatcher-dispatch-host-now! dispatcher operation))))

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

  (define (dispatcher-notify-editor-update! dispatcher update configuration)
    (dispatch-publication-publish-editor!
      (dispatcher-publication dispatcher) update configuration
      (lambda (published-update)
        (notify-view-plugins! dispatcher published-update))))

  ;; Publish non-document state owned by a Host service through the same
  ;; observer and ViewPlugin boundary as an editor transaction.  Buffer and
  ;; View generations remain unchanged because no editor state was mutated.
  (define (dispatcher-publish-buffer-damage! dispatcher buffer-id damage annotations)
    (unless (and (dispatcher? dispatcher)
                 (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)
                 (list? damage) (for-all symbol? damage)
                 (list? annotations))
      (assertion-violation
        'dispatcher-publish-buffer-damage! "invalid Buffer damage publication"
        buffer-id damage annotations))
    (let ([buffer (buffer-service-ref (dispatcher-buffers dispatcher) buffer-id #f)])
      (and buffer
           (let* ([state (buffer-state buffer)]
                  [length (snapshot-byte-size (buffer-state-document state))]
                  [update
                   (make-editor-update
                     buffer-id state state
                     (map
                       (lambda (view)
                         (make-view-state-update
                           (view-id view) (view-state view) (view-state view)))
                       (views-for-buffer (dispatcher-views dispatcher) buffer-id))
                     (make-change-set length '()) annotations #f damage)])
             (dispatcher-notify-editor-update!
               dispatcher update (buffer-state-configuration state))
             update))))

  (define (dispatcher-dispatch-resolved-internal! dispatcher resolved)
    (let ([result
           (dispatch-buffer-transaction!
             (dispatcher-buffers dispatcher)
             (dispatcher-views dispatcher)
             resolved)])
      (dispatcher-notify-editor-update!
        dispatcher (car result) (cdr result))))

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
                (let ([next ((car extensions) (buffer-state buffer) current)])
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

  (define (dispatcher-dispatch-specs-now! dispatcher specs)
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
                  (apply-resolved-transaction-extension
                    dispatcher resolved transaction-filters-facet)]
                 [extended
                  (and filtered
                       (apply-resolved-transaction-extension
                         dispatcher filtered transaction-extenders-facet))])
            (and extended
                 (dispatcher-dispatch-resolved-internal!
                   dispatcher extended))))))

  (define (dispatcher-dispatch-specs! dispatcher specs)
    (unless (and (dispatcher? dispatcher)
                 (list? specs)
                 (for-all transaction-spec? specs))
      (assertion-violation
        'dispatcher-dispatch-specs!
        "expected a dispatcher and a list of transaction specs"))
    (dispatcher-run! dispatcher
                     (lambda () (dispatcher-dispatch-specs-now! dispatcher specs))))

  (define (dispatcher-dispatch! dispatcher spec)
    (unless (and (dispatcher? dispatcher) (transaction-spec? spec))
      (assertion-violation 'dispatcher-dispatch! "expected a dispatcher and transaction spec"))
    (dispatcher-run! dispatcher
                     (lambda () (dispatcher-dispatch-specs-now! dispatcher (list spec)))) )

  (define (dispatcher-dispatch-view-now! dispatcher spec)
    (let ([result
           (dispatch-view-transaction! (dispatcher-views dispatcher) spec)])
      (dispatcher-notify-editor-update!
        dispatcher (car result) (cdr result))))
  (define (dispatcher-dispatch-view! dispatcher spec)
    (unless (and (dispatcher? dispatcher) (view-transaction-spec? spec))
      (assertion-violation
        'dispatcher-dispatch-view!
        "expected a dispatcher and ViewTransactionSpec"))
    (dispatcher-run! dispatcher
                     (lambda () (dispatcher-dispatch-view-now! dispatcher spec))))

  ;; A Location follow must not expose a Window whose View placement and
  ;; selection disagree.  Validate and advance the target View before the
  ;; Surface changes, then publish both updates from one dispatch gate.  A
  ;; rejected View transaction leaves the Window and its previous View intact.
  (define (dispatcher-dispatch-view-with-host-now! dispatcher spec operation)
    (let* ([result
            (dispatch-view-transaction! (dispatcher-views dispatcher) spec)]
           [update (car result)]
           [configuration (cdr result)]
           [state-update (car (editor-update-views update))]
           [view
            (view-service-ref
              (dispatcher-views dispatcher)
              (view-state-update-view-id state-update)
              #f)]
           [surface-update
            (dispatcher-dispatch-host-now! dispatcher operation)])
      (if surface-update
          (begin
            (dispatcher-notify-editor-update! dispatcher update configuration)
            #t)
          (begin
            ;; No observer has seen the staged View state yet, so restoring it
            ;; here leaves both editor and terminal presentation unchanged.
            (when view
              (view-publish-state! view (view-state-update-old-state state-update)))
            #f))))

  (define (dispatcher-dispatch-view-with-host! dispatcher spec operation)
    (unless (and (dispatcher? dispatcher)
                 (view-transaction-spec? spec)
                 (host-operation? operation)
                 (host-operation-surface-id operation))
      (assertion-violation
        'dispatcher-dispatch-view-with-host!
        "expected a Dispatcher, ViewTransactionSpec, and Surface HostOperation"
        dispatcher spec operation))
    (dispatcher-run!
      dispatcher
      (lambda ()
        (dispatcher-dispatch-view-with-host-now! dispatcher spec operation))))
)
