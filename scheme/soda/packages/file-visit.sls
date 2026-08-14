(library (soda packages file-visit)
  (export ensure-file-buffer!
          open-file-buffer!
          replace-buffer-contents)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel resource)
          (soda kernel selection)
          (soda kernel state)
          (soda host buffer)
          (soda host command)
          (soda host package)
          (soda host view)
          (soda packages base history)
          (soda packages buffer-mode)
          (soda packages edit-policy)
          (soda packages file-format)
          (soda packages file-mode-registry)
          (soda packages file-operation)
          (soda packages file-path)
          (soda packages file-policy)
          (soda packages file-resource-binding)
          (soda packages file-service-value)
          (soda support vfs))

  (define (file-buffer-configuration service resource context lock-conflict?)
    ;; New file Buffers inherit ordinary editing configuration from the active
    ;; Buffer.  The lock compartment is replaced at this boundary so a prior
    ;; conflict cannot make unrelated files read-only.
    (let* ([base (buffer-state-configuration (command-context-buffer-state context))]
           [mode (file-mode-registry-mode-for
                   (file-service-mode-registry service) resource)]
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
                      (set-file-resource!
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
           [host (file-service-host service)])
      ;; File loading is an effect.  Its final presentation remains conditional
      ;; on the originating View, so an input transition cannot be overwritten
      ;; by a delayed visit completion.
      (let* ([buffer (ensure-file-buffer! service context resource)]
             [current-id (command-context-buffer-id context)])
        (if (= (buffer-id buffer) current-id)
            buffer
            (and (package-host-present-buffer-if-current!
                   host (file-service-owner service) buffer context
                   (buffer-state-configuration (buffer-state buffer)))
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
)
