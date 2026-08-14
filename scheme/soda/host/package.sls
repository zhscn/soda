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
          package-host-key-binding-layers
          package-host-resolve-setting
          package-host-configuration-extensions
          package-host-register-mode!
          package-host-mode-spec
          package-host-validate-key-bindings!
          package-host-materialize-key-bindings
          package-host-register-location-provider!
          package-host-resolve-location
          package-host-follow-location!
          package-host-request-location-follow!
          package-host-location-opened!
          package-host-navigate-back!
          package-host-navigate-forward!
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
          package-host-present-buffer!
          package-host-present-buffer-if-current!
          package-host-command-context-current?
          package-host-create-interaction-view!
          package-host-create-interaction-companion-view!
          package-host-split-window!
          package-host-focus-next-window!
          package-host-delete-window!
          package-host-delete-other-windows!
          package-host-bury-window!
          package-host-surface-size
          package-host-invalidate-surface!
          package-host-remove-interaction-view!
          package-host-publish-feedback!
          package-host-publish-feedback-if-current!
          package-host-publish-buffer-presentation!
          package-host-register-buffer-presentation-projector!
          package-host-refresh-command-context)
  (import (rnrs)
          (soda kernel document)
          (soda kernel location)
          (soda kernel mode)
          (soda kernel resource)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel viewport)
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
          (soda host location)
          (soda host internal navigation)
          (soda host internal mode)
          (soda host internal presentation)
          (soda host internal setting)
          (soda host internal state)
          (soda host internal context)
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
    (let ([host (%make-package-host state)])
      (ensure-location-follow-runtime! host)
      host))

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
    (unless (and (package-host? host) (owner? owner)
                 (configuration-source? source))
      (assertion-violation 'package-host-reload-configuration-source!
                           "expected a PackageHost, Owner, and ConfigurationSource"
                           host owner source))
    ;; Validate key declarations before submitting the source replacement.
    ;; The setting service already parses all setting declarations before it
    ;; changes its source table, so either half failing preserves the prior
    ;; observable configuration generation.
    (package-host-validate-key-bindings!
      host (configuration-source-key-bindings source))
    (let ([state (package-host-state host)])
      (dispatcher-dispatch-host!
        (host-state-dispatch state)
        (setting-service-make-reload-operation
          (host-state-settings state) owner source))))

  (define (package-host-configuration-source host id . default)
    (apply setting-service-source
           (host-state-settings (package-host-state host)) id default))

  (define package-host-key-binding-layers
    (case-lambda
      [(host context mode)
       (package-host-key-binding-layers
         host context mode (make-configuration-context #f #f))]
      [(host context mode configuration-context)
    (unless (and (package-host? host) (symbol? context)
                 (or (not mode) (symbol? mode) (mode-spec? mode))
                 (configuration-context? configuration-context))
      (assertion-violation 'package-host-key-binding-layers
                           "expected a PackageHost, context, optional mode, and ConfigurationContext"
                           host context mode configuration-context))
    ;; Input resolution stops at the first matching layer.  SettingService
    ;; selects the sources that apply to this ConfigurationContext and orders
    ;; them from lower to higher configuration precedence.  Materialize each
    ;; source separately and reverse that order for input resolution.
    (let* ([sources
            (setting-service-configuration-sources-for
              (host-state-settings (package-host-state host)) configuration-context)]
           [sources-by-precedence
            (reverse sources)])
      (apply append
             (map
               (lambda (source)
                 (package-host-materialize-key-bindings
                   host (configuration-source-key-bindings source) context mode))
               sources-by-precedence)))]))

  (define (package-host-resolve-setting host name scope context)
    (setting-service-resolve
      (host-state-settings (package-host-state host)) name scope context))

  (define (package-host-configuration-extensions host scope context)
    (setting-service-extensions
      (host-state-settings (package-host-state host)) scope context))

  (define (package-host-register-mode! host owner spec)
    (unless (package-host? host)
      (assertion-violation 'package-host-register-mode! "expected a PackageHost" host))
    (mode-catalog-register!
      (host-state-mode-catalog (package-host-state host)) owner spec))

  (define (package-host-mode-spec host id . default)
    (unless (package-host? host)
      (assertion-violation 'package-host-mode-spec "expected a PackageHost" host))
    (apply mode-catalog-spec
           (host-state-mode-catalog (package-host-state host)) id default))

  (define (package-host-materialize-key-bindings host declarations context mode)
    (unless (and (package-host? host)
                 (or (not mode) (symbol? mode) (mode-spec? mode)))
      (assertion-violation 'package-host-materialize-key-bindings
                           "expected a PackageHost and optional ModeSpec or mode id"
                           host mode))
    (let* ([runtime
            (host-state-command-runtime (package-host-state host))]
           [mode-spec
            (if (mode-spec? mode)
                mode
                (and mode (package-host-mode-spec host mode #f)))]
           [mode-id (if (mode-spec? mode-spec) (mode-spec-id mode-spec) mode)]
           [categories
            (if mode-spec
                (mode-spec-command-category-list mode-spec)
                #f)])
      (key-binding-declarations->input-layers
        declarations
        (lambda (name)
          (and (command-runtime-command-definition runtime name #f) #t))
        (lambda (declaration)
          (let ([definition
                 (command-runtime-command-definition
                   runtime (key-binding-declaration-command declaration) #f)])
            (and definition
                 (or (eq? (command-definition-scope definition) 'global)
                     ;; A configuration collection can contain declarations
                     ;; for other modes.  Validate a mode command when its
                     ;; declaration targets this materialized ModeSpec; the
                     ;; mode catalog validates declarations before a target
                     ;; ModeSpec is available.
                     (not (eq? (key-binding-declaration-mode declaration)
                               mode-id))
                     (and categories
                          (key-binding-declaration-mode declaration)
                          (command-definition-class definition)
                          (memq (command-definition-class definition)
                                categories))))))
        context mode-id)))

  (define (package-host-validate-key-bindings! host declarations)
    (unless (package-host? host)
      (assertion-violation 'package-host-validate-key-bindings!
                           "expected a PackageHost" host))
    (let ([runtime (host-state-command-runtime (package-host-state host))])
      (key-binding-declarations-validate!
        declarations
        (lambda (name)
          (and (command-runtime-command-definition runtime name #f) #t))
        (lambda (declaration)
          (let ([definition
                 (command-runtime-command-definition
                   runtime (key-binding-declaration-command declaration) #f)]
                [mode
                 (and (key-binding-declaration-mode declaration)
                      (package-host-mode-spec
                        host (key-binding-declaration-mode declaration) #f))])
            (and definition
                 (or (eq? (command-definition-scope definition) 'global)
                     (and mode
                          (command-definition-class definition)
                          (memq (command-definition-class definition)
                                (mode-spec-command-category-list mode)))))))
        (lambda (mode)
          (and (package-host-mode-spec host mode #f) #t)))))

  (define (package-host-register-location-provider! host owner provider)
    (location-service-register!
      (host-state-locations (package-host-state host)) owner provider))

  (define (package-host-resolve-location host location)
    (location-service-resolve
      (host-state-locations (package-host-state host)) location))

  ;; Request a Location follow at the command-loop boundary.  A command-effect
  ;; open request retains the follow until its provider reports completion;
  ;; already-resolved and opaque requests use the generic follow effect.
  (define (package-host-request-location-follow! host context target)
    (unless (and (package-host? host) (command-context? context) (location? target))
      (assertion-violation 'package-host-request-location-follow!
                           "expected a PackageHost, CommandContext, and Location"
                           host context target))
    (let* ([resolution (package-host-resolve-location host target)]
           [follow
            (make-command-effect
              'location.follow (make-location-follow-request context target))])
      (if (eq? (location-resolution-status resolution) 'needs-open)
          (let ([open (location-resolution-request resolution)])
            (if (command-effect? open)
                (if (location-service-add-follow!
                      (host-state-locations (package-host-state host)) target
                      (make-location-follow-request context target))
                    (list open)
                    '())
                (list follow)))
          (list follow))))

  ;; Resource providers call this capability only after their open effect has
  ;; made the target Buffer discoverable.  Each retained request returns to
  ;; Runtime as an ordinary hidden command, behind already queued user input.
  (define (package-host-location-opened! host target)
    (unless (and (package-host? host) (location? target))
      (assertion-violation 'package-host-location-opened!
                           "expected a PackageHost and Location" host target))
    (let ([runtime (package-host-command-runtime host)])
      (for-each
        (lambda (request)
          (unless (location-follow-request? request)
            (assertion-violation 'package-host-location-opened!
                                 "invalid retained Location follow request" request))
          (command-runtime-enqueue-background!
            runtime
            (make-command-invoke-message
              'host.follow-location
              (location-follow-request-context request)
              (list request) #f)))
        (location-service-take-follows!
          (host-state-locations (package-host-state host)) target))))

  (define (location-follow-feedback host target)
    (case (location-resolution-status (package-host-resolve-location host target))
      [(unavailable) "Location is unavailable"]
      [(stale) "Location is stale"]
      [(outside) "Location is outside its buffer"]
      [(needs-open) "Could not open location"]
      [else "Could not visit location"]))

  ;; The Host installs this bridge once per HostState.  Location-producing
  ;; packages return effect values only; resource providers signal completion
  ;; through `package-host-location-opened!`.
  (define (ensure-location-follow-runtime! host)
    (let ([state (package-host-state host)])
      (unless (host-state-location-follow-ready? state)
        (let ([runtime (package-host-command-runtime host)]
              [owner (host-state-owner state)])
          (command-runtime-register-effect-handler!
            runtime 'location.follow owner 'enqueue-location-follow
            (lambda (runtime ignored effect)
              (let ([request (command-effect-payload effect)])
                (unless (location-follow-request? request)
                  (assertion-violation 'location.follow
                                       "invalid Location follow request" request))
                (command-runtime-enqueue!
                  runtime
                  (make-command-invoke-message
                    'host.follow-location
                    (location-follow-request-context request)
                    (list request) #f)))))
          (define-command
            runtime owner 'host.follow-location (context request)
            (documentation "Complete a queued Location follow request.")
            (class 'application)
            (visible #f)
            (undo 'ignore)
            (unless (location-follow-request? request)
              (assertion-violation 'host.follow-location
                                   "invalid Location follow request" request))
            (unless (package-host-follow-location!
                      host owner context (location-follow-request-target request))
              (package-host-publish-feedback-if-current!
                host context
                (make-user-feedback
                  (location-follow-feedback host
                                            (location-follow-request-target request))
                  'warning)))
            (command-handled))
          (host-state-location-follow-ready?-set! state #t)))))

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

  ;; A delayed outcome may use its initiating CommandContext only while that
  ;; exact View remains the active input target.  A retained but unfocused
  ;; split Window, or an active minibuffer, does not authorize a result to
  ;; replace content or occupy the echo area.
  (define (package-host-command-context-current? host context)
    (unless (and (package-host? host) (command-context? context))
      (assertion-violation 'package-host-command-context-current?
                           "expected a PackageHost and CommandContext" host context))
    (let* ([state (package-host-state host)]
           [surface
            (surface-service-ref
              (host-state-surfaces state)
              (command-context-surface-id context) #f)]
           [active
            (and surface
                 (surface-active-context surface (host-state-views state)))])
      (and active
           (= (active-context-window-id active) (command-context-window-id context))
           (= (active-context-view-id active) (command-context-view-id context)))))

  ;; An asynchronous producer presents its result only when the View that
  ;; requested it is still current in its Window.  The predicate remains a
  ;; host detail so packages select a presentation policy without inspecting
  ;; or repairing Window placement themselves.
  (define (package-host-present-buffer-if-current! host owner buffer context configuration)
    (unless (and (package-host? host) (owner? owner) (buffer? buffer)
                 (command-context? context))
      (assertion-violation 'package-host-present-buffer-if-current!
                           "expected a PackageHost, Owner, Buffer, and CommandContext"
                           host owner buffer context))
    (and (package-host-command-context-current? host context)
         (package-host-present-buffer!
           host owner buffer
           (command-context-surface-id context)
           (command-context-window-id context)
           configuration)))

  ;; Navigation history records concrete editor state, rather than a command's
  ;; transient input context.  The current primary point is therefore
  ;; captured as a revisioned Location immediately before following a target.
  (define (command-context-location context)
    (let* ([buffer-state (command-context-buffer-state context)]
           [view-state (command-context-view-state context)]
           [selection (and view-state (view-state-selection view-state))]
           [primary (and selection (selection-primary-range selection))]
           [document (and buffer-state (buffer-state-document buffer-state))])
      (and primary document
           (make-location
             (make-resource
               'buffer (number->string (command-context-buffer-id context)))
             (make-byte-position (selection-range-head primary))
             (make-byte-position (selection-range-head primary))
             (snapshot-revision document) 'after '()))))

  ;; Stage a View for a Location follow without placing it in a Window.  A
  ;; newly-created View remains private until the composite dispatcher commits
  ;; both its selection and the Window replacement.
  (define (stage-location-follow-view! host owner context buffer)
    (let* ([state (package-host-state host)]
           [views (host-state-views state)]
           [surface
            (surface-service-ref
              (host-state-surfaces state)
              (command-context-surface-id context) #f)]
           [current (package-host-view-ref host (command-context-view-id context) #f)])
      (and surface
           (if (and current (= (buffer-id (view-buffer current)) (buffer-id buffer)))
               (cons current #f)
               (let ([recent (recent-buffer-view surface views (buffer-id buffer))])
                 (if recent
                     (cons recent #f)
                     (cons
                       (view-service-create!
                         views owner buffer (buffer-state-configuration (buffer-state buffer)))
                       #t)))))))

  ;; All Location follows use one Host-owned commit boundary.  The target is
  ;; resolved before placement; the history token moves only after selection
  ;; and reveal were published for the resulting View.
  (define (follow-resolved-location! host owner context resolution jump)
    (let ([buffer
           (and (eq? (location-resolution-status resolution) 'resolved)
                (package-host-buffer-ref
                  host (location-resolution-buffer-id resolution) #f))]
          [committed? #f]
          ;; A View created while staging is not owned by a Window until the
          ;; composite dispatch succeeds.  Keep that ownership explicit so a
          ;; rejected transaction, including one that raises, cannot leak it.
          [unplaced-created-view #f])
      (and buffer
           (dynamic-wind
             (lambda () #f)
             (lambda ()
               (let ([staged (stage-location-follow-view! host owner context buffer)])
                 (and staged
                      (let* ([view (car staged)]
                             [created? (cdr staged)]
                             [selection
                              (make-view-transaction-spec
                                (view-id view)
                                (view-state-generation (view-state view))
                                (make-selection
                                  (list
                                    (make-selection-range
                                      (location-resolution-from resolution)
                                      (location-resolution-from resolution))))
                                (view-state-viewport (view-state view))
                                #f '() '()
                                (make-scroll-request
                                  'reveal-point
                                  (command-context-surface-id context)
                                  (command-context-window-id context)
                                  (view-id view)))]
                             [same-view? (= (view-id view) (command-context-view-id context))])
                        (when created?
                          (set! unplaced-created-view view))
                        (let ([placed?
                               (if same-view?
                                   (package-host-dispatch-view! host selection)
                                   (dispatcher-dispatch-view-with-host!
                                     (host-state-dispatch (package-host-state host))
                                     selection
                                     (make-replace-window-view-operation
                                       (command-context-surface-id context)
                                       (command-context-window-id context)
                                       (view-id view))))])
                          (and placed?
                               (begin
                                 ;; The Surface now owns the new placement.  It
                                 ;; must survive a later history-token failure.
                                 (set! unplaced-created-view #f)
                                 (and (navigation-history-commit!
                                        (host-state-navigation (package-host-state host))
                                        jump (location-resolution-location resolution))
                                      (begin
                                        (set! committed? #t)
                                        (make-command-context
                                          #f
                                          (command-context-surface-id context)
                                          (command-context-window-id context)
                                          (view-id view)
                                          (buffer-id buffer)
                                          (buffer-state buffer)
                                          (view-state view)
                                          #f '() #f #f 'location-follow #f))))))))))
             (lambda ()
               (unless committed?
                 (navigation-history-cancel!
                   (host-state-navigation (package-host-state host)) jump)
                 (when unplaced-created-view
                   (view-service-close-view!
                     (host-state-views (package-host-state host))
                     (view-id unplaced-created-view)))))))))

  ;; Follow a new Location from the current editor position.  Providers own a
  ;; `needs-open` continuation; callers resume the same Location only after
  ;; its resource becomes available.  A false result leaves history unchanged.
  (define (package-host-follow-location! host owner context target)
    (unless (and (package-host? host) (owner? owner)
                 (command-context? context) (location? target))
      (assertion-violation 'package-host-follow-location!
                           "expected a PackageHost, Owner, CommandContext, and Location"
                           host owner context target))
    (and (package-host-command-context-current? host context)
         (let* ([resolution (package-host-resolve-location host target)]
                [from (command-context-location context)])
           (and from
                (eq? (location-resolution-status resolution) 'resolved)
                (follow-resolved-location!
                  host owner context resolution
                  (navigation-history-begin!
                    (host-state-navigation (package-host-state host)) from target))))))

  ;; Complete a pending history traversal in the current editor Window.  This
  ;; is private to the capability: feature packages never receive its mutable
  ;; history token.
  (define (follow-navigation! host owner context jump)
    (unless (and (package-host? host) (owner? owner)
                 (command-context? context) (navigation-jump? jump))
      (assertion-violation 'follow-navigation!
                           "expected a PackageHost, Owner, CommandContext, and NavigationJump"
                           host owner context jump))
    (let ([history (host-state-navigation (package-host-state host))])
      (cond
        [(not (package-host-command-context-current? host context))
         (navigation-history-cancel! history jump)
         'inactive]
        [else
         (let ([resolution
                (package-host-resolve-location host (navigation-jump-target jump))])
           (if (not (eq? (location-resolution-status resolution) 'resolved))
               (begin
                 (navigation-history-cancel! history jump)
                 (location-resolution-status resolution))
               (if (follow-resolved-location! host owner context resolution jump)
                   'followed
                   'placement-failed)))])))

  ;; Traverse Location history through the same follow boundary used for new
  ;; Location visits.  Failure cancels the pending traversal, retaining the
  ;; current history position for a later retry.
  (define (package-host-navigate-back! host owner context)
    (unless (and (package-host? host) (owner? owner) (command-context? context))
      (assertion-violation 'package-host-navigate-back!
                           "expected a PackageHost, Owner, and CommandContext"
                           host owner context))
    (let ([jump
           (navigation-history-back!
             (host-state-navigation (package-host-state host)))])
      (if jump
          (follow-navigation! host owner context jump)
          'empty)))

  (define (package-host-navigate-forward! host owner context)
    (unless (and (package-host? host) (owner? owner) (command-context? context))
      (assertion-violation 'package-host-navigate-forward!
                           "expected a PackageHost, Owner, and CommandContext"
                           host owner context))
    (let ([jump
           (navigation-history-forward!
             (host-state-navigation (package-host-state host)))])
      (if jump
          (follow-navigation! host owner context jump)
          'empty)))

  ;; User Window commands operate on the selected editor Window identified by
  ;; their CommandContext.  This rejects interaction overlays and stale
  ;; contexts rather than mutating whichever Window is selected later.
  (define (selected-editor-window host context)
    (let* ([state (package-host-state host)]
           [surface
            (surface-service-ref
              (host-state-surfaces state) (command-context-surface-id context) #f)]
           [window
            (and surface
                 (find
                   (lambda (leaf)
                     (= (window-id leaf) (command-context-window-id context)))
                   (window-leaves (surface-root-window surface))))])
      (and window surface
           (eq? window (surface-selected-window surface))
           (package-host-command-context-current? host context)
           (cons surface window))))

  (define (clone-view-placement! state source clone)
    ;; Point and viewport are View-local placement state.  Pending input is
    ;; deliberately not copied: a prefix belongs to the command sequence that
    ;; opened the split, not to the new Window.
    (let ([source-state (view-state source)]
          [clone-state (view-state clone)])
      (dispatcher-dispatch-view!
        (host-state-dispatch state)
        (make-view-transaction-spec
          (view-id clone) (view-state-generation clone-state)
          (view-state-selection source-state) (view-state-viewport source-state)
          #f '() '() #f))))

  (define (package-host-split-window! host owner context axis focus-policy)
    (unless (and (package-host? host) (owner? owner) (command-context? context)
                 (memq axis '(horizontal vertical))
                 (memq focus-policy '(focus preserve)))
      (assertion-violation 'package-host-split-window!
                           "invalid PackageHost Window split request"
                           host owner context axis focus-policy))
    (let* ([state (package-host-state host)]
           [target (selected-editor-window host context)]
           [views (host-state-views state)]
           [source (and target
                        (view-service-ref views (command-context-view-id context) #f))])
      (and source
           (let ([clone
                  (view-service-create!
                    views owner (view-buffer source)
                    (view-state-configuration (view-state source)))])
             (guard
               (condition
                 [else
                  (view-service-close-view! views (view-id clone))
                  (raise condition)])
               (if (and (clone-view-placement! state source clone)
                        (dispatcher-dispatch-host!
                          (host-state-dispatch state)
                          (make-split-window-view-operation
                            (command-context-surface-id context)
                            (window-id (cdr target)) axis (view-id clone) focus-policy)))
                   clone
                   (begin
                     (view-service-close-view! views (view-id clone))
                     #f)))))))

  (define (package-host-focus-next-window! host context)
    (unless (and (package-host? host) (command-context? context))
      (assertion-violation 'package-host-focus-next-window!
                           "expected a PackageHost and CommandContext" host context))
    (let ([target (selected-editor-window host context)])
      (and target
           (let* ([surface (car target)]
                  [selected (cdr target)]
                  [leaves (window-leaves (surface-root-window surface))]
                  [next
                   (let loop ([remaining leaves])
                     (and (pair? remaining)
                          (if (eq? (car remaining) selected)
                              (if (pair? (cdr remaining)) (cadr remaining) (car leaves))
                              (loop (cdr remaining)))))])
             (and next (not (eq? next selected))
                  (dispatcher-dispatch-host!
                    (host-state-dispatch (package-host-state host))
                    (make-focus-window-operation
                      (surface-id surface) (window-id next))))))))

  (define (delete-window! host surface window)
    (let* ([state (package-host-state host)]
           [views (host-state-views state)]
           [view-id (window-view-id window)]
           [update
            (dispatcher-dispatch-host!
              (host-state-dispatch state)
              (make-remove-window-operation (surface-id surface) (window-id window)))])
      (and update
           (begin
             ;; Removing the Window retires this presentation, not its Buffer.
             (view-service-close-view! views view-id)
             update))))

  (define (package-host-delete-window! host context)
    (unless (and (package-host? host) (command-context? context))
      (assertion-violation 'package-host-delete-window!
                           "expected a PackageHost and CommandContext" host context))
    (let ([target (selected-editor-window host context)])
      (and target (delete-window! host (car target) (cdr target)))))

  (define (package-host-delete-other-windows! host context)
    (unless (and (package-host? host) (command-context? context))
      (assertion-violation 'package-host-delete-other-windows!
                           "expected a PackageHost and CommandContext" host context))
    (let ([target (selected-editor-window host context)])
      (and target
           (let ([surface (car target)] [selected (cdr target)])
             (for-each
               (lambda (window)
                 (unless (eq? window selected)
                   (delete-window! host surface window)))
               (window-leaves (surface-root-window surface)))
             #t))))

  ;; Bury leaves a Buffer alive and returns the selected Window to its recent
  ;; presentation history.  Generated `q` and the user-facing buffer command
  ;; share this operation; neither one is a resource close.
  (define (package-host-bury-window! host context)
    (unless (and (package-host? host) (command-context? context))
      (assertion-violation 'package-host-bury-window!
                           "expected a PackageHost and CommandContext" host context))
    (let* ([target (selected-editor-window host context)]
           [state (package-host-state host)]
           [views (host-state-views state)])
      (and target
           (let* ([surface (car target)]
                  [window (cdr target)]
                  [current (view-service-ref views (window-view-id window) #f)])
             (and current
                  (let ([previous
                         (recent-replacement-view
                           surface views (buffer-id (view-buffer current)))])
                    (and previous
                         (dispatcher-dispatch-host!
                           (host-state-dispatch state)
                           (make-replace-window-view-operation
                             (surface-id surface) (window-id window) (view-id previous)))
                         previous)))))))

  (define (package-host-close-view! host id)
    (view-service-close-view! (host-state-views (package-host-state host)) id))

  (define (package-host-surface-size host surface-id)
    (let ([surface
           (surface-service-ref (host-state-surfaces (package-host-state host)) surface-id #f)])
      (and surface (surface-size surface))))

  (define (package-host-invalidate-surface! host surface-id)
    (unless (package-host? host)
      (assertion-violation 'package-host-invalidate-surface!
                           "expected a PackageHost" host))
    (dispatcher-dispatch-host!
      (host-state-dispatch (package-host-state host))
      (make-invalidate-surface-operation surface-id)))

  ;; Placement owns rollback of a newly-created View.  Feature packages only
  ;; observe success or failure and never repair the Surface tree directly.
  (define (place-view! host operation view-id)
    (if (dispatcher-dispatch-host! (host-state-dispatch (package-host-state host)) operation)
        #t
        (begin
          (package-host-close-view! host view-id)
          #f)))

  ;; Interaction interfaces are ordinary Buffer/View presentations, but their
  ;; placement is an overlay owned by the Surface.  Packages request the two
  ;; supported presentations instead of composing a bare View creation with
  ;; an unrelated Surface operation.  The Host owns rollback in both cases.
  (define (package-host-create-interaction-view!
            host owner buffer configuration surface-id height)
    (let* ([state (package-host-state host)]
           [views (host-state-views state)]
           [created (view-service-create! views owner buffer configuration)])
      (guard
        (condition
          [else
           (view-service-close-view! views (view-id created))
           (raise condition)])
        (and (place-view!
               host
               (make-push-interaction-operation surface-id (view-id created) height)
               (view-id created))
             created))))

  (define (package-host-create-interaction-companion-view!
            host owner buffer configuration surface-id anchor-view-id height)
    (let* ([state (package-host-state host)]
           [views (host-state-views state)]
           [created (view-service-create! views owner buffer configuration)])
      (guard
        (condition
          [else
           (view-service-close-view! views (view-id created))
           (raise condition)])
        (and (place-view!
               host
               (make-add-interaction-companion-operation
                 surface-id anchor-view-id (view-id created) height)
               (view-id created))
             created))))

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

  ;; Delayed command effects and asynchronous package callbacks use this
  ;; operation when feedback belongs to their initiating interaction.  The
  ;; result is discarded after a focus, Buffer, or minibuffer transition;
  ;; durable state belongs to a Buffer presentation or mode line instead.
  (define (package-host-publish-feedback-if-current! host context feedback)
    (unless (and (package-host? host) (command-context? context)
                 (user-feedback? feedback))
      (assertion-violation 'package-host-publish-feedback-if-current!
                           "expected a PackageHost, CommandContext, and UserFeedback"
                           host context feedback))
    (dispatcher-dispatch-host!
      (host-state-dispatch (package-host-state host))
      (make-set-surface-feedback-if-current-operation
        (command-context-surface-id context)
        (command-context-window-id context)
        (command-context-view-id context)
        feedback)))

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
             (command-context-target template) source #f
             (command-context-input-layers template)))))
)
