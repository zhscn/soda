(library (soda host package)
  (export make-package-host
          package-host?
          package-host-command-runtime
          package-host-register-analysis-provider!
          package-host-request-analysis!
          package-host-stop-analysis!
          package-host-analysis-result
          package-host-register-location-provider!
          package-host-resolve-location
          package-host-begin-navigation!
          package-host-navigation-back!
          package-host-navigation-forward!
          package-host-commit-navigation!
          package-host-cancel-navigation!
          package-host-dispatch!
          package-host-dispatch-view!
          package-host-buffer-ref
          package-host-buffers
          package-host-open-or-create-buffer!
          package-host-create-buffer!
          package-host-close-buffer!
          package-host-close-buffer-with-fallback!
          package-host-add-buffer-close-listener!
          package-host-find-buffer-key
          package-host-rebind-buffer-key!
          package-host-view-ref
          package-host-create-view!
          package-host-close-view!
          package-host-surface-size
          package-host-replace-window-view!
          package-host-push-interaction-view!
          package-host-pop-interaction-view!
          package-host-set-surface-message!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command-runtime)
          (soda host analysis)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal analysis)
          (soda host internal location)
          (soda host internal navigation)
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

  (define (package-host-buffer-ref host id . default)
    (apply buffer-service-ref (host-state-buffers (package-host-state host)) id default))

  (define (package-host-buffers host)
    (buffer-service-buffers (host-state-buffers (package-host-state host))))

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
  (define (package-host-close-buffer-with-fallback! host owner target-id)
    (let* ((state (package-host-state host))
           (buffers (host-state-buffers state))
           (views (host-state-views state))
           (surfaces (host-state-surfaces state))
           (target (buffer-service-ref buffers target-id #f)))
      (and target
           (let ((fallback
                  (let find-surface ((remaining (surface-service-surfaces surfaces)))
                    (and (pair? remaining)
                         (or (let find-window ((windows
                                                (window-leaves
                                                  (surface-root-window (car remaining)))))
                               (and (pair? windows)
                                    (let ((view (view-service-ref views
                                                                  (window-view-id (car windows)) #f)))
                                      (if (and view
                                               (not (= (buffer-id (view-buffer view)) target-id)))
                                          (view-buffer view)
                                          (find-window (cdr windows))))))
                             (find-surface (cdr remaining)))))))
             (let ((replacement-buffer
                    (or fallback
                        (buffer-service-create!
                          buffers owner "*scratch*" (make-document "")
                          (buffer-state-configuration (buffer-state target))))))
               (for-each
                 (lambda (surface)
                   (for-each
                     (lambda (window)
                       (let ((view (view-service-ref views (window-view-id window) #f)))
                         (when (and view (= (buffer-id (view-buffer view)) target-id))
                           (let ((replacement
                                  (view-service-create!
                                    views owner replacement-buffer
                                    (view-state-configuration (view-state view)))))
                             (unless (dispatcher-dispatch-host!
                                       (host-state-dispatch state)
                                       (make-replace-window-view-operation
                                         (surface-id surface) (window-id window)
                                         (view-id replacement)))
                               (view-service-close-view! views (view-id replacement))
                               (assertion-violation
                                 'package-host-close-buffer-with-fallback!
                                 "unable to replace a Buffer View before close" target-id))))))
                     (window-leaves (surface-root-window surface))))
                 (surface-service-surfaces surfaces))
               (buffer-service-close-buffer! buffers target-id))))))

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

  (define (package-host-push-interaction-view! host surface-id view-id rectangle)
    (place-view! host
                 (make-push-interaction-operation surface-id view-id rectangle)
                 view-id))

  (define (package-host-pop-interaction-view! host surface-id)
    (dispatcher-dispatch-host!
      (host-state-dispatch (package-host-state host))
      (make-pop-interaction-operation surface-id)))

  (define (package-host-set-surface-message! host surface-id message)
    (dispatcher-dispatch-host!
      (host-state-dispatch (package-host-state host))
      (make-set-surface-message-operation surface-id message)))
)
