(library (soda host view)
  (export make-view
          view?
          view-id
          view-owner
          view-buffer
          view-state
          view-generation
          view-publish-state!
          view-close!
          make-view-service
          view-service?
          view-service-create!
          view-service-ref
          view-service-views
          view-service-close-view!)
  (import (rnrs)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel value)
          (soda host buffer)
          (soda host input)
          (soda host value))

  (define-record-type
    (view %make-view view?)
    (fields
      (immutable id view-id)
      (immutable owner view-owner)
      (immutable buffer view-buffer)
      (mutable state view-state view-state-set!)
      (mutable generation view-generation view-generation-set!)
      (mutable closed? view-closed? view-closed?-set!)))

  (define (empty-selection)
    (make-selection (list (make-selection-range 0 0))))

  (define (default-input-stack)
    (make-input-stack (make-input-state 'default '() 'accept)))

  (define (make-view owner buffer configuration . input-state)
    (owner-assert-active 'make-view owner)
    (unless (buffer? buffer)
      (assertion-violation 'make-view "expected a buffer" buffer))
    (let ([view
            (%make-view
              (identity-source-next! view-identities)
              owner buffer
              (make-view-state
                (buffer-id buffer) (empty-selection) '(0 . 0)
                (if (null? input-state) (default-input-stack) (car input-state))
                configuration)
              0 #f)])
      (owner-add-cleanup! owner (lambda () (view-close! view)))
      view))

  (define view-identities (make-identity-source))

  ;; State publication is intentionally only used by the host dispatcher.
  (define (view-publish-state! view state)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-publish-state! "view is closed" view))
    (unless (view-state? state)
      (assertion-violation 'view-publish-state! "expected a view state" state))
    (view-state-set! view state)
    (view-generation-set! view (view-state-generation state))
    state)

  (define (view-close! view)
    (unless (view? view)
      (assertion-violation 'view-close! "expected a view" view))
    (if (view-closed? view)
        #f
        (begin (view-closed?-set! view #t) #t)))

  (define-record-type
    (view-service %make-view-service view-service?)
    (fields (immutable identities view-service-identities)
            (immutable table view-service-table)))

  (define (make-view-service)
    (%make-view-service (make-identity-source) (make-eqv-hashtable)))

  (define (view-service-create! service owner buffer configuration . input-state)
    (let ([view
            (let ([view-identities (view-service-identities service)])
              (owner-assert-active 'view-service-create! owner)
              (%make-view
                (identity-source-next! view-identities)
                owner buffer
                (make-view-state
                  (buffer-id buffer) (empty-selection) '(0 . 0)
                  (if (null? input-state) (default-input-stack) (car input-state))
                  configuration)
                0 #f))])
      (hashtable-set! (view-service-table service) (view-id view) view)
      (owner-add-cleanup! owner (lambda () (view-close! view)))
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
