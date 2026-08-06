(library (soda packages file)
  (export make-file-service!
          file-service?
          file-service-resource)
  (import (rnrs)
          (only (chezscheme) current-directory)
          (soda kernel change)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal operation)
          (soda host internal state)
          (soda host internal view)
          (soda host value)
          (soda packages base history)
          (soda packages interaction)
          (soda packages resource)
          (soda support vfs))

  ;; FileService owns the association between a Buffer and an external file.
  ;; A file Buffer is catalogued by its canonical resource.  Visiting a file
  ;; therefore creates or reuses shared Buffer state, then creates a View for
  ;; the requesting Window; it never replaces unrelated Buffer contents.
  (define-record-type
    (file-service %make-file-service file-service?)
    (fields
      (immutable resources file-service-resources)
      (immutable state file-service-state)
      (immutable owner file-service-owner)
      (immutable history file-service-history)))

  (define-record-type file-binding
    (fields resource version))

  (define-record-type file-load
    (fields buffer-id resource version discard-history?))

  (define-record-type file-write
    (fields buffer-id resource contents expected-version rebind?))

  (define-record-type file-visit
    (fields context resource))

  (define (buffer-id? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (require-path who path)
    (unless (and (string? path) (positive? (string-length path)))
      (assertion-violation who "expected a non-empty file name" path)))

  (define (canonical-file-resource path)
    (require-path 'canonical-file-resource path)
    (make-resource 'file
      (vfs-resolve-path (vfs-directory-path (current-directory)) path)))

  (define (file-service-binding service buffer-id . default)
    (unless (and (file-service? service) (buffer-id? buffer-id))
      (assertion-violation 'file-service-binding "expected a file service and Buffer id"
                           service buffer-id))
    (hashtable-ref (file-service-resources service) buffer-id
                   (if (null? default) #f (car default))))

  (define (file-service-resource service buffer-id . default)
    (let ([binding (file-service-binding service buffer-id #f)])
      (if binding
          (file-binding-resource binding)
          (if (null? default) #f (car default)))))

  (define (set-resource! service buffer-id resource version)
    (let ([binding (make-file-binding resource version)])
      (hashtable-set! (file-service-resources service) buffer-id binding)
      binding))

  (define (file-buffer-key resource)
    (make-buffer-key 'file (resource-locator resource)))

  (define (empty-bytes)
    (make-bytevector 0))

  (define (resource-contents resource)
    (let ([path (resource-locator resource)])
      (if (vfs-file-exists? path)
          (values (vfs-read-file path) (vfs-stat-path path))
          (values (empty-bytes) #f))))

  (define (file-buffer-configuration context)
    ;; New file Buffers start with the currently active Buffer configuration.
    ;; Mode selection is a later package concern; this preserves fundamental
    ;; editing and any ordinary Buffer-local extensions at the open boundary.
    (buffer-state-configuration (command-context-buffer-state context)))

  (define (open-file-buffer! service request)
    (unless (file-visit? request)
      (assertion-violation 'file.visit "invalid file visit request" request))
    (let* ([context (file-visit-context request)]
           [resource (file-visit-resource request)]
           [state (file-service-state service)]
           [buffers (host-state-buffers state)]
           [views (host-state-views state)]
           [key (file-buffer-key resource)]
           [buffer
            (buffer-service-open-or-create!
              buffers (file-service-owner service) key
              (lambda ()
                (call-with-values
                  (lambda () (resource-contents resource))
                  (lambda (contents version)
                    (let ([created
                           (buffer-service-create!
                             buffers (file-service-owner service)
                             (resource-locator resource)
                             (make-document contents)
                             (file-buffer-configuration context))])
                      (set-resource! service (buffer-id created) resource version)
                      (when (file-service-history service)
                        (history-mark-saved! (file-service-history service)
                                             (buffer-id created)))
                      created)))))]
           [current-id (command-context-buffer-id context)])
      (if (= (buffer-id buffer) current-id)
          buffer
          (let* ([surface-id (command-context-surface-id context)]
                 [window-id (command-context-window-id context)])
            (unless (and (buffer-id? surface-id) (buffer-id? window-id))
              (assertion-violation 'file.visit
                                   "file visit requires a routed Window context" context))
            (let ([view
                   (view-service-create!
                     views (file-service-owner service) buffer
                     (file-buffer-configuration context))])
              (unless
                (dispatcher-dispatch-host!
                  (host-state-dispatch state)
                  (make-replace-window-view-operation surface-id window-id (view-id view)))
                (view-service-close-view! views (view-id view))
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

  (define (make-file-service! state owner history)
    (unless (and (host-state? state) (owner? owner)
                 (or (not history) (history? history)))
      (assertion-violation 'make-file-service! "invalid file service dependencies"
                           state owner history))
    (let* ([runtime (host-state-command-runtime state)]
           [buffers (host-state-buffers state)]
           [service (%make-file-service (make-eqv-hashtable) state owner history)])
      (command-runtime-register-effect-handler!
        runtime 'file.visit owner 'open-file-buffer
        (lambda (ignored invocation effect)
          (open-file-buffer! service (command-effect-payload effect))))
      (command-runtime-register-effect-handler!
        runtime 'file.load owner 'bind-loaded-file
        (lambda (ignored invocation effect)
          (let ([request (command-effect-payload effect)])
            (unless (file-load? request)
              (assertion-violation 'file.load "invalid file load request" request))
            (set-resource! service (file-load-buffer-id request)
                           (file-load-resource request) (file-load-version request))
            (when (and (file-load-discard-history? request) history)
              (history-discard-buffer! history (file-load-buffer-id request))))))
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
                    (and (file-write-rebind? request)
                         (buffer-service-ref buffers (file-write-buffer-id request) #f))])
              (when (and (file-write-rebind? request) (not target))
                (assertion-violation 'file.write "target Buffer is no longer live" request))
              ;; Verify ownership of the destination before touching it.  A
              ;; failed Save As must not overwrite an open file Buffer owned
              ;; by another resource identity.
              (when target
                (let ([existing (buffer-service-find-key buffers (file-buffer-key resource) #f)])
                  (when (and existing (not (= (buffer-id existing) (buffer-id target))))
                    (assertion-violation 'file.write
                                         "destination is already visited by another Buffer"
                                         path))))
              (when expected
                (unless (vfs-stat-same-version? expected (vfs-stat-path path))
                  (assertion-violation 'file.write "file changed outside Soda" path)))
              (vfs-write-file path (file-write-contents request))
              (when target
                (buffer-service-rebind-key!
                  buffers (file-buffer-key resource) target))
              (set-resource! service (file-write-buffer-id request)
                             resource (vfs-stat-path path)))
            (when history
              (history-mark-saved! history (file-write-buffer-id request))))))
      (install-file-command! runtime owner 'file.visit "Visit a file in the active Window."
        (list (make-interaction-string-reader 'file-name "Visit file: "))
        (lambda (context path)
          (make-command-effect 'file.visit
            (make-file-visit context (canonical-file-resource path)))))
      (install-file-command! runtime owner 'file.revert "Reload the active Buffer's visited file." '()
        (lambda (context)
          (let ([binding (file-service-binding service (command-context-buffer-id context) #f)])
            (if (not binding)
                (command-handled)
                (let* ([resource (file-binding-resource binding)]
                       [version (vfs-stat-path (resource-locator resource))]
                       [contents (vfs-read-file (resource-locator resource))])
                  (list
                    (replace-buffer-contents context contents)
                    (make-command-effect 'file.load
                      (make-file-load (command-context-buffer-id context)
                                      resource version #t))))))))
      (install-file-command! runtime owner 'file.save "Write the active Buffer to its visited file." '()
        (lambda (context)
          (let ([binding (file-service-binding service (command-context-buffer-id context) #f)])
            (if (not binding)
                (command-handled)
                (make-command-effect
                  'file.write
                  (make-file-write
                    (command-context-buffer-id context) (file-binding-resource binding)
                    (snapshot-bytevector
                      (buffer-state-document (command-context-buffer-state context)))
                    (file-binding-version binding) #f))))))
      (install-file-command! runtime owner 'file.save-as "Write the active Buffer to a file and visit it."
        (list (make-interaction-string-reader 'file-name "Write file: "))
        (lambda (context path)
          (let ([resource (canonical-file-resource path)])
            (make-command-effect
              'file.write
                (make-file-write
                  (command-context-buffer-id context) resource
                  (snapshot-bytevector
                    (buffer-state-document (command-context-buffer-state context)))
                #f #t)))))
      (buffer-service-add-close-listener!
        buffers owner
        (lambda (buffer)
          (hashtable-delete! (file-service-resources service) (buffer-id buffer))))
      service))
)
