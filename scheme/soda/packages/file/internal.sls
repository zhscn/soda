(library (soda packages file internal)
  (export make-file-service!
          file-service?
          file-service-resource
          file-service-format
          file-service-conflict
          file-service-recovery
          file-service-start-recovery!
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
          (soda packages file-operation)
          (soda packages file-state)
          (soda packages file-watch)
          (soda packages file-format)
          (soda packages interaction)
          (soda packages recovery)
          (soda packages resource)
          (soda support vfs))

  ;; FileService owns the association between a Buffer and an external file.
  ;; A file Buffer is catalogued by its canonical resource.  Visiting a file
  ;; therefore creates or reuses shared Buffer state, then creates a View for
  ;; the requesting Window; it never replaces unrelated Buffer contents.
  (define-record-type
    (file-service %make-file-service file-service?)
    (fields
      (immutable state file-service-state)
      (immutable host file-service-host)
      (immutable owner file-service-owner)
      (immutable history file-service-history)
      (immutable keymap file-keymap)
      (immutable watch-service file-service-watch-service)
      (mutable recovery file-service-recovery file-service-recovery-set!)
      (immutable mode-registry file-service-mode-registry)))

  (define (file-service-register-mode! service owner suffix mode)
    (unless (file-service? service)
      (assertion-violation 'file-service-register-mode!
                           "expected a FileService" service))
    (file-mode-registry-register!
      (file-service-mode-registry service) owner suffix mode))

  (define (file-service-mode-for service resource)
    (file-mode-registry-mode-for
      (file-service-mode-registry service) resource))

  (define (overwrite-decision value)
    (cond
      [(and (string? value) (string-ci=? value "yes")) 'overwrite]
      [(and (string? value) (string-ci=? value "no")) 'cancel]
      [else
       (assertion-violation 'file.write "expected yes or no" value)]))

  (define (make-overwrite-request path)
    (make-interaction-request
      'overwrite-decision
      (string-append "File exists: " path ". Overwrite? (yes/no) ")
      #f #f 'free
      (lambda (value ignored)
        (and (string? value)
             (or (string-ci=? value "yes") (string-ci=? value "no"))))))

  (define (external-change-decision value)
    (let ([text
           (cond [(symbol? value) (symbol->string value)]
                 [(string? value) value]
                 [else ""])])
      (cond
        [(or (string-ci=? text "r") (string-ci=? text "reload")) 'reload]
        [(or (string-ci=? text "o") (string-ci=? text "overwrite")) 'overwrite]
        [(or (string-ci=? text "s") (string-ci=? text "save-as")) 'save-as]
        [(or (string-ci=? text "i") (string-ci=? text "ignore")) 'ignore]
        [else
         (assertion-violation
           'file.resolve-external-change
           "expected reload, overwrite, save-as, or ignore" value)])))

  (define (make-external-change-reader service)
    (make-interactive-reader
      'external-change-decision
      (lambda (context arguments)
        (unless (and (= (length arguments) 2)
                     (buffer-id? (car arguments)))
          (assertion-violation 'file.resolve-external-change
                               "invalid external conflict arguments" arguments))
        (let* ([binding (file-service-binding service (car arguments) #f)]
               [path
                (if binding
                    (resource-locator (file-binding-resource binding))
                    "file")])
          (make-interactive-suspend
            (make-interaction-request
              'external-file-change
              (string-append
                "File changed on disk: " path
                ". Reload, overwrite, save-as, or ignore? (r/o/s/i) ")
              #f #f 'free
              (lambda (value ignored)
                (guard (condition [else #f])
                  (external-change-decision value)
                  #t))
              (list #\r #\o #\s #\i))
            (lambda (value)
              (make-interactive-ready
                (list (external-change-decision value)))))))))

  (define (make-conflict-target-reader service)
    (make-interactive-reader
      'external-conflict
      (lambda (context arguments)
        (cond
          [(null? arguments)
           (let ([conflict
                  (file-service-conflict
                    service (command-context-buffer-id context) #f)])
             (unless conflict
               (assertion-violation 'file.resolve-external-change
                                    "active Buffer has no external file conflict"))
             (make-interactive-ready
               (list (file-conflict-buffer-id conflict)
                     (file-conflict-version conflict))))]
          [(= (length arguments) 2) (make-interactive-ready '())]
          [else
           (assertion-violation 'file.resolve-external-change
                                "invalid external conflict target" arguments)]))))

  (define (make-conflict-save-as-reader)
    (make-interactive-reader
      'file-name
      (lambda (context arguments)
        (if (and (= (length arguments) 3)
                 (eq? (caddr arguments) 'save-as))
            (make-interactive-suspend
              (make-interaction-request
                'file-name "Write local contents to: "
                #f file-name-completion-source 'free)
              (lambda (value) (make-interactive-ready (list value))))
            (make-interactive-ready '())))))

  (define (make-conflict-overwrite-reader)
    (make-interactive-reader
      'overwrite-decision
      (lambda (context arguments)
        (if (and (= (length arguments) 4)
                 (eq? (caddr arguments) 'save-as)
                 (string? (cadddr arguments))
                 (vfs-file-exists?
                   (resource-locator
                     (canonical-file-resource (cadddr arguments)))))
            (let* ([resource (canonical-file-resource (cadddr arguments))]
                   [path (resource-locator resource)]
                   [version (vfs-stat-path path)])
              (make-interactive-suspend
                (make-overwrite-request path)
                (lambda (value)
                  (make-interactive-ready
                    (list (overwrite-decision value) version)))))
            (make-interactive-ready (list 'overwrite #f))))))

  (define (file-service-binding service buffer-id . default)
    (unless (and (file-service? service) (buffer-id? buffer-id))
      (assertion-violation 'file-service-binding "expected a file service and Buffer id"
                           service buffer-id))
    (file-state-binding
      (file-service-state service) buffer-id
      (if (null? default) #f (car default))))

  (define (file-service-resource service buffer-id . default)
    (let ([binding (file-service-binding service buffer-id #f)])
      (if binding
          (file-binding-resource binding)
          (if (null? default) #f (car default)))))

  (define (file-service-format service buffer-id . default)
    (let ([binding (file-service-binding service buffer-id #f)])
      (if binding
          (file-binding-format binding)
          (if (null? default) #f (car default)))))

  (define (file-service-binding-at-path service path)
    (file-state-binding-at-path (file-service-state service) path))

  ;; Directory packages delegate file mutations here so Buffer identity,
  ;; locks, watches, and resource keys change as one host-owned operation.
  (define (file-service-rename-resource! service source destination expected)
    (unless (file-service? service)
      (assertion-violation 'file-service-rename-resource!
                           "expected a FileService" service))
    (let ([target (canonical-file-resource destination)])
      (let-values ([(buffer-id binding)
                    (file-service-binding-at-path service source)])
        (if (not binding)
            (vfs-rename-path-if-matches! source destination expected)
            (let* ([host (file-service-host service)]
                   [buffer (package-host-buffer-ref host buffer-id #f)]
                   [existing
                    (package-host-find-buffer-key
                      host (file-buffer-key target) #f)])
              (unless buffer
                (assertion-violation 'file-service-rename-resource!
                                     "visited file Buffer is no longer live" source))
              (when (and existing (not (= (buffer-id existing) buffer-id)))
                (assertion-violation 'file-service-rename-resource!
                                     "destination is already visited" destination))
              (let ([new-lock (acquire-file-lock target)]
                    [renamed? #f]
                    [committed? #f])
                (unless new-lock
                  (assertion-violation 'file-service-rename-resource!
                                       "destination is locked" destination))
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (vfs-rename-path-if-matches! source destination expected)
                    (set! renamed? #t)
                    (package-host-rebind-buffer-key!
                      host (file-buffer-key target) buffer)
                    (set-resource!
                      service buffer-id target (vfs-stat-path destination)
                      new-lock (file-binding-format binding) #t)
                    (release-file-lock! (file-binding-lock binding))
                    (clear-conflict! service buffer-id)
                    (set! committed? #t)
                    destination)
                  (lambda ()
                    (unless committed?
                      (when renamed? (vfs-rename-path! destination source))
                      (release-file-lock! new-lock))))))))))

  (define (file-service-delete-resource! service path expected)
    (unless (file-service? service)
      (assertion-violation 'file-service-delete-resource!
                           "expected a FileService" service))
    (let-values ([(buffer-id binding)
                  (file-service-binding-at-path service path)])
      (vfs-delete-path-if-matches! path expected)
      (when binding
        (release-file-lock! (file-binding-lock binding))
        (set-resource!
          service buffer-id (file-binding-resource binding) #f #f
          (file-binding-format binding) #t)
        (file-state-set-conflict!
          (file-service-state service) buffer-id
          (make-file-conflict
            buffer-id (file-binding-resource binding) #f 'deleted 'pending)))
      #t))

  (define (file-service-conflict service buffer-id . default)
    (unless (and (file-service? service) (buffer-id? buffer-id))
      (assertion-violation 'file-service-conflict
                           "expected a FileService and Buffer id"
                           service buffer-id))
    (file-state-conflict
      (file-service-state service) buffer-id
      (if (null? default) #f (car default))))

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
                     (make-interactive-ready (list (overwrite-decision value)))))))]
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
            (make-interactive-suspend
              (make-interaction-request
                'file-name "Write file: " #f file-name-completion-source 'free)
              (lambda (value) (make-interactive-ready (list value))))))))

  (define set-resource!
    (case-lambda
      [(service buffer-id resource version)
       (set-resource! service buffer-id resource version #f
                      (make-default-file-format) #f)]
      [(service buffer-id resource version lock)
       (set-resource! service buffer-id resource version lock
                      (make-default-file-format) #f)]
      [(service buffer-id resource version lock format)
       (set-resource! service buffer-id resource version lock format #f)]
      [(service buffer-id resource version lock format local?)
       (unless (file-format? format)
         (assertion-violation 'set-resource!
                              "expected file format metadata" format))
       (let ([binding (make-file-binding resource version lock format)])
         (file-state-set-binding! (file-service-state service) buffer-id binding)
         (file-watch-service-update!
           (file-service-watch-service service) buffer-id
           (resource-locator resource) version local?)
         binding)]))

  (define (file-service-attach-runtime! service runtime)
    (unless (file-service? service)
      (assertion-violation 'file-service-attach-runtime!
                           "expected a FileService" service))
    (file-watch-service-attach-runtime!
      (file-service-watch-service service) runtime)
    service)

  (define (file-version=? left right)
    (or (and (not left) (not right))
        (and left right (vfs-stat-same-version? left right))))

  (define (same-conflict-event? conflict event)
    (and conflict
         (file-version=? (file-conflict-version conflict)
                         (file-state-event-version event))
         (eq? (file-conflict-kind conflict) (file-state-event-kind event))))

  (define (file-service-handle-state-event! service event context)
    (unless (and (file-service? service) (file-state-event? event)
                 (command-context? context))
      (assertion-violation 'file-service-handle-state-event!
                           "expected a FileService, FileStateEvent, and CommandContext"
                           service event context))
    (when (and (eq? (file-state-event-origin event) 'external)
               (not (eq? (file-state-event-kind event) 'metadata)))
      (let* ([buffer-id (file-state-event-buffer-id event)]
             [buffer
              (package-host-buffer-ref
                (file-service-host service) buffer-id #f)]
             [binding (file-service-binding service buffer-id #f)]
             [existing (file-service-conflict service buffer-id #f)])
        (when (and buffer binding
                   (string=? (file-state-event-path event)
                             (resource-locator (file-binding-resource binding)))
                   (not (same-conflict-event? existing event)))
          (let* ([modified?
                  (or (not (file-service-history service))
                      (history-modified?
                        (file-service-history service) buffer-id))]
                 [automatic?
                  (and (not modified?)
                       (memq (file-state-event-kind event)
                             '(modified replaced))
                       (file-state-event-version event))]
                 [conflict
                  (make-file-conflict
                    buffer-id
                    (file-binding-resource binding)
                    (file-state-event-version event)
                    (file-state-event-kind event)
                    (if automatic? 'reloading 'pending))])
            (file-state-set-conflict!
              (file-service-state service) buffer-id conflict)
            (command-runtime-enqueue!
              (package-host-command-runtime (file-service-host service))
              (make-command-invoke-message
                (if automatic?
                    'file.external-auto-reload
                    'file.resolve-external-change)
                context (list buffer-id (file-state-event-version event))
                (not automatic?))))))))

  (define file-service-handle-runtime-event!
    (case-lambda
      [(service event)
       (unless (file-service? service)
         (assertion-violation 'file-service-handle-runtime-event!
                              "expected a FileService" service))
       (file-watch-service-handle-runtime-event!
         (file-service-watch-service service) event)]
      [(service event context)
       (unless (command-context? context)
         (assertion-violation 'file-service-handle-runtime-event!
                              "expected a CommandContext" context))
       (let ([events (file-service-handle-runtime-event! service event)])
         (when events
           (for-each
             (lambda (state-event)
               (file-service-handle-state-event! service state-event context))
             events))
         events)]))

  (define (file-service-add-state-listener! service owner procedure)
    (unless (file-service? service)
      (assertion-violation 'file-service-add-state-listener!
                           "expected a FileService" service))
    (file-watch-service-add-listener!
      (file-service-watch-service service) owner procedure))

  (define (file-service-start-recovery! service context)
    (unless (file-service? service)
      (assertion-violation 'file-service-start-recovery!
                           "expected a FileService" service))
    (let ([recovery (file-service-recovery service)])
      (and recovery (recovery-service-start! recovery context))))

  (define (file-buffer-configuration service resource context lock-conflict?)
    ;; New file Buffers inherit ordinary editing configuration from the active
    ;; Buffer.  The lock compartment is replaced at this boundary so a prior
    ;; conflict cannot make unrelated files read-only.
    (let* ([base (buffer-state-configuration (command-context-buffer-state context))]
           [mode (file-service-mode-for service resource)]
           [mode-configuration
            (if mode
                (configuration-reconfigure
                  base buffer-major-mode-compartment
                  (make-buffer-mode-extension mode))
                base)]
           [extensions
            (filter
              (lambda (extension)
                (not (and (compartment-entry? extension)
                          (eq? (compartment-entry-compartment extension)
                               file-lock-read-only-compartment))))
              (configuration-extensions mode-configuration))])
      (make-configuration
        (append extensions
                (list
                  (compartment-of
                    file-lock-read-only-compartment
                    (if lock-conflict?
                        (make-buffer-read-only-extension #t)
                        '())))))))

  (define (file-buffer-key resource)
    (make-buffer-key 'file (resource-locator resource)))

  (define (empty-bytes)
    (make-bytevector 0))

  (define (resource-contents resource)
    (let ([path (resource-locator resource)])
      (if (vfs-file-exists? path)
          (call-with-values
            (lambda () (decode-file-contents (vfs-read-file path)))
            (lambda (contents format)
              (values contents (vfs-stat-path path) format)))
          (values (empty-bytes) #f (make-default-file-format)))))

  ;; Loading a Resource and displaying it are separate lifecycle actions.
  ;; Location resolution uses this operation without changing any Window;
  ;; an explicit file visit adds placement after the Buffer is available.
  (define (ensure-file-buffer! service context resource)
    (let* ([host (file-service-host service)]
           [key (file-buffer-key resource)])
      (package-host-open-or-create-buffer!
        host (file-service-owner service) key
        (lambda ()
          (let ([lock (acquire-file-lock resource)] [created? #f])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (call-with-values
                  (lambda () (resource-contents resource))
                  (lambda (contents version format)
                    (let ([created
                           (package-host-create-buffer!
                             host (file-service-owner service)
                             (resource-locator resource)
                             (make-document contents)
                             (file-buffer-configuration
                               service resource context (not lock)))])
                      (set-resource!
                        service (buffer-id created) resource version lock format)
                      (when (file-service-history service)
                        (history-mark-saved! (file-service-history service)
                                             (buffer-id created)))
                      (set! created? #t)
                      created))))
              (lambda ()
                (unless created? (release-file-lock! lock)))))))))

  (define (open-file-buffer! service request)
    (unless (file-visit? request)
      (assertion-violation 'file.visit "invalid file visit request" request))
    (let* ([context (file-visit-context request)]
           [resource (file-visit-resource request)]
           [host (file-service-host service)]
           [buffer (ensure-file-buffer! service context resource)]
           [current-id (command-context-buffer-id context)])
      (if (= (buffer-id buffer) current-id)
          buffer
          (let* ([surface-id (command-context-surface-id context)]
                 [window-id (command-context-window-id context)])
            (unless (and (buffer-id? surface-id) (buffer-id? window-id))
              (assertion-violation 'file.visit
                                   "file visit requires a routed Window context" context))
            (let ([view
                   (package-host-create-view!
                     host (file-service-owner service) buffer
                     (buffer-state-configuration (buffer-state buffer)))])
              (unless
                (package-host-replace-window-view! host surface-id window-id (view-id view))
                (assertion-violation 'file.visit "origin Window is no longer available" context))
              buffer)))))

  (define (reset-selection)
    (make-selection (list (make-selection-range 0 0))))

  (define (replace-buffer-contents context contents)
    (let* ([state (command-context-buffer-state context)]
           [length (snapshot-byte-size (buffer-state-document state))])
      (make-transaction-spec
        (command-context-buffer-id context)
        (command-context-view-id context)
        (buffer-state-generation state)
        (make-change-set length (list (make-text-change 0 length contents)))
        (reset-selection) '() '())))

  (define (install-file-command! runtime owner name documentation readers procedure)
    (command-runtime-register-command! runtime
      (make-command-definition
        name procedure owner documentation 'file (make-interactive-plan readers))))

  (define (encode-buffer-for-write service buffer-id state)
    (let* ([binding (file-service-binding service buffer-id #f)]
           [format (if binding (file-binding-format binding)
                       (make-default-file-format))]
           [configuration (buffer-state-configuration state)])
      (encode-file-contents
        (snapshot-bytevector (buffer-state-document state)) format
        (file-newline-policy configuration)
        (file-bom-policy configuration)
        (file-final-newline-policy configuration))))

  (define (make-file-write-effect service buffer-id state resource version rebind?)
    (call-with-values
      (lambda () (encode-buffer-for-write service buffer-id state))
      (lambda (contents format)
        (make-command-effect
          'file.write
          (make-file-write
            buffer-id resource contents format version rebind?)))))

  (define (toggle-backup context)
    (let* ([buffer-state (command-context-buffer-state context)]
           [enabled? (file-backup-enabled? (buffer-state-configuration buffer-state))]
           [effect
            (make-compartment-reconfigure-effect
              file-backup-compartment
              (make-file-backup-extension (not enabled?)))]
           [update
            (make-transaction-spec
              (command-context-buffer-id context)
              (command-context-view-id context)
              (buffer-state-generation buffer-state)
              (make-change-set
                (snapshot-byte-size (buffer-state-document buffer-state)) '())
              #f (list effect) '())]
           [surface-id (command-context-surface-id context)])
      (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
          (list update
                (make-set-surface-message-operation
                  surface-id
                  (string-append "File backups "
                                 (if enabled? "disabled" "enabled"))))
          update)))

  (define (modified-file-buffer? service buffer)
    (and buffer
         (file-service-binding service (buffer-id buffer) #f)
         (file-service-history service)
         (history-modified? (file-service-history service) (buffer-id buffer))))

  (define (modified-file-buffers service)
    (filter
      (lambda (buffer) (modified-file-buffer? service buffer))
      (package-host-buffers (file-service-host service))))

  (define (file-service-modified-count service)
    (unless (file-service? service)
      (assertion-violation 'file-service-modified-count
                           "expected a FileService" service))
    (length (modified-file-buffers service)))

  ;; Application composition owns the shutdown command and decision.  The
  ;; FileService contributes only the file-save effects required by that
  ;; decision, preserving binding/version policy inside its capability.
  (define (file-service-shutdown-effects service decision)
    (unless (and (file-service? service)
                 (memq decision '(save discard cancel)))
      (assertion-violation 'file-service-shutdown-effects
                           "expected a FileService and shutdown decision"
                           service decision))
    (if (eq? decision 'save)
        (map
          (lambda (buffer)
            (let ([binding (file-service-binding service (buffer-id buffer))])
              (make-file-write-effect
                service (buffer-id buffer) (buffer-state buffer)
                (file-binding-resource binding) (file-binding-version binding) #f)))
          (modified-file-buffers service))
        '()))

  (define (close-decision value)
    (cond
      [(and (string? value) (string-ci=? value "save")) 'save]
      [(and (string? value) (string-ci=? value "discard")) 'discard]
      [(and (string? value) (string-ci=? value "cancel")) 'cancel]
      [else
       (assertion-violation 'file.close
                            "expected save, discard, or cancel"
                            value)]))

  (define (make-decision-request prompt)
    (make-interaction-request
      'save-decision prompt #f #f 'free
      (lambda (value ignored)
        (and (string? value)
             (or (string-ci=? value "save")
                 (string-ci=? value "discard")
                 (string-ci=? value "cancel"))))))

  ;; The reader evaluates dirty state at command invocation time.  The
  ;; minibuffer is therefore a normal interaction overlay; it does not hold a
  ;; Buffer close transaction open while the user decides.
  ;; `file.close` accepts an optional initial Buffer identity.  Interactive
  ;; invocations without one close the active Buffer; generated result Buffers
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
           (assertion-violation 'file.close
                                "expected an optional Buffer identity before close decision"
                                arguments)]))))

  (define (make-buffer-close-decision-reader service)
    (make-interactive-reader
      'save-decision
      (lambda (context arguments)
        (unless (and (pair? arguments) (null? (cdr arguments))
                     (buffer-id? (car arguments)))
          (assertion-violation 'file.close
                               "close decision requires exactly one Buffer identity"
                               arguments))
        (let ([buffer
               (package-host-buffer-ref (file-service-host service)
                                   (car arguments) #f)])
          (if (modified-file-buffer? service buffer)
              (make-interactive-suspend
                (make-decision-request
                  (string-append "Save changes to " (buffer-name buffer)
                                 "? (save/discard/cancel) "))
                (lambda (value)
                  (make-interactive-ready (list (close-decision value)))))
              (make-interactive-ready (list 'discard)))))))

  (define (close-buffer! service target-id)
    (package-host-close-buffer-with-fallback!
      (file-service-host service) (file-service-owner service) target-id))

  (define (current-resource-version resource)
    (let ([path (resource-locator resource)])
      (and (vfs-file-exists? path) (vfs-stat-path path))))

  (define (require-observed-version! resource expected)
    (let ([current (current-resource-version resource)])
      (unless (file-version=? current expected)
        (assertion-violation
          'file.resolve-external-change
          "file changed again while awaiting a conflict decision"
          (resource-locator resource)))
      current))

  (define (conflict-for-resolution service request)
    (unless (file-external-resolution? request)
      (assertion-violation 'file.resolve-external-change
                           "invalid external file resolution" request))
    (let ([conflict
           (file-service-conflict
             service (file-external-resolution-buffer-id request) #f)])
      (unless (and conflict
                   (file-version=?
                     (file-conflict-version conflict)
                     (file-external-resolution-version request)))
        (assertion-violation 'file.resolve-external-change
                             "external file conflict is stale" request))
      conflict))

  (define (clear-conflict! service buffer-id)
    (file-state-clear-conflict! (file-service-state service) buffer-id))

  (define (clear-recovery! service buffer-id)
    (let ([recovery (file-service-recovery service)])
      (when recovery (recovery-service-clear-buffer! recovery buffer-id))))

  (define (replace-live-buffer-contents! service buffer contents version format)
    (let* ([state (buffer-state buffer)]
           [length (snapshot-byte-size (buffer-state-document state))])
      (package-host-dispatch!
        (file-service-host service)
        (make-transaction-spec
          (buffer-id buffer) (buffer-state-generation state)
          (make-change-set length (list (make-text-change 0 length contents)))))
      (let* ([binding (file-service-binding service (buffer-id buffer))]
             [resource (file-binding-resource binding)])
        (set-resource! service (buffer-id buffer) resource version
                       (file-binding-lock binding) format #f))
      (when (file-service-history service)
        (history-discard-buffer! (file-service-history service) (buffer-id buffer))
        (history-mark-saved! (file-service-history service) (buffer-id buffer)))
      (clear-recovery! service (buffer-id buffer))))

  (define (reload-conflicted-buffer! service conflict)
    (let* ([resource (file-conflict-resource conflict)]
           [expected (file-conflict-version conflict)]
           [before (require-observed-version! resource expected)])
      (unless before
        (assertion-violation 'file.resolve-external-change
                             "cannot reload a deleted file"
                             (resource-locator resource)))
      (call-with-values
        (lambda ()
          (decode-file-contents (vfs-read-file (resource-locator resource))))
        (lambda (contents format)
          (let ([after (current-resource-version resource)])
            (unless (file-version=? before after)
              (assertion-violation 'file.resolve-external-change
                                   "file changed while it was being reloaded"
                                   (resource-locator resource)))
            (let ([buffer
                   (package-host-buffer-ref
                     (file-service-host service)
                     (file-conflict-buffer-id conflict) #f)])
              (unless buffer
                (assertion-violation 'file.resolve-external-change
                                     "conflicted Buffer is no longer live" conflict))
              (replace-live-buffer-contents! service buffer contents after format)
              (clear-conflict! service (buffer-id buffer))))))))

  (define (write-current-buffer! service conflict)
    (let* ([resource (file-conflict-resource conflict)]
           [_current
            (require-observed-version! resource (file-conflict-version conflict))]
           [buffer
            (package-host-buffer-ref
              (file-service-host service) (file-conflict-buffer-id conflict) #f)])
      (unless buffer
        (assertion-violation 'file.resolve-external-change
                             "conflicted Buffer is no longer live" conflict))
      (let ([path (resource-locator resource)]
            [state (buffer-state buffer)])
        (when (and (file-backup-enabled?
                     (buffer-state-configuration (buffer-state buffer)))
                   (vfs-file-exists? path))
          (vfs-write-file (file-backup-path path) (vfs-read-file path)))
        (call-with-values
          (lambda () (encode-buffer-for-write service (buffer-id buffer) state))
          (lambda (contents format)
            (vfs-write-file path contents)
            (let* ([binding (file-service-binding service (buffer-id buffer))]
                   [version (vfs-stat-path path)])
              (set-resource! service (buffer-id buffer) resource version
                             (file-binding-lock binding) format #t)
              (when (file-service-history service)
                (history-mark-saved!
                  (file-service-history service) (buffer-id buffer)))
              (clear-recovery! service (buffer-id buffer))
              (clear-conflict! service (buffer-id buffer))))))))

  (define (save-conflicted-buffer-as! service conflict destination expected-destination)
    (let* ([source (file-conflict-resource conflict)]
           [_source-current
            (require-observed-version! source (file-conflict-version conflict))]
           [current-destination (current-resource-version destination)]
           [host (file-service-host service)]
           [buffer
            (package-host-buffer-ref
              host (file-conflict-buffer-id conflict) #f)])
      (unless (file-version=? current-destination expected-destination)
        (assertion-violation 'file.resolve-external-change
                             "save-as destination changed while awaiting confirmation"
                             (resource-locator destination)))
      (unless buffer
        (assertion-violation 'file.resolve-external-change
                             "conflicted Buffer is no longer live" conflict))
      (let ([existing
             (package-host-find-buffer-key host (file-buffer-key destination) #f)])
        (when (and existing (not (= (buffer-id existing) (buffer-id buffer))))
          (assertion-violation 'file.resolve-external-change
                               "save-as destination is already visited"
                               (resource-locator destination))))
      (let* ([old-binding (file-service-binding service (buffer-id buffer))]
             [same-resource?
              (resource=? destination (file-binding-resource old-binding))]
             [new-lock
              (and (not same-resource?) (acquire-file-lock destination))]
             [written? #f])
        (when (and (not same-resource?) (not new-lock))
          (assertion-violation 'file.resolve-external-change
                               "save-as destination is locked"
                               (resource-locator destination)))
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (call-with-values
              (lambda ()
                (encode-buffer-for-write
                  service (buffer-id buffer) (buffer-state buffer)))
              (lambda (contents format)
                (vfs-write-file (resource-locator destination) contents)
                (package-host-rebind-buffer-key!
                  host (file-buffer-key destination) buffer)
                (set-resource!
                  service (buffer-id buffer) destination
                  (vfs-stat-path (resource-locator destination))
                  (if same-resource? (file-binding-lock old-binding) new-lock)
                  format #t)))
            (set! written? #t)
            (unless same-resource?
              (release-file-lock! (file-binding-lock old-binding)))
            (when (file-service-history service)
              (history-mark-saved! (file-service-history service) (buffer-id buffer)))
            (clear-recovery! service (buffer-id buffer))
            (clear-conflict! service (buffer-id buffer)))
          (lambda ()
            (when (and new-lock (not written?)) (release-file-lock! new-lock)))))))

  (define (resolve-external-file! service request)
    (let* ([conflict (conflict-for-resolution service request)]
           [action (file-external-resolution-action request)])
      ;; Every resolution, including ignore, validates the exact disk state
      ;; that was presented to the user.
      (require-observed-version!
        (file-conflict-resource conflict) (file-conflict-version conflict))
      (case action
        [(reload) (reload-conflicted-buffer! service conflict)]
        [(overwrite) (write-current-buffer! service conflict)]
        [(save-as)
         (save-conflicted-buffer-as!
           service conflict
           (file-external-resolution-destination request)
           (file-external-resolution-destination-version request))]
        [(ignore) (file-conflict-status-set! conflict 'ignored)]
        [else
         (assertion-violation 'file.resolve-external-change
                              "unknown external file resolution" action)])))

  (define (retry-external-resolution! service request context)
    (let* ([buffer-id (file-external-resolution-buffer-id request)]
           [old (file-service-conflict service buffer-id #f)]
           [buffer
            (package-host-buffer-ref
              (file-service-host service) buffer-id #f)])
      (when (and old buffer)
        (let* ([version (current-resource-version (file-conflict-resource old))]
               [automatic?
                (and (eq? (file-conflict-status old) 'reloading)
                     version
                     (file-service-history service)
                     (not (history-modified?
                            (file-service-history service) buffer-id)))]
               [next
                (make-file-conflict
                  buffer-id (file-conflict-resource old) version
                  (if version 'replaced 'deleted)
                  (if automatic? 'reloading 'pending))])
          (file-state-set-conflict! (file-service-state service) buffer-id next)
          (command-runtime-enqueue!
            (package-host-command-runtime (file-service-host service))
            (make-command-invoke-message
              (if automatic?
                  'file.external-auto-reload
                  'file.resolve-external-change)
              context (list buffer-id version) (not automatic?)))))))

  (define (automatic-reload-became-dirty? service request)
    (let ([conflict
           (file-service-conflict
             service (file-external-resolution-buffer-id request) #f)])
      (and conflict
           (eq? (file-conflict-status conflict) 'reloading)
           (file-service-history service)
           (history-modified?
             (file-service-history service)
             (file-conflict-buffer-id conflict)))))

  (define (request-conflict-decision! service request context)
    (let ([conflict
           (file-service-conflict
             service (file-external-resolution-buffer-id request) #f)])
      (when conflict
        (file-conflict-status-set! conflict 'pending)
        (command-runtime-enqueue!
          (package-host-command-runtime (file-service-host service))
          (make-command-invoke-message
            'file.resolve-external-change context
            (list (file-conflict-buffer-id conflict)
                  (file-conflict-version conflict))
            #t)))))

  (define (make-file-service! host owner history)
    (unless (and (package-host? host) (owner? owner)
                 (or (not history) (history? history)))
      (assertion-violation 'make-file-service! "invalid file service dependencies"
                           host owner history))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-file-keymap)]
           [watch-service (make-file-watch-service owner)]
           [service
            (%make-file-service
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
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'file.external-auto-reload
          (lambda (context buffer-id version)
            (make-command-effect
              'file.external-resolution
              (make-file-external-resolution
                buffer-id version 'reload #f #f)))
          owner "Reload an unmodified Buffer after a stable external change."
          'file #f))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'file.resolve-external-change
          (lambda (context buffer-id version action . arguments)
            (cond
              [(and (eq? action 'save-as)
                    (or (< (length arguments) 3)
                        (eq? (cadr arguments) 'cancel)))
               (command-handled)]
              [else
               (let* ([destination
                        (and (eq? action 'save-as)
                             (canonical-file-resource (car arguments)))]
                      [destination-version
                       (and destination (caddr arguments))])
                 (make-command-effect
                   'file.external-resolution
                   (make-file-external-resolution
                     buffer-id version action destination
                     destination-version)))]))
          owner
          "Resolve a changed-on-disk conflict without applying a stale decision."
          'file
          (make-interactive-plan
            (list (make-conflict-target-reader service)
                  (make-external-change-reader service)
                  (make-conflict-save-as-reader)
                  (make-conflict-overwrite-reader)))))
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
              (set-resource! service (file-load-buffer-id request)
                             (file-load-resource request) (file-load-version request)
                             (and binding (file-binding-lock binding))
                             (file-load-format request)))
            (clear-conflict! service (file-load-buffer-id request))
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
                    (set-resource! service (file-write-buffer-id request)
                                   resource (vfs-stat-path path)
                                   (if transfer-lock?
                                       new-lock
                                       (and binding (file-binding-lock binding)))
                                   (file-write-format request) #t)
                    (clear-conflict! service (file-write-buffer-id request))
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
        runtime 'file.close owner 'close-file-buffer
        (lambda (ignored invocation effect)
          (let ([request (command-effect-payload effect)])
            (unless (file-close? request)
              (assertion-violation 'file.close "invalid file close request" request))
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
        (list (make-file-name-reader "Visit file: "))
        (lambda (context path)
          (make-command-effect 'file.visit
            (make-file-visit context (canonical-file-resource path)))))
      (install-file-command! runtime owner 'file.insert
        "Insert a file's contents at every active selection."
        (list (make-file-name-reader "Insert file: "))
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
        (lambda (context) (toggle-backup context)))
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
        (list (make-file-name-reader "Write file: ") (make-overwrite-reader service))
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
      (install-file-command! runtime owner 'file.close "Close the active file Buffer."
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
                         (make-command-effect 'file.close (make-file-close target-id)))
                       (make-command-effect 'file.close (make-file-close target-id)))))]
            [else
             (make-command-effect 'file.close (make-file-close target-id))])))
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
