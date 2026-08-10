(library (soda host dispatch buffer-transaction)
  (export dispatch-buffer-transaction! views-for-buffer)
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

  ;; A Buffer transaction maps every View by byte offset first.  Configured
  ;; mappers may then replace that result with a richer semantic position,
  ;; such as a generated item's stable identity.  This keeps one publication
  ;; boundary for the Buffer and all of its Views without teaching Dispatcher
  ;; about individual feature packages.
  (define (apply-view-selection-mappers configuration view old-state transaction selection)
    (let loop ([mappers (configuration-facet configuration view-selection-mappers-facet 'buffer)]
               [current selection])
      (if (null? mappers)
          current
          (let ([next ((car mappers) (view-id view) old-state transaction current)])
            (unless (selection? next)
              (assertion-violation 'dispatcher-dispatch!
                                   "view selection mapper must return a Selection" next))
            (loop (cdr mappers) next)))))

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

  (define (dispatch-buffer-transaction! buffers views resolved)
    (unless (and (buffer-service? buffers) (view-service? views)
                 (resolved-transaction? resolved))
      (assertion-violation
        'dispatcher-dispatch-specs!
        "expected a dispatcher and resolved transaction"))
    (let ([buffer (buffer-service-ref
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
                           [mapped-selection
                            (if (and origin (= (view-id view) (view-id origin))
                                     (transaction-selection transaction))
                                (transaction-selection transaction)
                                (selection-map-change
                                  (view-state-selection current) changes))]
                           [selection
                            (apply-view-selection-mappers
                              (buffer-state-configuration new-buffer-state)
                              view current transaction mapped-selection)]
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
                        (make-view-state-update
                          (view-id (car entry))
                          (cadr entry)
                          (caddr entry)))
                      pending-views)
                    changes
                    (transaction-annotations transaction)
                    (or (resolved-transaction-scroll-request resolved)
                        (and origin (transaction-selection transaction)
                             (make-scroll-request
                               'reveal-point #f #f (view-id origin))))
                    (if (change-set-empty? changes) '(selection) '(document selection)))])
            (cons update (buffer-state-configuration new-buffer-state)))))))))
)

