(library (soda host internal view)
  (export view?
          view-id
          view-owner
          view-buffer
          view-state
          view-plugin-instances
          view-publish-state!
          view-update-plugins!
          view-close!
          make-view-service
          view-service?
          view-service-create!
          view-service-ref
          view-service-views
          view-service-close-view!)
  (import (rnrs)
          (soda kernel selection)
          (soda kernel extension)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel value)
          (soda host internal buffer)
          (soda host input)
          (soda host value)
          (soda view plugin))

  (define-record-type
    (view %make-view view?)
    (fields
      (immutable id view-id)
      (immutable owner view-owner)
      (immutable buffer view-buffer)
      (mutable state view-state view-state-set!)
      (mutable plugins view-plugin-instances view-plugin-instances-set!)
      (mutable closed? view-closed? view-closed?-set!)))

  (define (empty-selection)
    (make-selection (list (make-selection-range 0 0))))

  (define (default-input-stack)
    (make-input-stack (make-input-state 'default '() 'accept)))

  (define (make-view-record identity-source owner buffer configuration input-state)
    (owner-assert-active 'view-service-create! owner)
    (unless (buffer? buffer)
      (assertion-violation 'view-service-create! "expected a buffer" buffer))
    (let ([view
            (%make-view
              (identity-source-next! identity-source)
              owner buffer
              (make-view-state
                (buffer-id buffer)
                (buffer-state-generation (buffer-state buffer))
                (empty-selection) '(0 . 0)
                (or input-state (default-input-stack))
                configuration)
              '()
              #f)])
      (view-plugin-instances-set!
        view
        (map
          (lambda (plugin)
            (unless (view-plugin? plugin)
              (assertion-violation
                'view-service-create! "view plugin facet contains a non-plugin" plugin))
            (make-view-plugin-instance plugin view))
          (configuration-facet configuration view-plugins-facet 'view)))
      (owner-add-cleanup! owner (lambda () (view-close! view)))
      view))

  (define (view-publish-state! view state)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-publish-state! "view is closed" view))
    (unless (view-state? state)
      (assertion-violation 'view-publish-state! "expected a view state" state))
    (view-state-set! view state)
    state)

  (define (view-close! view)
    (unless (view? view)
      (assertion-violation 'view-close! "expected a view" view))
    (if (view-closed? view)
        #f
        (begin
          (for-each
            (lambda (instance)
              (guard (condition [else #f])
                (view-plugin-instance-destroy! instance)))
            (view-plugin-instances view))
          (view-closed?-set! view #t)
          #t)))

  (define (view-update-plugins! view update)
    (unless (and (view? view) (not (view-closed? view)) (view-update? update))
      (assertion-violation
        'view-update-plugins! "expected a live View and ViewUpdate" view update))
    ;; Plugin failures are isolated from the already-published editor update.
    ;; A failing instance is destroyed once and cannot repeatedly fail on later
    ;; render turns.
    (for-each
      (lambda (instance)
        (unless (view-plugin-instance-destroyed? instance)
          (guard
            (condition
              [else
               (guard (ignored [else #f])
                 (view-plugin-instance-destroy! instance))
               #f])
            (view-plugin-instance-update! instance update))))
      (view-plugin-instances view))
    view)

  (define-record-type
    (view-service %make-view-service view-service?)
    (fields (immutable identities view-service-identities)
            (immutable table view-service-table)))

  (define (make-view-service)
    (%make-view-service (make-identity-source) (make-eqv-hashtable)))

  (define (view-service-create! service owner buffer configuration . input-state)
    (unless (view-service? service)
      (assertion-violation 'view-service-create! "expected a view service" service))
    (let ([view (make-view-record
                  (view-service-identities service)
                  owner buffer configuration
                  (if (null? input-state) #f (car input-state)))])
      (hashtable-set! (view-service-table service) (view-id view) view)
      view))

  (define (view-service-ref service id . default)
    (let ([view (hashtable-ref (view-service-table service) id #f)])
      (if (and view (not (view-closed? view)))
          view
          (if (null? default) #f (car default)))))

  (define (view-service-views service)
    (call-with-values
      (lambda () (hashtable-entries (view-service-table service)))
      (lambda (ids values)
        (filter (lambda (view) (not (view-closed? view)))
                (vector->list values)))))

  (define (view-service-close-view! service id)
    (let ([view (view-service-ref service id #f)])
      (and view (view-close! view))))
)
