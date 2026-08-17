(library (soda host internal event)
  (export make-editor-event
          editor-event?
          editor-event-sequence
          editor-event-topic
          editor-event-subject-kind
          editor-event-subject-id
          editor-event-before
          editor-event-after
          editor-event-changes
          editor-event-payload
          editor-event-cause
          event-delivery-active?
          make-event-service
          event-service?
          event-service-subscribe!
          event-service-publish!
          event-service-publish-editor-update!
          event-service-publish-host-update!
          event-service-publish-buffer-closed!
          event-service-publish-view-closed!)
  (import (rnrs)
          (only (chezscheme) make-parameter parameterize)
          (soda host command)
          (soda host command-runtime)
          (soda host condition)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal operation)
          (soda host internal view)
          (soda host runtime)
          (soda host value))

  (define current-event-delivery (make-parameter #f))

  (define (event-delivery-active?) (current-event-delivery))

  ;; Editor events are immutable committed observations.  They carry resource
  ;; identities and immutable state values, never a mutable Host service.
  (define-record-type
    (editor-event %make-editor-event editor-event?)
    (fields (immutable sequence editor-event-sequence)
            (immutable topic editor-event-topic)
            (immutable subject-kind editor-event-subject-kind)
            (immutable subject-id editor-event-subject-id)
            (immutable before editor-event-before)
            (immutable after editor-event-after)
            (immutable changes editor-event-changes)
            (immutable payload editor-event-payload)
            (immutable cause editor-event-cause)))

  (define (make-editor-event sequence topic kind id before after changes payload cause)
    (unless (and (integer? sequence) (exact? sequence) (>= sequence 0)
                 (symbol? topic) (symbol? kind)
                 (or (not id) (and (integer? id) (exact? id) (>= id 0))))
      (assertion-violation 'make-editor-event "invalid editor event identity"
                           sequence topic kind id))
    (%make-editor-event sequence topic kind id before after changes payload cause))

  (define-record-type
    (event-subscription %make-event-subscription event-subscription?)
    (fields owner topic selector procedure))

  (define-record-type
    (event-service %make-event-service event-service?)
    (fields runtime conditions
            (mutable next-sequence event-service-next-sequence
                     event-service-next-sequence-set!)
            (mutable subscriptions event-service-subscriptions
                     event-service-subscriptions-set!)
            (mutable pending event-service-pending event-service-pending-set!)
            (mutable scheduled? event-service-scheduled? event-service-scheduled?-set!)))

  (define (make-event-service runtime conditions)
    (unless (and (runtime? runtime) (condition-service? conditions))
      (assertion-violation 'make-event-service
                           "expected a Runtime and ConditionService"
                           runtime conditions))
    (%make-event-service runtime conditions 0 '() '() #f))

  (define (event-service-subscribe! service owner topic selector procedure)
    (unless (and (event-service? service) (owner? owner) (symbol? topic)
                 (or (not selector) (procedure? selector))
                 (procedure? procedure))
      (assertion-violation 'event-service-subscribe!
                           "invalid event subscription" service owner topic selector procedure))
    (owner-assert-active 'event-service-subscribe! owner)
    (let ([entry (%make-event-subscription owner topic selector procedure)])
      (event-service-subscriptions-set!
        service (append (event-service-subscriptions service) (list entry)))
      (make-registration
        owner
        (lambda ()
          (event-service-subscriptions-set!
            service
            (filter (lambda (item) (not (eq? item entry)))
                    (event-service-subscriptions service)))))))

  (define (capture-event-condition! service entry event condition)
    (when (owner-active? (event-subscription-owner entry))
      (condition-service-capture
        (event-service-conditions service) (event-subscription-owner entry)
        (list 'event (editor-event-topic event) condition)
        (lambda arguments #f) '(dismiss))))

  (define (deliver-event! service event)
    ;; The Runtime invokes this only after the originating Dispatcher or
    ;; command boundary has returned.  A subscriber may enqueue later work,
    ;; but cannot reenter the transaction that produced this observation.
    (for-each
      (lambda (entry)
        (when (and (owner-active? (event-subscription-owner entry))
                   (eq? (event-subscription-topic entry) (editor-event-topic event)))
          (guard
            (condition
              [else (capture-event-condition! service entry event condition)])
            (when (or (not (event-subscription-selector entry))
                      ((event-subscription-selector entry) event))
              ((event-subscription-procedure entry) event)))))
      (event-service-subscriptions service))
    event)

  (define (deliver-pending-events! service)
    ;; One Runtime item drains a committed batch in sequence order.  Commands
    ;; enqueued by an observer therefore run only after its sibling Buffer,
    ;; View, and Surface observations have all been delivered.
    (let ([events (event-service-pending service)])
      (event-service-pending-set! service '())
      (event-service-scheduled?-set! service #f)
      (parameterize ([current-event-delivery #t])
        (for-each (lambda (event) (deliver-event! service event)) events)))
    #t)

  (define event-service-publish!
    (case-lambda
      [(service topic kind id before after changes cause)
       (event-service-publish! service topic kind id before after changes #f cause)]
      [(service topic kind id before after changes payload cause)
       (unless (and (event-service? service) (symbol? topic) (symbol? kind))
         (assertion-violation 'event-service-publish! "invalid event publication"
                              service topic kind))
       (let ([event
              (make-editor-event (+ 1 (event-service-next-sequence service))
                                 topic kind id before after changes payload cause)])
         (event-service-next-sequence-set! service (editor-event-sequence event))
         (event-service-pending-set!
           service (append (event-service-pending service) (list event)))
         (unless (event-service-scheduled? service)
           (event-service-scheduled?-set! service #t)
           (runtime-enqueue-after-current!
             (event-service-runtime service)
             (lambda () (deliver-pending-events! service))))
         event)]))

  (define (event-service-publish-editor-update! service update)
    (event-service-publish!
      service 'buffer/changed 'buffer (editor-update-buffer-id update)
      (editor-update-old-buffer-state update)
      (editor-update-new-buffer-state update)
      (editor-update-changes update) update 'dispatcher)
    (for-each
      (lambda (view-update)
        (event-service-publish!
          service 'view/changed 'view (view-state-update-view-id view-update)
          (view-state-update-old-state view-update)
          (view-state-update-new-state view-update)
          (editor-update-changes update) view-update 'dispatcher))
      (editor-update-views update))
    update)

  (define (event-service-publish-host-update! service update)
    (event-service-publish!
      service 'surface/changed 'surface (host-update-surface-id update)
      (host-update-old-context update) (host-update-new-context update)
      (host-update-damage update) update (host-operation-kind (host-update-operation update))))

  (define (event-service-publish-buffer-closed! service buffer)
    (event-service-publish!
      service 'buffer/closed 'buffer (buffer-id buffer)
      (buffer-state buffer) #f #f 'lifecycle))

  (define (event-service-publish-view-closed! service view)
    (event-service-publish!
      service 'view/closed 'view (view-id view)
      (view-state view) #f #f 'lifecycle))
)
