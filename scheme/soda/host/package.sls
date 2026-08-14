(library (soda host package)
  (export make-package-host
          package-host?
          package-host-command-runtime
          package-host-register-analysis-provider!
          package-host-request-analysis!
          package-host-stop-analysis!
          package-host-analysis-result
          package-host-register-setting-schema!
          package-host-setting-schema
          package-host-setting-schemas
          package-host-parse-setting
          package-host-reload-configuration-source!
          package-host-configuration-source
          package-host-resolve-setting
          package-host-configuration-extensions
          package-host-materialize-key-bindings
          package-host-register-location-provider!
          package-host-resolve-location
          package-host-begin-navigation!
          package-host-navigation-back!
          package-host-navigation-forward!
          package-host-commit-navigation!
          package-host-cancel-navigation!
          package-host-dispatch!
          package-host-dispatch-view!
          package-host-add-update-listener!
          package-host-buffer-ref
          package-host-buffers
          package-host-buffers-for-surface
          package-host-open-or-create-buffer!
          package-host-create-buffer!
          package-host-close-buffer!
          package-host-close-buffer-with-fallback!
          package-host-add-buffer-close-listener!
          package-host-find-buffer-key
          package-host-rebind-buffer-key!
          package-host-view-ref
          package-host-create-view!
          package-host-present-buffer!
          package-host-close-view!
          package-host-surface-size
          package-host-replace-window-view!
          package-host-push-interaction-view!
          package-host-add-interaction-companion-view!
          package-host-pop-interaction-view!
          package-host-remove-interaction-view!
          package-host-publish-feedback!
          package-host-publish-buffer-presentation!
          package-host-register-buffer-presentation-projector!
          package-host-refresh-command-context)
  (import (rnrs)
          (soda kernel document)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host feedback)
          (soda host analysis)
          (soda host key-configuration)
          (soda host setting)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal analysis)
          (soda host internal location)
          (soda host internal navigation)
          (soda host internal presentation)
          (soda host internal setting)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
          (soda host internal window)
          (soda host operation)
          (soda host value))

  ;; PackageHost is the complete mutable capability made available to a
  ;; feature package.  It deliberately exposes requests and resource values,
  ;; never the HostState registries that own their lifetime.
  (define-record-type
    (package-host %make-package-host package-host?)
    (fields (immutable state package-host-state)))

  (define (make-package-host state)
    (unless (host-state? state)
      (assertion-violation 'make-package-host "expected a HostState" state))
    (%make-package-host state))

  (define (package-host-command-runtime host)
    (host-state-command-runtime (package-host-state host)))

  (define (package-host-register-analysis-provider! host owner provider)
    (analysis-service-register!
      (host-state-analyses (package-host-state host)) owner provider))

  (define package-host-request-analysis!
    (case-lambda
      [(host buffer-id key)
       (analysis-service-request!
         (host-state-analyses (package-host-state host)) buffer-id key)]
      [(host buffer-id key changed-ranges)
       (analysis-service-request!
         (host-state-analyses (package-host-state host))
         buffer-id key changed-ranges)]))

  (define (package-host-stop-analysis! host buffer-id key)
    (analysis-service-stop!
      (host-state-analyses (package-host-state host)) buffer-id key))

  (define (package-host-analysis-result host buffer-id key . default)
    (apply analysis-service-result
           (host-state-analyses (package-host-state host))
           buffer-id key default))

  (define (package-host-register-setting-schema! host owner schema)
    (setting-service-register!
      (host-state-settings (package-host-state host)) owner schema))

  (define (package-host-setting-schema host name . default)
    (apply setting-service-ref
           (host-state-settings (package-host-state host)) name default))

  (define (package-host-setting-schemas host)
    (setting-service-schemas
      (host-state-settings (package-host-state host))))

  (define (package-host-parse-setting host name input scope source)
    (setting-service-parse
      (host-state-settings (package-host-state host))
      name input scope source))

  (define (package-host-reload-configuration-source! host owner source)
    (let ([state (package-host-state host)])
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (setting-service-make-reload-operation
          (host-state-settings state) owner source))))

  (define (package-host-configuration-source host id . default)
    (apply setting-service-source
           (host-state-settings (package-host-state host)) id default))

  (define (package-host-resolve-setting host name scope context)
    (setting-service-resolve
      (host-state-settings (package-host-state host)) name scope context))

  (define (package-host-configuration-extensions host scope context)
    (setting-service-extensions
      (host-state-settings (package-host-state host)) scope context))

  (define (package-host-materialize-key-bindings host declarations context mode)
    (let ([runtime
           (host-state-command-runtime (package-host-state host))])
      (key-binding-declarations->input-layers
        declarations
        (lambda (name)
          (and (command-runtime-command-definition runtime name #f) #t))
        context mode)))

  (define (package-host-register-location-provider! host owner provider)
    (location-service-register!
      (host-state-locations (package-host-state host)) owner provider))

  (define (package-host-resolve-location host location)
    (location-service-resolve
      (host-state-locations (package-host-state host)) location))

  (define (package-host-begin-navigation! host from target)
    (navigation-history-begin!
      (host-state-navigation (package-host-state host)) from target))

  (define (package-host-navigation-back! host)
    (navigation-history-back!
      (host-state-navigation (package-host-state host))))

  (define (package-host-navigation-forward! host)
    (navigation-history-forward!
      (host-state-navigation (package-host-state host))))

  (define (package-host-commit-navigation! host jump arrived)
    (navigation-history-commit!
      (host-state-navigation (package-host-state host)) jump arrived))

  (define (package-host-cancel-navigation! host jump)
    (navigation-history-cancel!
      (host-state-navigation (package-host-state host)) jump))

  (define (package-host-dispatch! host specification)
    (dispatcher-dispatch! (host-state-dispatch (package-host-state host)) specification))

  (define (package-host-dispatch-view! host specification)
    (dispatcher-dispatch-view! (host-state-dispatch (package-host-state host)) specification))

  (define (package-host-add-update-listener! host owner procedure)
    (unless (and (package-host? host) (owner? owner) (procedure? procedure))
      (assertion-violation 'package-host-add-update-listener!
                           "expected a PackageHost, Owner, and update listener"
                           host owner procedure))
    (dispatcher-add-listener!
      (host-state-dispatch (package-host-state host)) owner procedure))

  (define (package-host-buffer-ref host id . default)
    (apply buffer-service-ref (host-state-buffers (package-host-state host)) id default))

  (define (package-host-buffers host)
    (buffer-service-buffers (host-state-buffers (package-host-state host))))

  ;; Buffer catalogs are unordered registries.  User-facing switchers consume
  ;; a Surface-relative order: recently replaced Views first, followed by the
  ;; remaining live Buffers in a deterministic name order.
  (define (package-host-buffers-for-surface host surface-id)
    (unless (and (package-host? host) (integer? surface-id)
                 (exact? surface-id) (>= surface-id 0))
      (assertion-violation 'package-host-buffers-for-surface
                           "invalid PackageHost or Surface identity"
                           host surface-id))
    (let* ([state (package-host-state host)]
           [buffers (host-state-buffers state)]
           [views (host-state-views state)]
           [surface
            (surface-service-ref (host-state-surfaces state) surface-id #f)]
           [catalog (buffer-service-buffers buffers)])
      (define (seen? buffer result)
        (exists
          (lambda (candidate) (= (buffer-id candidate) (buffer-id buffer)))
          result))
      (define (append-buffer result buffer)
        (if (or (not buffer) (seen? buffer result))
            result
            (append result (list buffer))))
      (let* ([recent
              (if (not surface)
                  '()
                  (fold-left
                    (lambda (result view-id)
                      (let ([view (view-service-ref views view-id #f)])
                        (append-buffer result (and view (view-buffer view)))))
                    '() (surface-view-history surface)))]
             [remaining
              (list-sort
                (lambda (left right)
                  (let ([left-name (buffer-name left)]
                        [right-name (buffer-name right)])
                    (or (string<? left-name right-name)
                        (and (string=? left-name right-name)
                             (< (buffer-id left) (buffer-id right))))))
                (filter (lambda (buffer) (not (seen? buffer recent))) catalog))])
        (append recent remaining))))

  (define (package-host-open-or-create-buffer! host owner key builder)
    (buffer-service-open-or-create!
      (host-state-buffers (package-host-state host)) owner key builder))

  (define (package-host-create-buffer! host owner name document configuration)
    (buffer-service-create!
      (host-state-buffers (package-host-state host)) owner name document configuration))

  (define (package-host-close-buffer! host id)
    (buffer-service-close-buffer! (host-state-buffers (package-host-state host)) id))

  ;; Closing a placed Buffer is a host lifecycle operation.  The host replaces
  ;; every occurrence before retirement, so a feature package never traverses
  ;; Surface trees or leaves a Window targeting a retired View.
  (define (recent-replacement-view surface views excluded-buffer-id)
    (let loop ([ids (surface-view-history surface)])
      (and (pair? ids)
           (let ([view (view-service-ref views (car ids) #f)])
             (if (and view
                      (not (= (buffer-id (view-buffer view))
                              excluded-buffer-id)))
                 view
                 (loop (cdr ids)))))))

  (define (package-host-close-buffer-with-fallback! host owner target-id)
    (let* ((state (package-host-state host))
           (buffers (host-state-buffers state))
           (views (host-state-views state))
           (surfaces (host-state-surfaces state))
           (target (buffer-service-ref buffers target-id #f)))
      (and target
           (let* ((scratch
                   (buffer-service-find-key buffers (scratch-buffer-key) #f))
                  (fallback
                   (or (and scratch
                            (not (= (buffer-id scratch) target-id))
                            scratch)
                       (find
                         (lambda (buffer)
                           (not (= (buffer-id buffer) target-id)))
                         (buffer-service-buffers buffers))))
                  (replacement-needs-key? (and (not fallback) (eq? scratch target)))
                  (replacement-buffer
                   (or fallback
                       (if replacement-needs-key?
                           ;; The old scratch owns the canonical key until its
                           ;; close commits.  Bind its replacement afterwards.
                           (buffer-service-create!
                             buffers owner "*scratch*" (make-document "")
                             (buffer-state-configuration (buffer-state target)))
                           (buffer-service-open-or-create!
                             buffers owner (scratch-buffer-key)
                             (lambda ()
                               (buffer-service-create!
                                 buffers owner "*scratch*" (make-document "")
                                 (buffer-state-configuration
                                   (buffer-state target)))))))))
             (let ()
               (for-each
                 (lambda (surface)
                   (for-each
                     (lambda (window)
                       (let ((view (view-service-ref views (window-view-id window) #f)))
                         (when (and view (= (buffer-id (view-buffer view)) target-id))
                           (let* ((recent
                                   (recent-replacement-view
                                     surface views target-id))
                                  (replacement
                                   (or recent
                                       (view-service-create!
                                         views owner replacement-buffer
                                         (view-state-configuration
                                           (view-state view))))))
                             (unless (dispatcher-dispatch-host!
                                       (host-state-dispatch state)
                                       (make-replace-window-view-operation
                                         (surface-id surface) (window-id window)
                                         (view-id replacement)))
                               (unless recent
                                 (view-service-close-view!
                                   views (view-id replacement)))
                               (assertion-violation
                                 'package-host-close-buffer-with-fallback!
                                 "unable to replace a Buffer View before close" target-id))))))
                     (window-leaves (surface-root-window surface))))
                 (surface-service-surfaces surfaces))
               (let ((closed? (buffer-service-close-buffer! buffers target-id)))
                 (when (and closed? replacement-needs-key?)
                   (buffer-service-bind-key!
                     buffers (scratch-buffer-key) replacement-buffer))
                 closed?))))))

  (define (package-host-add-buffer-close-listener! host owner procedure)
    (buffer-service-add-close-listener!
      (host-state-buffers (package-host-state host)) owner procedure))

  (define (package-host-find-buffer-key host key . default)
    (apply buffer-service-find-key (host-state-buffers (package-host-state host)) key default))

  (define (package-host-rebind-buffer-key! host key buffer)
    (buffer-service-rebind-key! (host-state-buffers (package-host-state host)) key buffer))

  (define (package-host-view-ref host id . default)
    (apply view-service-ref (host-state-views (package-host-state host)) id default))

  (define (package-host-create-view! host owner buffer configuration . input-state)
    (apply view-service-create!
           (host-state-views (package-host-state host)) owner buffer configuration input-state))

  (define (recent-buffer-view surface views target-id)
    (let loop ([ids (surface-view-history surface)])
      (and (pair? ids)
           (let ([view (view-service-ref views (car ids) #f)])
             (if (and view (= (buffer-id (view-buffer view)) target-id))
                 view
                 (loop (cdr ids)))))))

  ;; Presenting a Buffer is a host navigation operation.  It restores the
  ;; Surface's most recently used View for that Buffer, preserving point,
  ;; viewport, and input state.  A View is created only on first presentation.
  (define (package-host-present-buffer!
            host owner buffer target-surface-id target-window-id configuration)
    (unless (and (package-host? host) (owner? owner) (buffer? buffer))
      (assertion-violation 'package-host-present-buffer!
                           "expected a PackageHost, Owner, and Buffer"
                           host owner buffer))
    (let* ([state (package-host-state host)]
           [views (host-state-views state)]
           [surface
            (surface-service-ref
              (host-state-surfaces state) target-surface-id #f)]
           [window (and surface
                        (find (lambda (leaf) (= (window-id leaf) target-window-id))
                              (window-leaves (surface-root-window surface))))])
      (and window
           (let ([current (view-service-ref views (window-view-id window) #f)])
             (if (and current
                      (= (buffer-id (view-buffer current)) (buffer-id buffer)))
                 current
                 (let ([recent (recent-buffer-view surface views (buffer-id buffer))])
                   (if recent
                       (and (dispatcher-dispatch-host!
                              (host-state-dispatch state)
                              (make-replace-window-view-operation
                                target-surface-id target-window-id (view-id recent)))
                            recent)
                       (let ([created
                              (view-service-create!
                                views owner buffer configuration)])
                         (if (dispatcher-dispatch-host!
                               (host-state-dispatch state)
                               (make-replace-window-view-operation
                                 target-surface-id target-window-id (view-id created)))
                             created
                             (begin
                               (view-service-close-view! views (view-id created))
                               #f))))))))))

  (define (package-host-close-view! host id)
    (view-service-close-view! (host-state-views (package-host-state host)) id))

  (define (package-host-surface-size host surface-id)
    (let ([surface
           (surface-service-ref (host-state-surfaces (package-host-state host)) surface-id #f)])
      (and surface (surface-size surface))))

  ;; Placement owns rollback of a newly-created View.  Feature packages only
  ;; observe success or failure and never repair the Surface tree directly.
  (define (place-view! host operation view-id)
    (if (dispatcher-dispatch-host! (host-state-dispatch (package-host-state host)) operation)
        #t
        (begin
          (package-host-close-view! host view-id)
          #f)))

  (define (package-host-replace-window-view! host surface-id window-id view-id)
    (place-view! host
                 (make-replace-window-view-operation surface-id window-id view-id)
                 view-id))

  (define (package-host-push-interaction-view! host surface-id view-id height)
    (place-view! host
                 (make-push-interaction-operation surface-id view-id height)
                 view-id))

  (define (package-host-add-interaction-companion-view!
            host surface-id anchor-view-id view-id height)
    (place-view!
      host
      (make-add-interaction-companion-operation
        surface-id anchor-view-id view-id height)
      view-id))

  (define (package-host-pop-interaction-view! host surface-id)
    (dispatcher-dispatch-host!
      (host-state-dispatch (package-host-state host))
      (make-pop-interaction-operation surface-id)))

  (define (package-host-remove-interaction-view! host surface-id view-id)
    (dispatcher-dispatch-host!
      (host-state-dispatch (package-host-state host))
      (make-remove-interaction-operation surface-id view-id)))

  (define (package-host-publish-feedback! host surface-id feedback)
    (unless (and (package-host? host) (user-feedback? feedback))
      (assertion-violation 'package-host-publish-feedback!
                           "expected a PackageHost and UserFeedback" host feedback))
    (dispatcher-dispatch-host!
      (host-state-dispatch (package-host-state host))
      (make-set-surface-feedback-operation surface-id feedback)))

  (define (package-host-publish-buffer-presentation! host buffer-id key value)
    (unless (package-host? host)
      (assertion-violation 'package-host-publish-buffer-presentation!
                           "expected a PackageHost" host))
    (buffer-presentation-service-set!
      (host-state-presentations (package-host-state host)) buffer-id key value))

  (define (package-host-register-buffer-presentation-projector!
            host owner key procedure)
    (unless (and (package-host? host) (owner? owner) (symbol? key)
                 (procedure? procedure))
      (assertion-violation
        'package-host-register-buffer-presentation-projector!
        "invalid presentation projector" host owner key procedure))
    (let* ([state (package-host-state host)]
           [presentations (host-state-presentations state)]
           [registration
            (buffer-presentation-service-register-projector!
              presentations owner key procedure)])
      (for-each
        (lambda (buffer)
          (buffer-presentation-service-refresh!
            presentations (buffer-id buffer) buffer))
        (buffer-service-buffers (host-state-buffers state)))
      registration))

  ;; Long-running command compositions refresh state at each queued step.
  ;; Window identity is followed across View replacement, so a file visit or
  ;; buffer switch inside the composition changes the target of later steps.
  (define (package-host-refresh-command-context host template prefix source)
    (unless (and (package-host? host) (command-context? template) (symbol? source))
      (assertion-violation 'package-host-refresh-command-context
                           "expected a PackageHost, CommandContext, and source"
                           host template source))
    (let* ([state (package-host-state host)]
           [surface-id (command-context-surface-id template)]
           [requested-window-id (command-context-window-id template)]
           [surface
            (and surface-id
                 (surface-service-ref
                   (host-state-surfaces state) surface-id #f))]
           [window
            (and surface requested-window-id
                 (let loop ([remaining (surface-windows surface)])
                   (and (pair? remaining)
                        (if (= (window-id (car remaining)) requested-window-id)
                            (car remaining)
                            (loop (cdr remaining))))))]
           [resolved-view-id
            (if window (window-view-id window)
                (command-context-view-id template))]
           [view
            (and resolved-view-id
                 (view-service-ref
                   (host-state-views state) resolved-view-id #f))]
           [buffer (and view (view-buffer view))])
      (and view buffer
           (make-command-context
             #f surface-id requested-window-id (view-id view) (buffer-id buffer)
             (buffer-state buffer) (view-state view) #f '() prefix
             (command-context-target template) source #f))))
)
