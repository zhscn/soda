(library (soda host internal mode)
  (export make-mode-service
          mode-service?
          mode-service-reconcile!
          mode-service-close-buffer!
          mode-service-instances
          mode-instance?
          mode-instance-spec
          mode-instance-owner
          mode-instance-buffer-id
          mode-instance-generation
          mode-event?
          mode-event-buffer
          mode-event-old-major-mode
          mode-event-new-major-mode
          mode-event-enabled-minor-modes
          mode-event-disabled-minor-modes
          mode-event-generation
          make-mode-catalog
          mode-catalog?
          mode-catalog-register!
          mode-catalog-spec)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel state)
          (soda host internal buffer)
          (soda host value))

  (define-record-type
    (mode-instance %make-mode-instance mode-instance?)
    (fields (immutable spec mode-instance-spec)
            (immutable owner mode-instance-owner)
            (immutable buffer-id mode-instance-buffer-id)
            (immutable generation mode-instance-generation)))

  (define-record-type
    (mode-event %make-mode-event mode-event?)
    (fields (immutable buffer mode-event-buffer)
            (immutable old-major-mode mode-event-old-major-mode)
            (immutable new-major-mode mode-event-new-major-mode)
            (immutable enabled-minor-modes mode-event-enabled-minor-modes)
            (immutable disabled-minor-modes mode-event-disabled-minor-modes)
            (immutable generation mode-event-generation)))

  (define-record-type
    (mode-service %make-mode-service mode-service?)
    (fields (immutable instances mode-service-table)
            (immutable report-error! mode-service-report-error!)
            (mutable generation mode-service-generation mode-service-generation-set!)
            (mutable phase mode-service-phase mode-service-phase-set!)
            (mutable deferred mode-service-deferred mode-service-deferred-set!)
            (mutable draining? mode-service-draining? mode-service-draining?-set!)))

  ;; ModeCatalog stores declared ModeSpecs independently of live Buffer
  ;; instances.  Configuration can consequently validate a target mode before
  ;; any Buffer has selected that mode.
  (define-record-type
    (mode-catalog %make-mode-catalog mode-catalog?)
    (fields (immutable table mode-catalog-table)))
  (define-record-type mode-catalog-entry
    (fields owner spec))

  (define (make-mode-catalog)
    (%make-mode-catalog (make-eq-hashtable)))

  (define (mode-catalog-spec catalog id . default)
    (unless (and (mode-catalog? catalog) (symbol? id))
      (assertion-violation 'mode-catalog-spec "expected a ModeCatalog and mode id"
                           catalog id))
    (let ([entry (hashtable-ref (mode-catalog-table catalog) id #f)])
      (if entry
          (mode-catalog-entry-spec entry)
          (if (null? default) #f (car default)))))

  (define (mode-catalog-register! catalog owner spec)
    (unless (and (mode-catalog? catalog) (owner? owner) (mode-spec? spec))
      (assertion-violation 'mode-catalog-register!
                           "expected a ModeCatalog, Owner, and ModeSpec"
                           catalog owner spec))
    (owner-assert-active 'mode-catalog-register! owner)
    (let* ([table (mode-catalog-table catalog)]
           [id (mode-spec-id spec)]
           [existing (hashtable-ref table id #f)])
      (cond
        [(not existing)
         (let ([entry (make-mode-catalog-entry owner spec)])
           (hashtable-set! table id entry)
           (make-registration
             owner
             (lambda ()
               (when (eq? (hashtable-ref table id #f) entry)
                 (hashtable-delete! table id)))))]
        [(eq? (mode-catalog-entry-spec existing) spec)
         (make-registration owner (lambda () #f))]
        [else
         (assertion-violation 'mode-catalog-register!
                              "mode id is already registered by another ModeSpec"
                              id spec)])))

  (define (make-mode-service report-error!)
    (unless (procedure? report-error!)
      (assertion-violation 'make-mode-service "expected an error reporter" report-error!))
    (%make-mode-service (make-eqv-hashtable) report-error! 0 'idle '() #f))

  (define (report! service source condition)
    (guard (ignored [else #f])
      ((mode-service-report-error! service) source condition)))

  (define (mode-service-next-generation! service)
    (let ([generation (+ 1 (mode-service-generation service))])
      (mode-service-generation-set! service generation)
      generation))

  (define (configuration-modes configuration)
    (let ([major (configuration-facet configuration buffer-mode-facet 'buffer)]
          [minor (configuration-facet configuration buffer-minor-modes-facet 'buffer)])
      (append (if major (list major) '()) minor)))

  (define (configuration-major configuration)
    (and configuration
         (configuration-facet configuration buffer-mode-facet 'buffer)))

  (define (configuration-minor configuration)
    (if configuration
        (configuration-facet configuration buffer-minor-modes-facet 'buffer)
        '()))

  (define (mode-spec-lineage spec)
    (if (mode-spec-parent spec)
        (append (mode-spec-lineage (mode-spec-parent spec)) (list spec))
        (list spec)))

  (define (invoke-callback! service instance accessor buffer reverse?)
    (let ([specs (mode-spec-lineage (mode-instance-spec instance))])
      (for-each
        (lambda (spec)
          (let ([callback (accessor spec)])
            (when callback
              (guard
                (condition
                  [else
                   (report! service
                            (list 'mode (mode-spec-id spec)
                                  (if reverse? 'deactivate 'activate))
                            condition)])
                (callback buffer (mode-instance-owner instance))))))
        (if reverse? (reverse specs) specs))))

  (define (activate-instance! service buffer spec generation)
    (let* ([owner (make-owner (mode-spec-id spec))]
           [instance (%make-mode-instance spec owner (buffer-id buffer) generation)])
      (invoke-callback! service instance mode-spec-activate buffer #f)
      instance))

  (define (deactivate-instance! service buffer instance)
    (invoke-callback! service instance mode-spec-deactivate buffer #t)
    (when (owner-active? (mode-instance-owner instance))
      (owner-close! (mode-instance-owner instance))))

  (define (find-instance instances spec)
    (find (lambda (instance) (eq? (mode-instance-spec instance) spec)) instances))

  (define (difference left right)
    (filter (lambda (item) (not (memq item right))) left))

  (define (insert-hook hook hooks)
    (cond
      [(null? hooks) (list hook)]
      [(< (hook-spec-order hook) (hook-spec-order (car hooks)))
       (cons hook hooks)]
      [else (cons (car hooks) (insert-hook hook (cdr hooks)))]))

  (define (ordered-hooks hooks)
    (fold-left (lambda (result hook) (insert-hook hook result)) '() hooks))

  (define (run-hooks! service configuration phase event)
    (when configuration
      (let ([hooks
             (filter (lambda (hook) (eq? (hook-spec-phase hook) phase))
                     (configuration-facet configuration buffer-hooks-facet 'buffer))])
        (for-each
          (lambda (hook)
            (guard
              (condition
                [else
                 (report! service (list 'buffer-hook (hook-spec-name hook) phase)
                          condition)])
              ((hook-spec-procedure hook) event)))
          (ordered-hooks hooks)))))

  ;; Mode callbacks and Buffer-local hooks may publish another transaction.
  ;; Reconciliation is serialized so a nested publication observes the fully
  ;; installed ModeInstance set instead of constructing a competing set.
  (define (mode-service-drain! service)
    (when (and (eq? (mode-service-phase service) 'idle)
               (pair? (mode-service-deferred service))
               (not (mode-service-draining? service)))
      (dynamic-wind
        (lambda () (mode-service-draining?-set! service #t))
        (lambda ()
          (let loop ()
            (when (pair? (mode-service-deferred service))
              (let ([queued (mode-service-deferred service)])
                (mode-service-deferred-set! service '())
                (for-each (lambda (thunk) (mode-service-run! service thunk)) queued)
                (loop)))))
        (lambda () (mode-service-draining?-set! service #f)))))

  (define (mode-service-run! service thunk)
    (if (eq? (mode-service-phase service) 'idle)
        (let ([result
               (dynamic-wind
                 (lambda () (mode-service-phase-set! service 'reconciling))
                 thunk
                 (lambda () (mode-service-phase-set! service 'idle)))])
          (unless (mode-service-draining? service)
            (mode-service-drain! service))
          result)
        (begin
          (mode-service-deferred-set!
            service (append (mode-service-deferred service) (list thunk)))
          #f)))

  (define (mode-service-reconcile-now! service buffer old-configuration new-configuration)
    (unless (and (mode-service? service) (buffer? buffer)
                 (or (not old-configuration) (configuration? old-configuration))
                 (configuration? new-configuration))
      (assertion-violation 'mode-service-reconcile! "invalid reconciliation input"
                           service buffer old-configuration new-configuration))
    (let* ([id (buffer-id buffer)]
           [current (hashtable-ref (mode-service-table service) id '())]
           [desired (configuration-modes new-configuration)]
           [old-major (configuration-major old-configuration)]
           [new-major (configuration-major new-configuration)]
           [old-minor (configuration-minor old-configuration)]
           [new-minor (configuration-minor new-configuration)]
           [enabled (difference new-minor old-minor)]
           [disabled (difference old-minor new-minor)]
           [generation (mode-service-next-generation! service)]
           [event (%make-mode-event buffer old-major new-major enabled disabled generation)])
      (unless (eq? old-major new-major)
        (run-hooks! service old-configuration 'before-major-mode-change event))
      (for-each
        (lambda (instance)
          (unless (memq (mode-instance-spec instance) desired)
            (deactivate-instance! service buffer instance)))
        (reverse current))
      (let ([next
             (map (lambda (spec)
                    (or (find-instance current spec)
                        (activate-instance! service buffer spec generation)))
                  desired)])
        (hashtable-set! (mode-service-table service) id next)
        (unless (eq? old-major new-major)
          (run-hooks! service new-configuration 'after-major-mode-change event)
          (run-hooks! service new-configuration 'major-mode event))
        (when (pair? enabled)
          (run-hooks! service new-configuration 'minor-mode-enabled event))
        (when (pair? disabled)
          (run-hooks! service old-configuration 'minor-mode-disabled event))
        (unless (eq? old-configuration new-configuration)
          (run-hooks! service new-configuration 'buffer-configuration-changed event))
        next)))

  (define (mode-service-reconcile! service buffer old-configuration new-configuration)
    (unless (mode-service? service)
      (assertion-violation 'mode-service-reconcile! "expected a ModeService" service))
    (mode-service-run!
      service
      (lambda ()
        (mode-service-reconcile-now!
          service buffer old-configuration new-configuration))))

  (define (mode-service-close-buffer-now! service buffer)
    (unless (and (mode-service? service) (buffer? buffer))
      (assertion-violation 'mode-service-close-buffer!
                           "expected a ModeService and Buffer" service buffer))
    (let* ([id (buffer-id buffer)]
           [instances (hashtable-ref (mode-service-table service) id '())]
           [configuration (buffer-state-configuration (buffer-state buffer))]
           [generation (mode-service-next-generation! service)]
           [event (%make-mode-event buffer
                                    (configuration-major configuration) #f '()
                                    (configuration-minor configuration) generation)])
      (run-hooks! service configuration 'buffer-close event)
      (for-each (lambda (instance) (deactivate-instance! service buffer instance))
                (reverse instances))
      (hashtable-delete! (mode-service-table service) id)
      #t))

  (define (mode-service-close-buffer! service buffer)
    (unless (mode-service? service)
      (assertion-violation 'mode-service-close-buffer! "expected a ModeService" service))
    (mode-service-run!
      service (lambda () (mode-service-close-buffer-now! service buffer))))

  (define (mode-service-instances service buffer-id)
    (unless (and (mode-service? service) (integer? buffer-id) (exact? buffer-id))
      (assertion-violation 'mode-service-instances
                           "expected a ModeService and Buffer identity" service buffer-id))
    (list-copy (hashtable-ref (mode-service-table service) buffer-id '())))
)
