(library (soda packages file-save)
  (export encode-buffer-for-write
          make-file-write-effect
          toggle-file-backup
          modified-file-buffer?
          file-service-modified-count
          file-service-shutdown-effects)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel resource)
          (soda kernel state)
          (soda host buffer)
          (soda host command)
          (soda host feedback)
          (soda host package)
          (soda packages base history)
          (soda packages file-format)
          (soda packages file-operation)
          (soda packages file-policy)
          (soda packages file-resource-binding)
          (soda packages file-service-value)
          (soda packages file-state))

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

  (define (toggle-file-backup context)
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
              #f (list effect) '())])
      (list update
            (make-user-feedback
              (string-append "File backups "
                             (if enabled? "disabled" "enabled")) 'info))))

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
)
