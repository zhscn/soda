(library (soda host internal view)
  (export view?
          view-id
          view-owner
          view-buffer
          view-state
          view-plugin-instances
          view-decorations
          view-merged-decorations
          view-display-streams
          view-display-transforms
          view-transform-display-stream
          view-publish-state!
          view-update-plugins!
          view-close!
          make-view-service
          view-service?
          view-service-create!
          view-service-ref
          view-service-views
          view-service-set-plugin-error-handler!
          view-service-close-view!)
  (import (rnrs)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel value)
          (soda host internal buffer)
          (soda host input)
          (soda host value)
          (soda view plugin)
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
            (mutable decoration-cache view-decoration-cache
                     view-decoration-cache-set!)
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
                (guard
                  (condition
                    [else
                     (report-plugin-error! view 'plugin-decorations condition)
                     (destroy-plugin-instance! view instance 'plugin-decoration-cleanup)
                     (loop (cdr instances) result)])
                  (loop (cdr instances)
                        (cons (view-plugin-instance-decorations instance) result))))))))

  (define (refresh-view-decorations! view)
    (view-decoration-cache-set!
      view
      (merge-decoration-sets (collect-view-decorations view))))

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

  (define (make-view-record identity-source owner buffer configuration input-state plugin-error!)
    (owner-assert-active 'view-service-create! owner)
    (unless (buffer? buffer)
      (assertion-violation 'view-service-create! "expected a buffer" buffer))
    (let ([view
           (%make-view
             (identity-source-next! identity-source) owner buffer plugin-error!
             (make-view-state (buffer-id buffer)
                              (buffer-state-generation (buffer-state buffer))
                              (empty-selection) '(0 . 0)
                              (or input-state (default-input-stack)) configuration)
             '() (make-decoration-set '()) #f)])
      (view-plugin-instances-set!
        view
        (create-plugin-instances! view (configuration-view-plugins configuration)))
      (refresh-view-decorations! view)
      (owner-add-cleanup! owner (lambda () (view-close! view)))
      view))

  (define (view-publish-state! view state)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-publish-state! "view is closed" view))
    (unless (view-state? state)
      (assertion-violation 'view-publish-state! "expected a view state" state))
    (view-state-set! view state)
    (reconcile-view-plugins! view (view-state-configuration state))
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
    (for-each
      (lambda (instance)
        (unless (view-plugin-instance-destroyed? instance)
          (guard
            (condition
              [else
               (report-plugin-error! view 'plugin-update condition)
               (destroy-plugin-instance! view instance 'plugin-update-cleanup)
               #f])
            (view-plugin-instance-update! instance update))))
      (view-plugin-instances view))
    (refresh-view-decorations! view)
    view)

  (define (view-decorations view)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-decorations "expected a live View" view))
    (collect-view-decorations view))

  (define (view-merged-decorations view)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-merged-decorations "expected a live View" view))
    (view-decoration-cache view))

  ;; A display stream is cached by its plugin instance and updated at the View
  ;; publication boundary.  Rendering only reads the cached projection.
  (define (view-display-streams view)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-display-streams "expected a live View" view))
    (let loop ([instances (view-plugin-instances view)] [result '()])
      (if (null? instances)
          (reverse result)
          (let ([stream (view-plugin-instance-display-stream (car instances))])
            (loop (cdr instances) (if stream (cons stream result) result))))))

  (define (view-display-transforms view)
    (unless (and (view? view) (not (view-closed? view)))
      (assertion-violation 'view-display-transforms "expected a live View" view))
    (let loop ([instances (view-plugin-instances view)] [result '()])
      (if (null? instances)
          (reverse result)
          (let ([transform (view-plugin-instance-display-transform (car instances))])
            (loop (cdr instances) (if transform (cons transform result) result))))))

  ;; A transform is prepared by a plugin update but executed against the
  ;; current visible base stream.  Failure is contained at the View boundary,
  ;; matching decoration and update failures.
  (define (view-transform-display-stream view stream)
    (unless (and (view? view) (not (view-closed? view)) (display-stream? stream))
      (assertion-violation 'view-transform-display-stream
                           "expected a live View and DisplayStream" view stream))
    (let loop ([instances (view-plugin-instances view)] [current stream])
      (if (null? instances)
          current
          (let* ([instance (car instances)]
                 [transform (view-plugin-instance-display-transform instance)])
            (if (not transform)
                (loop (cdr instances) current)
                (guard
                  (condition
                    [else
                     (report-plugin-error! view 'plugin-display-transform condition)
                     (destroy-plugin-instance! view instance 'plugin-display-transform-cleanup)
                     (loop (cdr instances) current)])
                  (let ([next (transform current)])
                    (unless (display-stream? next)
                      (assertion-violation 'view-transform-display-stream
                                           "plugin transform returned a non-DisplayStream" next))
                    (loop (cdr instances) next))))))))

  (define-record-type
    (view-service %make-view-service view-service?)
    (fields (immutable identities view-service-identities)
            (immutable table view-service-table)
            (mutable plugin-error! view-service-plugin-error!
                     view-service-plugin-error!-set!)))

  (define (make-view-service)
    (%make-view-service (make-identity-source) (make-eqv-hashtable)
                        (lambda (view phase condition) #f)))

  (define (view-service-set-plugin-error-handler! service handler)
    (unless (and (view-service? service) (procedure? handler))
      (assertion-violation
        'view-service-set-plugin-error-handler!
        "expected a ViewService and condition handler" service handler))
    (view-service-plugin-error!-set! service handler)
    handler)

  (define (view-service-create! service owner buffer configuration . input-state)
    (unless (view-service? service)
      (assertion-violation 'view-service-create! "expected a view service" service))
    (let ([view (make-view-record (view-service-identities service) owner buffer configuration
                                  (if (null? input-state) #f (car input-state))
                                  (view-service-plugin-error! service))])
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
