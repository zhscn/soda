(library (soda host internal view)
  (export view?
          view-id
          view-owner
          view-buffer
          view-state
          view-render-generation
          view-projection
          view-occurrences
          view-plugin-instances
          view-publish-state!
          view-update-plugins!
          view-close!
          make-view-service
          view-service?
          view-service-create!
          view-service-ref
          view-service-views
          view-service-close-buffer-views!
          view-service-retire-projection-failure!
          view-service-publish-occurrences!
          view-service-set-plugin-error-handler!
          view-service-set-close-handler!
          view-service-add-close-listener!
          view-service-close-view!)
  (import (rnrs)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda kernel value)
          (soda host internal buffer)
          (soda host input)
          (soda host value)
          (soda view plugin)
          (soda view internal plugin)
          (soda view projection)
          (soda view occurrence)
          (soda view display)
          (soda view decoration))

  (define-record-type
    (view %make-view view?)
    (fields (immutable id view-id)
            (immutable owner view-owner)
            (immutable buffer view-buffer)
            (immutable plugin-error! view-plugin-error!)
            (mutable state view-state view-state-set!)
            (mutable plugins view-plugin-instances view-plugin-instances-set!)
            (mutable projection view-published-projection
                     view-published-projection-set!)
            (mutable occurrences view-occurrences view-occurrences-set!)
            (mutable render-generation view-render-generation
                     view-render-generation-set!)
            (mutable closed? view-closed? view-closed?-set!)))

  (define (empty-selection)
    (make-selection (list (make-selection-range 0 0))))

  (define (default-input-stack)
    (make-input-stack (make-input-state 'default '() 'accept)))

  (define (report-plugin-error! view phase condition)
    (guard (ignored [else #f])
      ((view-plugin-error! view) view phase condition)))

  (define (destroy-plugin-instance! view instance phase)
    (guard (condition [else (report-plugin-error! view phase condition) #f])
      (view-plugin-instance-destroy! instance)))

  (define (create-plugin-instances! view plugins)
    (let loop ([remaining plugins] [created '()])
      (if (null? remaining)
          (reverse created)
          (guard
            (condition
              [else
               (report-plugin-error! view 'plugin-create condition)
               (for-each
                 (lambda (instance)
                   (destroy-plugin-instance! view instance 'plugin-create-cleanup))
                 created)
               (raise condition)])
            (loop (cdr remaining)
                  (cons (make-view-plugin-instance (car remaining) view)
                        created))))))

  (define (collect-view-decorations view)
    (let loop ([instances (view-plugin-instances view)] [result '()])
      (if (null? instances)
          (reverse result)
          (let ([instance (car instances)])
            (if (view-plugin-instance-destroyed? instance)
                (loop (cdr instances) result)
                (loop (cdr instances)
                      (cons (view-plugin-instance-decorations instance) result)))))))

  (define (validate-display-providers! plugins)
    (let ([providers
           (filter (lambda (plugin) (view-plugin-display plugin)) plugins)])
      (when (and (pair? providers) (pair? (cdr providers)))
        (assertion-violation
          'view-service-create!
          "a View configuration may contain only one full DisplayStream provider"
          (map view-plugin-key providers)))))

  (define (collect-view-display-stream view)
    (let loop ([instances (view-plugin-instances view)] [result #f])
      (if (null? instances)
          result
          (let ([stream (view-plugin-instance-display-stream (car instances))])
            (if stream
                (if result
                    (assertion-violation
                      'view-display-stream
                      "multiple ViewPlugin instances produced full DisplayStreams")
                (loop (cdr instances) stream))
                (loop (cdr instances) result))))))

  (define (collect-view-transforms view)
    (let loop ([instances (view-plugin-instances view)] [result '()])
      (if (null? instances)
          (reverse result)
          (let* ([instance (car instances)]
                 [transform (view-plugin-instance-display-transform instance)])
            (loop (cdr instances)
                  (if transform
                      (cons (cons (view-plugin-key
                                    (view-plugin-instance-plugin instance))
                                  transform)
                            result)
                      result))))))

  (define (publish-view-projection! view)
    (let ([next-generation (+ 1 (view-render-generation view))])
      (view-render-generation-set! view next-generation)
      (view-published-projection-set!
        view
        (make-view-projection
          next-generation
          (merge-decoration-sets (collect-view-decorations view))
          (collect-view-display-stream view)
          (collect-view-transforms view)))))

  (define (view-projection view)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-projection "expected a live View" view))
    (view-published-projection view))

  ;; Retain a destroyed instance until its definition leaves configuration.
  ;; Recreating it on every update would turn one plugin fault into a loop.
  (define (matching-plugin-instance instances plugin)
    (let loop ([remaining instances])
      (cond [(null? remaining) #f]
            [(eq? plugin (view-plugin-instance-plugin (car remaining)))
             (car remaining)]
            [else (loop (cdr remaining))])))

  (define (reconcile-view-plugins! view configuration)
    (let ([plugins
            (guard
              (condition
                [else (report-plugin-error! view 'plugin-configuration condition) #f])
              (configuration-view-plugins configuration))])
      (when plugins
        (validate-display-providers! plugins)
        (let ([old (view-plugin-instances view)])
          (for-each
            (lambda (instance)
              (unless (exists (lambda (plugin)
                                (eq? plugin (view-plugin-instance-plugin instance)))
                              plugins)
                (destroy-plugin-instance! view instance 'plugin-destroy)))
            old)
          (view-plugin-instances-set!
            view
            (let loop ([remaining plugins] [result '()])
              (if (null? remaining)
                  (reverse result)
                  (let ([existing
                         (matching-plugin-instance old (car remaining))])
                    (if existing
                        (loop (cdr remaining) (cons existing result))
                        (guard
                          (condition
                            [else
                             (report-plugin-error! view 'plugin-create condition)
                             (loop (cdr remaining) result)])
                          (loop (cdr remaining)
                                (cons (make-view-plugin-instance (car remaining) view)
                                      result))))))))))))

  (define (make-view-record identity-source owner buffer configuration input-state plugin-error! on-close)
    (owner-assert-active 'view-service-create! owner)
    (unless (buffer? buffer)
      (assertion-violation 'view-service-create! "expected a buffer" buffer))
    (let ([view
           (%make-view
             (identity-source-next! identity-source) owner buffer plugin-error!
             (make-view-state (buffer-id buffer)
                              (buffer-state-generation (buffer-state buffer))
                              (empty-selection) default-viewport
                              (or input-state (default-input-stack)) configuration)
             '() (make-view-projection 0 (make-decoration-set '()) #f '()) '() 0 #f)])
      (validate-display-providers! (configuration-view-plugins configuration))
      (view-plugin-instances-set!
        view
        (create-plugin-instances! view (configuration-view-plugins configuration)))
      (publish-view-projection! view)
      (owner-add-cleanup! owner (lambda () (on-close view)))
      view))

  (define (view-publish-state! view state)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-publish-state! "view is closed" view))
    (unless (view-state? state)
      (assertion-violation 'view-publish-state! "expected a view state" state))
    (let ([configuration-changed?
           (not (eq? (view-state-configuration (view-state view))
                     (view-state-configuration state)))])
      (view-state-set! view state)
      (when configuration-changed?
        (reconcile-view-plugins! view (view-state-configuration state))
        (publish-view-projection! view)))
    state)

  (define (view-close! view)
    (unless (view? view)
      (assertion-violation 'view-close! "expected a view" view))
    (if (view-closed? view)
        #f
        (begin
          (for-each (lambda (instance)
                      (destroy-plugin-instance! view instance 'plugin-destroy))
                    (view-plugin-instances view))
          (view-closed?-set! view #t)
          #t)))

  (define (view-update-plugins! view update)
    (unless (and (view? view) (not (view-closed? view)) (view-update? update))
      (assertion-violation
        'view-update-plugins! "expected a live View and ViewUpdate" view update))
    (let ([output-changed? #f])
      (for-each
        (lambda (instance)
          (unless (view-plugin-instance-destroyed? instance)
            (guard
              (condition
                [else
                 (report-plugin-error! view 'plugin-update condition)
                 (destroy-plugin-instance! view instance 'plugin-update-cleanup)
                 (set! output-changed? #t)
                 #f])
              (when (view-plugin-instance-update! instance update)
                (set! output-changed? #t)))))
        (view-plugin-instances view))
      (when output-changed?
        (publish-view-projection! view))
      view))

  (define-record-type
    (view-service %make-view-service view-service?)
    (fields (immutable identities view-service-identities)
            (immutable table view-service-table)
            (mutable plugin-error! view-service-plugin-error!
                     view-service-plugin-error!-set!)
            (mutable close! view-service-close-handler view-service-close-handler-set!)
            (mutable close-listeners view-service-close-listeners
                     view-service-close-listeners-set!)))

  (define (make-view-service)
    (%make-view-service (make-identity-source) (make-eqv-hashtable)
                        (lambda (view phase condition) #f)
                        (lambda (view) #f)
                        '()))

  (define (view-service-set-plugin-error-handler! service handler)
    (unless (and (view-service? service) (procedure? handler))
      (assertion-violation
        'view-service-set-plugin-error-handler!
        "expected a ViewService and condition handler" service handler))
    (view-service-plugin-error!-set! service handler)
    handler)

  (define (view-service-set-close-handler! service handler)
    (unless (and (view-service? service) (procedure? handler))
      (assertion-violation 'view-service-set-close-handler!
                           "expected a ViewService and close handler" service handler))
    (view-service-close-handler-set! service handler)
    handler)

  ;; The primary close handler preserves surface placement.  Listeners run
  ;; after it and before the View leaves the service catalog.
  (define (view-service-add-close-listener! service owner procedure)
    (unless (and (view-service? service) (owner? owner) (procedure? procedure))
      (assertion-violation 'view-service-add-close-listener!
                           "expected a ViewService, owner, and procedure"
                           service owner procedure))
    (owner-assert-active 'view-service-add-close-listener! owner)
    (let ([listener procedure])
      (view-service-close-listeners-set!
        service (append (view-service-close-listeners service) (list listener)))
      (make-registration
        owner
        (lambda ()
          (view-service-close-listeners-set!
            service
            (filter (lambda (item) (not (eq? item listener)))
                    (view-service-close-listeners service)))))))

  (define (view-service-create! service owner buffer configuration . input-state)
    (unless (view-service? service)
      (assertion-violation 'view-service-create! "expected a view service" service))
    (let ([view (make-view-record
                  (view-service-identities service) owner buffer configuration
                  (if (null? input-state) #f (car input-state))
                  (view-service-plugin-error! service)
                  (lambda (view)
                    (view-service-close-view! service (view-id view))))])
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

  (define (view-service-close-buffer-views! service target-buffer-id)
    (unless (and (view-service? service)
                 (nonnegative-exact-integer? target-buffer-id))
      (assertion-violation 'view-service-close-buffer-views!
                           "invalid ViewService or Buffer identity"
                           service target-buffer-id))
    (for-each
      (lambda (view)
        (when (= (buffer-id (view-buffer view)) target-buffer-id)
          (view-service-close-view! service (view-id view))))
      (view-service-views service))
    #t)

  (define (occurrence-lists=? left right)
    (and (= (length left) (length right))
         (for-all view-occurrence=? left right)))

  (define (retarget-occurrence occurrence generation)
    (make-view-occurrence
      (view-occurrence-surface-id occurrence)
      (view-occurrence-window-id occurrence)
      (view-occurrence-view-id occurrence)
      (view-occurrence-rectangle occurrence)
      (view-occurrence-viewport occurrence)
      (view-occurrence-visible-ranges occurrence)
      generation))

  ;; This runs from a queued frontend host message after the pure frame has
  ;; been presented.  Every occurrence belongs to one View and is immutable.
  (define (view-service-publish-occurrences! service id occurrences)
    (unless (and (view-service? service) (integer? id) (exact? id) (>= id 0)
                 (list? occurrences)
                 (for-all (lambda (occurrence)
                            (and (view-occurrence? occurrence)
                                 (= (view-occurrence-view-id occurrence) id)))
                          occurrences))
      (assertion-violation 'view-service-publish-occurrences!
                           "invalid View occurrences" service id occurrences))
    (let ([view (view-service-ref service id #f)])
      (and view
           (let* ([target-generation
                   (if (null? (view-occurrences view))
                       (+ 1 (view-render-generation view))
                       (view-render-generation view))]
                  [published
                  (map (lambda (occurrence)
                         (retarget-occurrence occurrence
                                              target-generation))
                       occurrences)])
             (and (not (occurrence-lists=? (view-occurrences view) published))
           (begin
             (view-occurrences-set!
               view
               (map (lambda (occurrence)
                      (retarget-occurrence occurrence target-generation))
                    occurrences))
             (view-update-plugins!
               view
               (make-view-update (view-id view) (view-state view) (view-state view)
                                 #f '(viewport layout) (view-occurrences view)))
             #t))))))

  ;; Render failures are reported by a frontend on its next host-loop turn.
  ;; The generation check keeps an obsolete frame from retiring a plugin that
  ;; has since published a newer projection.
  (define (view-service-retire-projection-failure! service id generation key condition)
    (unless (and (view-service? service) (integer? id) (exact? id) (>= id 0)
                 (integer? generation) (exact? generation) (>= generation 0)
                 (symbol? key))
      (assertion-violation 'view-service-retire-projection-failure!
                           "invalid View projection failure" service id generation key))
    (let ([view (view-service-ref service id #f)])
      (and view
           (= generation (view-render-generation view))
           (let ([instance
                  (let loop ([instances (view-plugin-instances view)])
                    (and (pair? instances)
                         (if (eq? key (view-plugin-key
                                        (view-plugin-instance-plugin (car instances))))
                             (car instances)
                             (loop (cdr instances)))))])
             (and instance (not (view-plugin-instance-destroyed? instance))
                  (begin
                    (report-plugin-error! view 'plugin-transform condition)
                    (destroy-plugin-instance! view instance 'plugin-transform-cleanup)
                    (publish-view-projection! view)
                    #t))))))

  (define (view-service-close-view! service id)
    (let ([view (view-service-ref service id #f)])
      (and view
           (let ([closed? (view-close! view)])
             (when closed?
               ((view-service-close-handler service) view)
               (for-each
                 (lambda (listener)
                   (guard (ignored [else #f]) (listener view)))
                 (view-service-close-listeners service))
               (hashtable-delete! (view-service-table service) id))
             closed?))))
)
