(library (soda host internal state-slot)
  (export make-state-slot
          state-slot?
          state-slot-id
          state-slot-scope
          state-slot-stale
          state-slot-stale?
          make-state-slot-service
          state-slot-service?
          state-slot-service-register!
          state-slot-service-ref
          state-slot-service-set!
          state-slot-service-initialize-buffer!
          state-slot-service-discard-buffer!
          state-slot-service-discard-view!
          state-slot-service-discard-surface!
          state-slot-service-apply-editor-update!)
  (import (rnrs)
          (soda kernel change)
          (soda host condition)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal surface)
          (soda host internal view)
          (soda host value))

  ;; A StateSlot is package-private state whose lifetime is owned by Host.
  ;; The initial and map procedures must return immutable-by-contract values.
  ;; map receives value, ChangeDesc, old BufferState, and new BufferState.
  (define-record-type
    (state-slot %make-state-slot state-slot?)
    (fields (immutable id state-slot-id)
            (immutable scope state-slot-scope)
            (immutable initial state-slot-initial)
            (immutable map-change state-slot-map-change)))

  (define-record-type
    (state-slot-stale-value %make-state-slot-stale state-slot-stale?)
    (fields))

  (define state-slot-stale (%make-state-slot-stale))

  (define (make-state-slot id scope initial map-change)
    (unless (and (symbol? id) (memq scope '(buffer view surface))
                 (procedure? initial) (procedure? map-change))
      (assertion-violation 'make-state-slot
                           "expected an id, resource scope, initial, and mapper"
                           id scope initial map-change))
    (%make-state-slot id scope initial map-change))

  (define-record-type
    (state-slot-entry %make-state-slot-entry state-slot-entry?)
    (fields owner slot values))

  (define-record-type
    (state-slot-service %make-state-slot-service state-slot-service?)
    (fields buffers views surfaces conditions
            (immutable entries state-slot-service-entries)))

  (define (slot-token owner slot)
    (cons (owner-id owner) (state-slot-id slot)))

  (define (make-state-slot-service buffers views surfaces conditions)
    (unless (and (buffer-service? buffers) (view-service? views)
                 (surface-service? surfaces) (condition-service? conditions))
      (assertion-violation 'make-state-slot-service
                           "expected resource services and a ConditionService"
                           buffers views surfaces conditions))
    (%make-state-slot-service
      buffers views surfaces conditions (make-hashtable equal-hash equal?)))

  (define (entry-for service owner slot who)
    (unless (and (state-slot-service? service) (owner? owner) (state-slot? slot))
      (assertion-violation who "invalid StateSlot request" service owner slot))
    (owner-assert-active who owner)
    (let ([entry (hashtable-ref (state-slot-service-entries service)
                                (slot-token owner slot) #f)])
      (unless (and entry (eq? (state-slot-entry-owner entry) owner)
                   (eq? (state-slot-entry-slot entry) slot))
        (assertion-violation who "StateSlot is not owned by this Owner" slot))
      entry))

  (define (capture-slot-condition! service entry phase condition)
    (when (owner-active? (state-slot-entry-owner entry))
      (condition-service-capture
        (state-slot-service-conditions service) (state-slot-entry-owner entry)
        (list 'state-slot (state-slot-id (state-slot-entry-slot entry)) phase condition)
        (lambda arguments #f) '(dismiss))))

  (define (initialize-entry-buffer! service entry buffer)
    (let* ([slot (state-slot-entry-slot entry)]
           [values (state-slot-entry-values entry)]
           [id (buffer-id buffer)])
      (unless (hashtable-contains? values id)
        (guard
          (condition
            [else
             (capture-slot-condition! service entry 'initial condition)
             (hashtable-set! values id state-slot-stale)])
          (hashtable-set!
            values id ((state-slot-initial slot) id (buffer-state buffer)))))))

  (define (initialize-entry-view! service entry view)
    (let* ([slot (state-slot-entry-slot entry)]
           [values (state-slot-entry-values entry)]
           [id (view-id view)])
      (unless (hashtable-contains? values id)
        (guard
          (condition
            [else
             (capture-slot-condition! service entry 'initial condition)
             (hashtable-set! values id state-slot-stale)])
          (hashtable-set! values id ((state-slot-initial slot) id (view-state view)))))))

  ;; Surface has no immutable state record yet.  Its stable identity is the
  ;; only initialization input; packages must observe subsequent layout state
  ;; through surface/changed events rather than retaining the Surface object.
  (define (initialize-entry-surface! service entry surface)
    (let* ([slot (state-slot-entry-slot entry)]
           [values (state-slot-entry-values entry)]
           [id (surface-id surface)])
      (unless (hashtable-contains? values id)
        (guard
          (condition
            [else
             (capture-slot-condition! service entry 'initial condition)
             (hashtable-set! values id state-slot-stale)])
          (hashtable-set! values id ((state-slot-initial slot) id #f))))))

  (define (initialize-entry-resource! service entry id who)
    (case (state-slot-scope (state-slot-entry-slot entry))
      [(buffer)
       (let ([buffer (buffer-service-ref (state-slot-service-buffers service) id #f)])
         (unless buffer (assertion-violation who "target Buffer is not live" id))
         (initialize-entry-buffer! service entry buffer))]
      [(view)
       (let ([view (view-service-ref (state-slot-service-views service) id #f)])
         (unless view (assertion-violation who "target View is not live" id))
         (initialize-entry-view! service entry view))]
      [(surface)
       (let ([surface (surface-service-ref (state-slot-service-surfaces service) id #f)])
         (unless surface (assertion-violation who "target Surface is not live" id))
         (initialize-entry-surface! service entry surface))]
      [else (assertion-violation who "unsupported StateSlot scope")]))

  (define (state-slot-service-initialize-buffer! service buffer)
    (unless (and (state-slot-service? service) (buffer? buffer))
      (assertion-violation 'state-slot-service-initialize-buffer!
                           "expected a StateSlotService and Buffer" service buffer))
    (let-values ([(keys entries) (hashtable-entries (state-slot-service-entries service))])
      (for-each
        (lambda (entry) (initialize-entry-buffer! service entry buffer))
        (vector->list entries)))
    buffer)

  (define (state-slot-service-discard-buffer! service buffer)
    (unless (and (state-slot-service? service) (buffer? buffer))
      (assertion-violation 'state-slot-service-discard-buffer!
                           "expected a StateSlotService and Buffer" service buffer))
    (let-values ([(keys entries) (hashtable-entries (state-slot-service-entries service))])
      (for-each
        (lambda (entry)
          (hashtable-delete! (state-slot-entry-values entry) (buffer-id buffer)))
        (vector->list entries)))
    #t)

  (define (discard-resource! service scope id)
    (let-values ([(keys entries) (hashtable-entries (state-slot-service-entries service))])
      (for-each
        (lambda (entry)
          (when (eq? (state-slot-scope (state-slot-entry-slot entry)) scope)
            (hashtable-delete! (state-slot-entry-values entry) id)))
        (vector->list entries)))
    #t)

  (define (state-slot-service-discard-view! service view)
    (unless (and (state-slot-service? service) (view? view))
      (assertion-violation 'state-slot-service-discard-view!
                           "expected a StateSlotService and View" service view))
    (discard-resource! service 'view (view-id view)))

  (define (state-slot-service-discard-surface! service surface)
    (unless (and (state-slot-service? service) (surface? surface))
      (assertion-violation 'state-slot-service-discard-surface!
                           "expected a StateSlotService and Surface" service surface))
    (discard-resource! service 'surface (surface-id surface)))

  (define (state-slot-service-register! service owner slot)
    (unless (and (state-slot-service? service) (owner? owner) (state-slot? slot))
      (assertion-violation 'state-slot-service-register!
                           "expected a StateSlotService, Owner, and StateSlot"
                           service owner slot))
    (owner-assert-active 'state-slot-service-register! owner)
    (let* ([token (slot-token owner slot)]
           [table (state-slot-service-entries service)])
      (when (hashtable-ref table token #f)
        (assertion-violation 'state-slot-service-register!
                             "StateSlot id is already registered by Owner"
                             (state-slot-id slot)))
      (let ([entry (%make-state-slot-entry owner slot (make-eqv-hashtable))])
        (hashtable-set! table token entry)
        (when (eq? (state-slot-scope slot) 'buffer)
          (for-each
            (lambda (buffer) (initialize-entry-buffer! service entry buffer))
            (buffer-service-buffers (state-slot-service-buffers service))))
        (owner-add-cleanup!
          owner
          (lambda ()
            (when (eq? (hashtable-ref table token #f) entry)
              (hashtable-delete! table token))))
        slot)))

  (define state-slot-service-ref
    (case-lambda
      [(service owner slot buffer-id)
       (state-slot-service-ref service owner slot buffer-id #f)]
      [(service owner slot buffer-id default)
       (let ([entry (entry-for service owner slot 'state-slot-service-ref)])
         (initialize-entry-resource! service entry buffer-id 'state-slot-service-ref)
         (hashtable-ref (state-slot-entry-values entry) buffer-id default))]))

  (define (state-slot-service-set! service owner slot buffer-id value)
    (let ([entry (entry-for service owner slot 'state-slot-service-set!)])
      (initialize-entry-resource! service entry buffer-id 'state-slot-service-set!)
      (hashtable-set! (state-slot-entry-values entry) buffer-id value)
      value))

  (define (state-slot-service-apply-editor-update! service update)
    (unless (and (state-slot-service? service) (editor-update? update))
      (assertion-violation 'state-slot-service-apply-editor-update!
                           "expected a StateSlotService and EditorUpdate" service update))
    (let ([id (editor-update-buffer-id update)])
      (let-values ([(keys entries) (hashtable-entries (state-slot-service-entries service))])
        (for-each
          (lambda (entry)
            (let ([values (state-slot-entry-values entry)])
              (when (and (eq? (state-slot-scope (state-slot-entry-slot entry)) 'buffer)
                         (hashtable-contains? values id)
                         (not (change-set-empty? (editor-update-changes update))))
                (guard
                  (condition
                    [else
                     (capture-slot-condition! service entry 'map condition)
                     (hashtable-set! values id state-slot-stale)])
                  (hashtable-set!
                    values id
                    ((state-slot-map-change (state-slot-entry-slot entry))
                     (hashtable-ref values id state-slot-stale)
                     (editor-update-changes update)
                     (editor-update-old-buffer-state update)
                     (editor-update-new-buffer-state update)))))))
          (vector->list entries))))
    update)
)
