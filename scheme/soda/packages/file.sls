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
          (soda host buffer)
          (soda host command-runtime)
          (soda host value)
          (soda packages base history)
          (soda packages interaction)
          (soda packages resource)
          (soda support vfs))

  ;; FileService owns the association between a Buffer and an external file.
  ;; Reading and writing are effects; a file's bytes become a Document only by
  ;; returning an ordinary TransactionSpec to CommandRuntime.
  (define-record-type
    (file-service %make-file-service file-service?)
    (fields
      (immutable resources file-service-resources)
      (immutable history file-service-history)))

  (define-record-type file-binding
    (fields resource version))

  (define-record-type file-load
    (fields buffer-id resource version discard-history?))

  (define-record-type file-write
    (fields buffer-id resource contents expected-version))

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

  (define (make-file-service! runtime buffers owner history)
    (unless (and (command-runtime? runtime) (owner? owner)
                 (or (not history) (history? history)))
      (assertion-violation 'make-file-service! "invalid file service dependencies"
                           runtime buffers owner history))
    (let ([service (%make-file-service (make-eqv-hashtable) history)])
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
            (let* ([path (resource-locator (file-write-resource request))]
                   [expected (file-write-expected-version request)])
              (when expected
                (unless (vfs-stat-same-version? expected (vfs-stat-path path))
                  (assertion-violation 'file.write "file changed outside Soda" path)))
              (vfs-write-file path (file-write-contents request))
              (set-resource! service (file-write-buffer-id request)
                             (file-write-resource request) (vfs-stat-path path)))
            (when history
              (history-mark-saved! history (file-write-buffer-id request))))))
      (install-file-command! runtime owner 'file.visit "Visit a file in the active Buffer."
        (list (make-interaction-string-reader 'file-name "Visit file: "))
        (lambda (context path)
          (let* ([resource (canonical-file-resource path)]
                 [version (vfs-stat-path (resource-locator resource))]
                 [contents (vfs-read-file (resource-locator resource))]
                 [id (command-context-buffer-id context)])
            (list
              (replace-buffer-contents context contents)
              (make-command-effect 'file.load
                (make-file-load id resource version #t))))))
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
                    (file-binding-version binding)))))))
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
                #f)))))
      (buffer-service-add-close-listener!
        buffers owner
        (lambda (buffer)
          (hashtable-delete! (file-service-resources service) (buffer-id buffer))))
      service))
)
