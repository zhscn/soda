(library (soda host package)
  (export make-package-host
          package-host?
          package-host-command-runtime
          package-host-dispatch!
          package-host-dispatch-view!
          package-host-buffer-ref
          package-host-buffers
          package-host-open-or-create-buffer!
          package-host-create-buffer!
          package-host-close-buffer!
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
          (soda host command-runtime)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal state)
          (soda host internal surface)
          (soda host internal view)
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
