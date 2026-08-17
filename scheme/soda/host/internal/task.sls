(library (soda host internal task)
  (export make-task-service
          task-service?
          task-service-start!
          task-service-cancel-buffer!
          task-service-cancel-view!
          task-service-cancel-surface!
          task-service-handle-message!)
  (import (rnrs)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host command-message)
          (soda host command-runtime)
          (soda host condition)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal context)
          (soda host internal surface)
          (soda host internal view)
          (soda host runtime)
          (soda host task)
          (soda host value))

  ;; Task events are the only values an external callback may put into the
  ;; host Runtime.  The callback cannot directly call a package command or
  ;; Dispatcher operation, keeping all editor work at a command boundary.
  (define-record-type
    (task-message %make-task-message task-message?)
    (fields (immutable id task-message-id)
            (immutable kind task-message-kind)
            (immutable value task-message-value)))

  (define-record-type
    (task-entry %make-task-entry task-entry?)
    (fields id owner name scope origin command arguments handle
            (mutable cancel task-entry-cancel task-entry-cancel-set!)))

  (define-record-type
    (task-service %make-task-service task-service?)
    (fields runtime commands conditions buffers views surfaces
            (mutable next-id task-service-next-id task-service-next-id-set!)
            (immutable entries task-service-entries)))

  (define (make-task-service owner runtime commands conditions buffers views surfaces dispatcher)
    (unless (and (owner? owner) (runtime? runtime) (command-runtime? commands)
                 (condition-service? conditions) (buffer-service? buffers)
                 (view-service? views) (surface-service? surfaces)
                 (dispatcher? dispatcher))
      (assertion-violation 'make-task-service "invalid host task dependencies"))
    (let ([service
           (%make-task-service runtime commands conditions buffers views surfaces 0
                               (make-eqv-hashtable))])
      (buffer-service-add-close-listener!
        buffers owner
        (lambda (buffer)
          (task-service-cancel-buffer! service (buffer-id buffer))))
      (view-service-add-close-listener!
        views owner
        (lambda (view)
          (task-service-cancel-view! service (view-id view))))
      (dispatcher-add-listener!
        dispatcher owner
        (lambda (update)
          (task-service-cancel-stale-buffer!
            service (editor-update-buffer-id update))))
      service))

  (define (task-entry-ref service id)
    (hashtable-ref (task-service-entries service) id #f))

  (define (capture-task-condition! service entry phase condition)
    (when (owner-active? (task-entry-owner entry))
      (condition-service-capture
        (task-service-conditions service) (task-entry-owner entry)
        (list 'task (task-entry-name entry) phase condition)
        (lambda arguments #f) '(dismiss))))

  (define (retire-task! service entry cancel?)
    (when (and (task-entry? entry)
               (eq? (task-entry-ref service (task-entry-id entry)) entry))
      (hashtable-delete! (task-service-entries service) (task-entry-id entry))
      (let ([handle (task-entry-handle entry)])
        (when (task-handle-active? handle)
          (task-handle-retire! handle)))
      (let ([cancel (task-entry-cancel entry)])
        (when (and cancel? cancel)
          (guard
            (condition
              [else (capture-task-condition! service entry 'cancel condition)])
            (cancel))))
      #t))

  (define (task-service-cancel-where! service predicate)
    (let-values ([(ids entries) (hashtable-entries (task-service-entries service))])
      (for-each
        (lambda (entry)
          (when (predicate entry)
            (retire-task! service entry #t)))
        (vector->list entries))))

  (define (task-service-cancel-buffer! service buffer-id)
    (task-service-cancel-where!
      service
      (lambda (entry)
        (= (command-context-buffer-id (task-entry-origin entry)) buffer-id))))

  (define (task-service-cancel-view! service view-id)
    (task-service-cancel-where!
      service
      (lambda (entry)
        (= (command-context-view-id (task-entry-origin entry)) view-id))))

  ;; Results scoped to a document revision cannot remain useful after the
  ;; source Buffer advances.  Cancelling the worker also prevents it from
  ;; consuming resources only to publish an answer that must be discarded.
  (define (task-service-cancel-stale-buffer! service buffer-id)
    (task-service-cancel-where!
      service
      (lambda (entry)
        (and (not (eq? (task-entry-scope entry) 'none))
             (= (command-context-buffer-id (task-entry-origin entry)) buffer-id)))))

  (define (task-service-cancel-surface! service surface-id)
    (task-service-cancel-where!
      service
      (lambda (entry)
        (= (command-context-surface-id (task-entry-origin entry)) surface-id))))

  (define (task-scope-current? service entry buffer view)
    (let* ([origin (task-entry-origin entry)]
           [scope (task-entry-scope entry)]
           [origin-buffer-state (command-context-buffer-state origin)]
           [origin-view-state (command-context-view-state origin)]
           [buffer-current?
            (and buffer origin-buffer-state
                 (= (buffer-id buffer) (command-context-buffer-id origin))
                 (= (buffer-state-generation (buffer-state buffer))
                    (buffer-state-generation origin-buffer-state)))]
           [view-current?
            (and buffer-current? view origin-view-state
                 (= (view-id view) (command-context-view-id origin))
                 (= (buffer-id (view-buffer view)) (buffer-id buffer))
                 (= (view-state-generation (view-state view))
                    (view-state-generation origin-view-state)))])
      (case scope
        [(none) (and buffer view)]
        [(buffer) buffer-current?]
        [(view) view-current?]
        [(context)
         (and view-current?
              (let* ([surface
                      (surface-service-ref
                        (task-service-surfaces service)
                        (command-context-surface-id origin) #f)]
                     [active
                      (and surface
                           (surface-active-context
                             surface (task-service-views service)))])
                (and active
                     (= (active-context-window-id active)
                        (command-context-window-id origin))
                     (= (active-context-view-id active) (view-id view)))))]
        [else #f])))

  (define (task-current-context service entry)
    (let* ([origin (task-entry-origin entry)]
           [buffer
            (buffer-service-ref
              (task-service-buffers service) (command-context-buffer-id origin) #f)]
           [view
            (view-service-ref
              (task-service-views service) (command-context-view-id origin) #f)])
      (and (task-scope-current? service entry buffer view)
           (make-command-context
             #f
             (command-context-surface-id origin)
             (command-context-window-id origin)
             (view-id view)
             (buffer-id buffer)
             (buffer-state buffer)
             (view-state view)
             #f '()
             (command-context-prefix-argument origin)
             (command-context-target origin)
             'task
             (command-context-layout origin)
             (command-context-input-layers origin)))))

  (define (enqueue-task-message! service id kind value)
    ;; A native runtime may report a late event after cancellation.  It has no
    ;; editor consequence and must not re-open a closed runtime through an
    ;; exception in its callback.
    (when (task-entry-ref service id)
      (guard (ignored [else #f])
        (runtime-enqueue!
          (task-service-runtime service) (%make-task-message id kind value)))))

  (define (task-service-start! service owner name scope origin command arguments start)
    (unless (and (task-service? service) (owner? owner) (symbol? name)
                 (task-scope? scope) (command-context? origin)
                 (symbol? command) (procedure? arguments) (procedure? start))
      (assertion-violation 'task-service-start! "invalid task declaration"
                           service owner name scope origin command arguments start))
    (owner-assert-active 'task-service-start! owner)
    (let* ([id (+ 1 (task-service-next-id service))]
           [entry #f]
           [handle
            (make-task-handle
              id owner name
              (lambda () (and entry (retire-task! service entry #t))))])
      (task-service-next-id-set! service id)
      (set! entry
            (%make-task-entry id owner name scope origin command arguments handle #f))
      (hashtable-set! (task-service-entries service) id entry)
      (owner-add-cleanup! owner (lambda () (retire-task! service entry #t)))
      (guard
        (condition
          [else
           (retire-task! service entry #t)
           (raise condition)])
        (let ([cancel
               (start
                 (lambda (value) (enqueue-task-message! service id 'result value))
                 (lambda () (enqueue-task-message! service id 'finished #f))
                 (lambda (condition)
                   (enqueue-task-message! service id 'failed condition)))])
          (unless (or (not cancel) (procedure? cancel))
            (retire-task! service entry #t)
            (assertion-violation 'task-service-start!
                                 "task start must return a cancellation procedure or false"
                                 name cancel))
          (task-entry-cancel-set! entry cancel)
          handle))))

  (define (handle-task-result! service entry value)
    (let ([context (task-current-context service entry)])
      (when context
        (guard
          (condition
            [else (capture-task-condition! service entry 'result condition)])
          (let ([arguments ((task-entry-arguments entry) value)])
            (unless (list? arguments)
              (assertion-violation 'task-result "task result arguments must be a list"
                                   (task-entry-name entry) arguments))
            (command-runtime-enqueue-background!
              (task-service-commands service)
              (make-command-invoke-message
                (task-entry-command entry) context arguments #f)))))))

  (define (task-service-handle-message! service message)
    (and (task-message? message)
         (let ([entry (task-entry-ref service (task-message-id message))])
           (when entry
             (case (task-message-kind message)
               [(result) (handle-task-result! service entry (task-message-value message))]
               [(finished) (retire-task! service entry #f)]
               [(failed)
                (capture-task-condition! service entry 'background
                                         (task-message-value message))
                (retire-task! service entry #t)]
               [else
                (capture-task-condition!
                  service entry 'protocol
                  (list 'unknown-task-message (task-message-kind message)))
                (retire-task! service entry #t)]))
           #t)))
)
