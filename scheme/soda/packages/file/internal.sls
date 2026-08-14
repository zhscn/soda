(library (soda packages file internal)
  (export make-file-service!
          file-service?
          file-service-resource
          file-service-format
          file-service-conflict
          file-service-recovery
          file-service-watch-service
          file-service-attach-runtime!
          file-service-handle-runtime-event!
          file-service-handle-state-event!
          file-service-add-state-listener!
          file-service-register-mode!
          file-service-modified-count
          file-service-shutdown-effects
          file-service-rename-resource!
          file-service-delete-resource!
          file-conflict?
          file-conflict-buffer-id
          file-conflict-resource
          file-conflict-version
          file-conflict-kind
          file-conflict-status
          file-backup-enabled?
          file-newline-policy
          file-bom-policy
          file-final-newline-policy
          file-keymap)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel location)
          (soda kernel resource)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel mode)
          (soda host command)
          (soda host command-runtime)
          (soda host buffer)
          (soda host package)
          (soda host location)
          (soda host operation)
          (soda host setting)
          (soda host value)
          (soda host view)
          (soda packages base history)
          (soda packages buffer-mode)
          (soda packages edit-policy)
          (soda packages completion)
          (soda packages file-keymap)
          (soda packages file-mode-registry)
          (soda packages file-path)
          (soda packages file-policy)
          (soda packages file-resource-binding)
          (soda packages file-save)
          (soda packages file-service-value)
          (soda packages file-operation)
          (soda packages file-state)
          (soda packages file-watch)
          (soda packages file-visit)
          (soda packages file-format)
          (soda packages file-conflict-workflow)
          (soda packages interaction)
          (soda packages recovery)
          (soda packages resource)
          (soda support vfs))

  ;; FileService owns the association between a Buffer and an external file.
  ;; A file Buffer is catalogued by its canonical resource.  Visiting a file
  ;; therefore creates or reuses shared Buffer state, then creates a View for
  ;; the requesting Window; it never replaces unrelated Buffer contents.
  (define (file-service-register-mode! service owner suffix mode)
    (unless (file-service? service)
      (assertion-violation 'file-service-register-mode!
                           "expected a FileService" service))
    (file-mode-registry-register!
      (file-service-mode-registry service) owner suffix mode))

  (define (file-service-mode-for service resource)
    (file-mode-registry-mode-for
      (file-service-mode-registry service) resource))

  (define (file-prompt-directory service context)
    (let ([resource
           (file-service-resource
             service (command-context-buffer-id context) #f)])
      (if resource
          (vfs-parent-directory (resource-locator resource))
          (current-file-directory))))

  ;; A visited Buffer has no preceding path argument and writes its own
  ;; resource directly.  For a supplied destination, an existing different
  ;; file requires explicit confirmation before a file-write effect is made.
  (define (make-overwrite-reader service)
    (make-interactive-reader
      'overwrite-decision
      (lambda (context arguments)
        (cond
          [(null? arguments) (make-interactive-ready (list 'overwrite))]
          [(and (pair? arguments) (null? (cdr arguments)) (string? (car arguments)))
           (let* ([resource (canonical-file-resource (car arguments))]
                  [path (resource-locator resource)]
                  [exists? (vfs-file-exists? path)]
                  [binding
                   (file-service-binding service (command-context-buffer-id context) #f)]
                  [same-resource?
                   (and binding
                        (string=? path
                                  (resource-locator (file-binding-resource binding))))])
             (if (or same-resource? (not exists?))
                 (make-interactive-ready (list 'overwrite))
                 (make-interactive-suspend
                   (make-overwrite-request path)
                   (lambda (value)
                     (make-interactive-ready (list value))))))]
          [else
           (assertion-violation 'file.write
                                "overwrite decision requires zero or one file name"
                                arguments)]))))

  (define (make-save-file-name-reader service)
    (make-interactive-reader
      'file-name
      (lambda (context arguments)
        (if (file-service-binding service (command-context-buffer-id context) #f)
            (make-interactive-ready '())
            (let* ([base (file-prompt-directory service context)]
                   [source (make-file-name-completion-source base)])
              (make-interactive-suspend
                (make-interaction-request
                  'file-name "Write file: " base source 'free
                  #f 'file-name)
                (lambda (value)
                  (make-interactive-ready
                    (list (vfs-resolve-path base value))))))))))

  (define (file-service-add-state-listener! service owner procedure)
    (unless (file-service? service)
      (assertion-violation 'file-service-add-state-listener!
                           "expected a FileService" service))
    (file-watch-service-add-listener!
      (file-service-watch-service service) owner procedure))

  (define (install-file-command! runtime owner name documentation readers procedure)
    (command-runtime-register-command! runtime
      (make-command-definition
        name procedure owner documentation 'file (make-interactive-plan readers))))

  ;; FileService owns the save and resource-release effects, while Buffer kill
  ;; is a user operation over every Buffer kind.
  (define (install-buffer-command! runtime owner name documentation readers procedure)
    (command-runtime-register-command! runtime
      (make-command-definition
        name procedure owner documentation 'buffer (make-interactive-plan readers))))

  (define (make-decision-request prompt)
    (make-choice-interaction-request
      'save-decision prompt
      (list
        (make-choice-action 'save "Save" (list #\s) 'normal #f)
        (make-choice-action 'discard "Discard" (list #\d) 'destructive #f)
        (make-choice-action 'cancel "Cancel" (list #\c) 'cancel #t))))

  (define (make-discard-request prompt)
    (make-choice-interaction-request
      'discard-decision prompt
      (list
        (make-choice-action 'discard "Discard" (list #\d) 'destructive #f)
        (make-choice-action 'cancel "Cancel" (list #\c) 'cancel #t))))

  ;; The reader evaluates dirty state at command invocation time.  The
  ;; minibuffer is therefore a normal interaction overlay; it does not hold a
  ;; Buffer close transaction open while the user decides.
  ;; `buffer.kill` accepts an optional initial Buffer identity.  Interactive
  ;; invocations without one target the active Buffer; generated result Buffers
  ;; can supply another live target without changing the selected Window.
  (define (make-buffer-close-target-reader)
    (make-interactive-reader
      'buffer-target
      (lambda (context arguments)
        (cond
          [(null? arguments)
           (make-interactive-ready (list (command-context-buffer-id context)))]
          [(and (null? (cdr arguments)) (buffer-id? (car arguments)))
           (make-interactive-ready '())]
          [else
           (assertion-violation 'buffer.kill
                                "expected an optional Buffer identity before close decision"
                                arguments)]))))

  (define (make-buffer-close-decision-reader service)
    (make-interactive-reader
      'save-decision
      (lambda (context arguments)
        (unless (and (pair? arguments) (null? (cdr arguments))
                     (buffer-id? (car arguments)))
          (assertion-violation 'buffer.kill
                               "close decision requires exactly one Buffer identity"
                               arguments))
        (let ([buffer
               (package-host-buffer-ref (file-service-host service)
                                   (car arguments) #f)])
          (cond
            [(modified-file-buffer? service buffer)
             (make-interactive-suspend
               (make-decision-request
                 (string-append "Save changes to " (buffer-name buffer) "?"))
               (lambda (value) (make-interactive-ready (list value))))]
            [(and buffer
                  (file-service-history service)
                  (history-modified?
                    (file-service-history service) (buffer-id buffer)))
             (make-interactive-suspend
               (make-discard-request
                 (string-append "Discard changes to " (buffer-name buffer) "?"))
               (lambda (value) (make-interactive-ready (list value))))]
            [else (make-interactive-ready (list 'discard))])))))

  (define (close-buffer! service target-id)
    (package-host-close-buffer-with-fallback!
      (file-service-host service) (file-service-owner service) target-id))

  (define (make-file-service! host owner history)
    (unless (and (package-host? host) (owner? owner)
                 (or (not history) (history? history)))
      (assertion-violation 'make-file-service! "invalid file service dependencies"
                           host owner history))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-file-keymap)]
           [watch-service (make-file-watch-service owner)]
           [service
            (make-file-service-value
              (make-file-state) host owner history keymap watch-service #f
              (make-file-mode-registry))])
      (file-service-recovery-set!
        service
        (and history
             (make-recovery-service!
               host owner history
               (lambda (buffer-id) (file-service-resource service buffer-id #f)))))
      (register-file-settings! host owner)
      (command-runtime-register-effect-handler!
        runtime 'file.external-resolution owner 'resolve-external-file
        (lambda (ignored invocation effect)
          (let ([request (command-effect-payload effect)])
            (if (automatic-reload-became-dirty? service request)
                (request-conflict-decision!
                  service request (command-invocation-context invocation))
                (guard
                  (condition
                    [else
                     (retry-external-resolution!
                       service request (command-invocation-context invocation))
                     (raise condition)])
                  (resolve-external-file! service request))))))
      ;; Native watchers decode immutable FileStateEvents only.  This command
      ;; is their command-loop handoff: it applies package policy after any
      ;; already queued user input and never opens an interaction by itself.
      (define-command
        runtime owner 'file.handle-state-event (context event)
        (documentation "Apply one observed external file state event.")
        (class 'file)
        (visible #f)
        (undo 'ignore)
        (file-service-handle-state-event! service event context)
        (command-handled))
      (define-command
        runtime owner 'file.external-auto-reload (context buffer-id version)
        (documentation "Reload an unmodified Buffer after a stable external change.")
        (class 'file)
        (visible #f)
        (undo 'ignore)
        (make-command-effect
          'file.external-resolution
          (make-file-external-resolution buffer-id version 'reload #f #f)))
      (define-command
        runtime owner 'file.resolve-external-change
        (context buffer-id version action . arguments)
        (documentation "Resolve a changed-on-disk conflict without applying a stale decision.")
        (class 'file)
        (interactive
          (make-interactive-plan
            (list (make-conflict-target-reader service)
                  (make-external-change-reader service)
                  (make-conflict-save-as-reader service)
                  (make-conflict-overwrite-reader))))
        (undo 'ignore)
        (cond
          [(and (eq? action 'save-as)
                (or (< (length arguments) 3)
                    (eq? (cadr arguments) 'cancel)))
           (command-handled)]
          [else
           (let* ([destination
                    (and (eq? action 'save-as)
                         (canonical-file-resource (car arguments)))]
                  [destination-version (and destination (caddr arguments))])
             (make-command-effect
               'file.external-resolution
               (make-file-external-resolution
                 buffer-id version action destination destination-version)))]))
      (command-runtime-register-effect-handler!
        runtime 'file.visit owner 'open-file-buffer
        (lambda (ignored invocation effect)
          (open-file-buffer! service (command-effect-payload effect))))
      (command-runtime-register-effect-handler!
        runtime 'file.location-open owner 'open-file-location
        (lambda (ignored invocation effect)
          (let ([request (command-effect-payload effect)])
            (unless (file-location-open? request)
              (assertion-violation
                'file.location-open "invalid Location open request" request))
            (ensure-file-buffer!
              service
              (command-invocation-context invocation)
              (location-resource (file-location-open-location request))))))
      (package-host-register-location-provider!
        host owner
        (make-location-provider
          'file
          (lambda (resource)
            (let ([buffer
                   (package-host-find-buffer-key
                     host (file-buffer-key resource) #f)])
              (and buffer
                   (let ([binding
                          (file-service-binding service (buffer-id buffer) #f)])
                     (and binding
                          (resource=? resource (file-binding-resource binding))
                          (buffer-id buffer))))))
          (lambda (location)
            (make-command-effect
              'file.location-open (make-file-location-open location)))))
      (command-runtime-register-effect-handler!
        runtime 'file.load owner 'bind-loaded-file
        (lambda (ignored invocation effect)
          (let ([request (command-effect-payload effect)])
            (unless (file-load? request)
              (assertion-violation 'file.load "invalid file load request" request))
            (let ([binding (file-service-binding service (file-load-buffer-id request) #f)])
              (set-file-resource! service (file-load-buffer-id request)
                             (file-load-resource request) (file-load-version request)
                             (and binding (file-binding-lock binding))
                             (file-load-format request)))
            (clear-file-conflict! service (file-load-buffer-id request))
            (when (and (file-load-discard-history? request) history)
              (history-discard-buffer! history (file-load-buffer-id request)))
            (clear-recovery! service (file-load-buffer-id request)))))
      (command-runtime-register-effect-handler!
        runtime 'file.write owner 'write-file
        (lambda (ignored invocation effect)
          (let ([request (command-effect-payload effect)])
            (unless (file-write? request)
              (assertion-violation 'file.write "invalid file write request" request))
            (let* ([resource (file-write-resource request)]
                   [path (resource-locator resource)]
                   [expected (file-write-expected-version request)]
                   [target
                    (package-host-buffer-ref host (file-write-buffer-id request) #f)]
                   [binding
                    (file-service-binding service (file-write-buffer-id request) #f)]
                   [transfer-lock?
                    (and (file-write-rebind? request)
                         (or (not binding)
                             (not (string=? (resource-locator resource)
                                            (resource-locator
                                              (file-binding-resource binding))))))]
                   [new-lock (and target transfer-lock? (acquire-file-lock resource))])
              (unless target
                (assertion-violation 'file.write "target Buffer is no longer live" request))
              (when (and transfer-lock? (not new-lock))
                (assertion-violation 'file.write "destination is locked by another Soda session" path))
              ;; Verify ownership of the destination before touching it.  A
              ;; failed Save As must not overwrite an open file Buffer owned
              ;; by another resource identity.
              (let ([existing (package-host-find-buffer-key host (file-buffer-key resource) #f)])
                (when (and existing (not (= (buffer-id existing) (buffer-id target))))
                  (assertion-violation 'file.write
                                       "destination is already visited by another Buffer"
                                       path)))
              (when expected
                (unless (vfs-stat-same-version? expected (vfs-stat-path path))
                  (assertion-violation 'file.write "file changed outside Soda" path)))
              (let ([written? #f])
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (when (and (file-backup-enabled?
                                 (buffer-state-configuration (buffer-state target)))
                               (vfs-file-exists? path))
                      (vfs-write-file (file-backup-path path) (vfs-read-file path)))
                    (vfs-write-file path (file-write-contents request))
                    (package-host-rebind-buffer-key! host (file-buffer-key resource) target)
                    (set-file-resource! service (file-write-buffer-id request)
                                   resource (vfs-stat-path path)
                                   (if transfer-lock?
                                       new-lock
                                       (and binding (file-binding-lock binding)))
                                   (file-write-format request) #t)
                    (clear-file-conflict! service (file-write-buffer-id request))
                    (set! written? #t)
                    (when transfer-lock?
                      (release-file-lock! (and binding (file-binding-lock binding)))))
                  (lambda ()
                    (when (and transfer-lock? (not written?))
                      (release-file-lock! new-lock))))))
            (when history
              (history-mark-saved! history (file-write-buffer-id request)))
            (clear-recovery! service (file-write-buffer-id request)))))
      (command-runtime-register-effect-handler!
        runtime 'buffer.kill owner 'kill-buffer
        (lambda (ignored invocation effect)
          (let ([request (command-effect-payload effect)])
            (unless (file-close? request)
              (assertion-violation 'buffer.kill "invalid Buffer kill request" request))
            (close-buffer! service (file-close-buffer-id request)))))
      (command-runtime-register-effect-handler!
        runtime 'file.insert owner 'insert-file-contents
        (lambda (runtime invocation effect)
          (let ([request (command-effect-payload effect)])
            (unless (file-insert? request)
              (assertion-violation 'file.insert "invalid file insert request" request))
            ;; Reading is an external effect.  The actual edit returns through
            ;; the ordinary fundamental command, retaining its multi-selection
            ;; mapping, History integration, and transaction boundary.
            (call-with-values
              (lambda ()
                (decode-file-contents
                  (vfs-read-file
                    (resource-locator (file-insert-resource request)))))
              (lambda (contents ignored-format)
                (command-runtime-enqueue!
                  runtime
                  (make-command-invoke-message
                    'fundamental.insert-text
                    (file-insert-context request)
                    (list contents) #f)))))))
      (install-file-command! runtime owner 'file.visit "Visit a file in the active Window."
        (list (make-file-name-reader
                "Visit file: "
                (lambda (context) (file-prompt-directory service context))))
        (lambda (context path)
          (make-command-effect 'file.visit
            (make-file-visit context (canonical-file-resource path)))))
      (install-file-command! runtime owner 'file.insert
        "Insert a file's contents at every active selection."
        (list (make-file-name-reader
                "Insert file: "
                (lambda (context) (file-prompt-directory service context))))
        (lambda (context path)
          (make-command-effect
            'file.insert
            (make-file-insert context (canonical-file-resource path)))))
      (install-file-command! runtime owner 'file.revert "Reload the active Buffer's visited file." '()
        (lambda (context)
          (let ([binding (file-service-binding service (command-context-buffer-id context) #f)])
            (if (not binding)
                (command-handled)
                (let* ([resource (file-binding-resource binding)]
                       [version (vfs-stat-path (resource-locator resource))])
                  (call-with-values
                    (lambda ()
                      (decode-file-contents
                        (vfs-read-file (resource-locator resource))))
                    (lambda (contents format)
                      (list
                        (replace-buffer-contents context contents)
                        (make-command-effect 'file.load
                          (make-file-load
                            (command-context-buffer-id context)
                            resource version format #t))))))))))
      (install-file-command! runtime owner 'file.toggle-backup
        "Toggle adjacent backup creation before writing an existing file."
        '()
        (lambda (context) (toggle-file-backup context)))
      (install-file-command! runtime owner 'file.save "Write the active Buffer to its visited file."
        (list (make-save-file-name-reader service) (make-overwrite-reader service))
        (lambda (context . arguments)
          (let ([binding (file-service-binding service (command-context-buffer-id context) #f)])
            (if binding
                (if (or (null? arguments)
                        (and (pair? arguments) (eq? (car arguments) 'overwrite)))
                    (make-file-write-effect
                      service
                      (command-context-buffer-id context)
                      (command-context-buffer-state context)
                      (file-binding-resource binding) (file-binding-version binding) #f)
                    (command-handled))
                (if (or (null? arguments) (not (string? (car arguments)))
                        (and (pair? (cdr arguments))
                             (not (eq? (cadr arguments) 'overwrite))))
                    (command-handled)
                    (let ([resource (canonical-file-resource (car arguments))])
                      (make-file-write-effect
                        service
                        (command-context-buffer-id context)
                        (command-context-buffer-state context)
                        resource #f #t)))))))
      (install-file-command! runtime owner 'file.save-as "Write the active Buffer to a file and visit it."
        (list (make-file-name-reader
                "Write file: "
                (lambda (context) (file-prompt-directory service context)))
              (make-overwrite-reader service))
        (lambda (context path . decisions)
          ;; A direct command invocation is an explicit noninteractive API
          ;; request.  It keeps the historical one-path calling convention;
          ;; terminal interaction always supplies an overwrite decision.
          (let ([decision (if (null? decisions) 'overwrite (car decisions))])
            (if (eq? decision 'overwrite)
                (let ([resource (canonical-file-resource path)])
                  (make-file-write-effect
                    service (command-context-buffer-id context)
                    (command-context-buffer-state context) resource #f #t))
                (command-handled)))))
      (install-buffer-command! runtime owner 'buffer.kill "Kill the active Buffer."
        (list (make-buffer-close-target-reader)
              (make-buffer-close-decision-reader service))
        (lambda (context target-id decision)
          (case decision
            [(cancel) (command-handled)]
            [(save)
             (let* ([target (package-host-buffer-ref host target-id #f)]
                    [binding (and target (file-service-binding service target-id #f))])
               (if (not target)
                   (command-handled)
                   (if binding
                       (list
                         (make-file-write-effect
                           service
                           target-id
                           (buffer-state target)
                           (file-binding-resource binding) (file-binding-version binding) #f)
                         (make-command-effect 'buffer.kill (make-file-close target-id)))
                       (make-command-effect 'buffer.kill (make-file-close target-id)))))]
            [else
             (make-command-effect 'buffer.kill (make-file-close target-id))])))
      (package-host-add-buffer-close-listener!
        host owner
        (lambda (buffer)
          (let ([binding (file-service-binding service (buffer-id buffer) #f)])
            (when binding (release-file-lock! (file-binding-lock binding))))
          (file-watch-service-unregister!
            (file-service-watch-service service) (buffer-id buffer))
          (file-state-delete-buffer!
            (file-service-state service) (buffer-id buffer))
          (clear-recovery! service (buffer-id buffer))
          (when history (history-discard-buffer! history (buffer-id buffer)))))
      service))
)
