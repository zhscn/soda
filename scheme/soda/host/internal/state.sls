(library (soda host internal state)
  (export make-host-state
          host-state?
          host-state-owner
          host-state-runtime
          host-state-buffers
          host-state-buffer-attachments
          host-state-analyses
          host-state-modes
          host-state-mode-catalog
          host-state-locations
          host-state-navigation
          host-state-presentations
          host-state-settings
          host-state-views
          host-state-surfaces
          host-state-commands
          host-state-command-runtime
          host-state-conditions
          host-state-dispatch
          host-state-frontend-handlers
          host-state-location-follow-ready?
          host-state-location-follow-ready?-set!
          host-state-closed?
          host-state-run!
          host-state-close!)
  (import (rnrs)
          (soda host internal buffer)
          (soda host internal buffer-attachment)
          (soda host internal analysis)
          (soda kernel state)
          (soda host command)
          (soda host command-runtime)
          (soda host condition)
          (soda host dispatch)
          (soda host internal location)
          (soda host internal navigation)
          (soda host internal presentation)
          (soda host internal setting)
          (soda host internal mode)
          (soda host runtime)
          (soda host internal surface)
          (soda host value)
          (soda host internal view))

  (define-record-type
    (host-state %make-host-state host-state?)
    (fields
      (immutable owner host-state-owner)
      (immutable runtime host-state-runtime)
      (immutable buffers host-state-buffers)
      (immutable buffer-attachments host-state-buffer-attachments)
      (immutable analyses host-state-analyses)
      (immutable modes host-state-modes)
      (immutable mode-catalog host-state-mode-catalog)
      (immutable locations host-state-locations)
      (immutable navigation host-state-navigation)
      (immutable presentations host-state-presentations)
      (immutable settings host-state-settings)
      (immutable views host-state-views)
      (immutable surfaces host-state-surfaces)
      (immutable commands host-state-commands)
      (immutable command-runtime host-state-command-runtime)
      (immutable conditions host-state-conditions)
      (immutable dispatch host-state-dispatch)
      (immutable frontend-handlers host-state-frontend-handlers)
      (mutable location-follow-ready? host-state-location-follow-ready?
               host-state-location-follow-ready?-set!)
      (mutable closed? host-state-closed? host-state-closed?-set!)))

  (define (make-host-state)
    (let* ([owner (make-owner 'host)]
           [runtime (make-runtime)]
           [buffers (make-buffer-service)]
           [buffer-attachments (make-buffer-attachment-service buffers)]
           [views (make-view-service)]
           [surfaces (make-surface-service)]
           [commands (make-command-registry)]
           [conditions (make-condition-service)]
           [dispatch (make-dispatcher buffers views surfaces)]
           [modes
            (make-mode-service
              (lambda (source condition)
                (condition-service-capture
                  conditions owner source (lambda arguments #f) '(dismiss))))]
           [mode-catalog (make-mode-catalog)]
           [locations (make-location-service buffers)]
           [navigation (make-navigation-history)]
           [presentations (make-buffer-presentation-service)]
           [settings (make-setting-service)]
           [command-runtime
             (make-command-runtime owner commands dispatch runtime conditions)]
           [analyses
            (make-analysis-service buffers runtime conditions dispatch)])
      (surface-service-set-remove-handler!
        surfaces
        (lambda (surface)
          (command-runtime-forget-surface! command-runtime (surface-id surface))))
      (view-service-set-plugin-error-handler!
        views
        (lambda (view phase condition)
          (condition-service-capture
            conditions
            (view-owner view)
            (list 'view-plugin phase condition)
             (lambda arguments #f)
            '(dismiss))))
      (dispatcher-set-error-reporter!
        dispatch
        (lambda (source condition)
          (condition-service-capture
            conditions owner (list 'dispatcher source condition)
            (lambda arguments #f)
            '(dismiss))))
      (dispatcher-register-global-operation-handler!
        dispatch owner 'configuration-source-reload '(configuration)
        (lambda (request)
          (setting-service-apply-reload-request! settings request)))
      (buffer-service-set-create-handler!
        buffers
        (lambda (buffer)
          (mode-service-reconcile!
            modes buffer #f
            (buffer-state-configuration (buffer-state buffer)))
          (buffer-presentation-service-refresh!
            presentations (buffer-id buffer) buffer)))
      (dispatcher-add-listener!
        dispatch owner
        (lambda (update)
          (let* ([buffer (buffer-service-ref buffers (editor-update-buffer-id update) #f)]
                 [old-configuration
                  (buffer-state-configuration (editor-update-old-buffer-state update))]
                 [new-configuration
                  (buffer-state-configuration (editor-update-new-buffer-state update))])
            (when (and buffer (not (eq? old-configuration new-configuration)))
              (mode-service-reconcile!
                modes buffer old-configuration new-configuration))
            (when buffer
              (buffer-presentation-service-refresh!
                presentations (buffer-id buffer) buffer))
            (analysis-service-refresh! analyses update))))
      (view-service-set-close-handler!
        views
        (lambda (view)
          (surface-service-prune-view! surfaces (view-id view))))
      (buffer-service-set-close-query-handler!
        buffers
        (lambda (buffer)
          (buffer-attachment-service-prepare-close! buffer-attachments buffer)))
      (buffer-service-set-close-handler!
        buffers
        (lambda (buffer)
          (and (mode-service-close-buffer! modes buffer)
               (analysis-service-close-buffer! analyses (buffer-id buffer))
               (view-service-close-buffer-views! views (buffer-id buffer))
               (begin
                 (buffer-presentation-service-discard!
                   presentations (buffer-id buffer))
                 #t)
               (buffer-attachment-service-destroy-buffer! buffer-attachments buffer))))
      (%make-host-state
        owner runtime buffers buffer-attachments analyses modes mode-catalog locations navigation
        presentations settings views surfaces commands
        command-runtime conditions dispatch (make-eqv-hashtable) #f #f)))

  (define (host-state-close! state)
    (unless (host-state? state)
      (assertion-violation 'host-state-close! "expected a host state" state))
    (if (host-state-closed? state)
        #f
        (let loop ()
          (let ([buffers (buffer-service-buffers (host-state-buffers state))])
            (cond
              [(null? buffers)
               (runtime-close! (host-state-runtime state))
               (owner-close! (host-state-owner state))
               (host-state-closed?-set! state #t)
               #t]
              [(buffer-service-close-buffer! (host-state-buffers state)
                                             (buffer-id (car buffers)))
               ;; Teardown may synchronously open a replacement Buffer.  Take
               ;; a fresh catalog snapshot before deciding shutdown is done.
               (loop)]
              ;; A veto leaves the HostState usable.  A caller can resolve the
              ;; close query and retry instead of losing live Buffer resources.
              [else #f])))))

  ;; The frontend owns polling native events.  The host loop only drains
  ;; bounded runtime messages and therefore remains usable by headless tests
  ;; and by a future terminal frontend.
  (define (host-state-run! state . options)
    (unless (and (host-state? state) (not (host-state-closed? state)))
      (assertion-violation 'host-state-run! "host state is closed" state))
    (let ([handler (if (null? options)
                       (lambda (message) (when (procedure? message) (message)))
                       (car options))]
          [limit (if (or (null? options) (null? (cdr options))) #f (cadr options))])
      (unless (procedure? handler)
        (assertion-violation 'host-state-run! "handler must be a procedure" handler))
      (runtime-drain!
        (host-state-runtime state)
        (lambda (message)
          (unless
            (or (analysis-service-handle-message!
                  (host-state-analyses state) message)
                (command-runtime-handle-message!
                  (host-state-command-runtime state) message))
            (handler message)))
        limit)))
)
