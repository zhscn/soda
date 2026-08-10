(library (soda host dispatch view-transaction)
  (export dispatch-view-transaction!)
  (import (rnrs)
          (soda kernel change core)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host dispatch update)
          (soda host internal buffer)
          (soda host internal view))

  (define (effects-for-view effects origin?)
    (filter
      (lambda (effect) (state-effect-for-view? effect origin?))
      effects))

  (define (selection-within-length? selection length)
    (for-all
      (lambda (range)
        (and (<= (selection-range-anchor range) length)
             (<= (selection-range-head range) length)))
      (selection-ranges selection)))

  (define (dispatch-view-transaction! views spec)
    (unless (and (view-service? views) (view-transaction-spec? spec))
      (assertion-violation
        'dispatcher-dispatch-view!
        "expected a dispatcher and ViewTransactionSpec"))
    (let* ([view
            (view-service-ref
              views
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
                  (list (make-view-state-update
                          (view-id view) old-state new-state))
                  (make-change-set document-length '())
                  (view-transaction-spec-annotations spec)
                  (or (view-transaction-spec-scroll-request spec)
                      (and (view-transaction-spec-selection spec)
                           (not (view-transaction-spec-viewport spec))
                           (make-scroll-request
                             'reveal-point #f #f (view-id view))))
                  damage)])
          (view-publish-state! view new-state)
          (cons update (buffer-state-configuration buffer-state))))))

)
