(library (soda packages file)
  (export make-file-service!
          file-service?
          file-service-resource
          file-service-register-mode!
          file-backup-enabled?
          file-keymap)
  (import (rnrs)
          (only (chezscheme) current-directory get-process-id)
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
          (soda host input)
          (soda host input-event)
          (soda host location)
          (soda host operation)
          (soda host setting)
          (soda host value)
          (soda host view)
          (soda packages base history)
          (soda packages buffer-ui)
          (soda packages completion)
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
      (immutable host file-service-host)
      (immutable owner file-service-owner)
      (immutable history file-service-history)
      (immutable keymap file-keymap)
      (mutable mode-associations file-service-mode-associations
                                 file-service-mode-associations-set!)))

  (define-record-type
    (file-mode-association %make-file-mode-association file-mode-association?)
    (fields (immutable suffix file-mode-association-suffix)
            (immutable mode file-mode-association-mode)))

  (define (file-service-register-mode! service owner suffix mode)
    (unless (and (file-service? service) (owner? owner)
                 (string? suffix) (positive? (string-length suffix))
                 (mode-spec? mode) (eq? (mode-spec-kind mode) 'major))
      (assertion-violation 'file-service-register-mode!
                           "expected a FileService, owner, suffix, and major ModeSpec"
                           service owner suffix mode))
    (owner-assert-active 'file-service-register-mode! owner)
    (let ([association
           (%make-file-mode-association (string-copy suffix) mode)])
      (file-service-mode-associations-set!
        service (cons association (file-service-mode-associations service)))
      (make-registration
        owner
        (lambda ()
          (file-service-mode-associations-set!
            service
            (filter (lambda (item) (not (eq? item association)))
                    (file-service-mode-associations service)))))))

  (define (string-suffix? suffix value)
    (let ([offset (- (string-length value) (string-length suffix))])
      (and (>= offset 0)
           (string=? suffix (substring value offset (string-length value))))))

  (define (file-service-mode-for service resource)
    (let loop ([associations (file-service-mode-associations service)]
               [best #f])
      (if (null? associations)
          (and best (file-mode-association-mode best))
          (let ([association (car associations)])
            (loop
              (cdr associations)
              (if (and (string-suffix?
                         (file-mode-association-suffix association)
                         (resource-locator resource))
                       (or (not best)
                           (> (string-length (file-mode-association-suffix association))
                              (string-length (file-mode-association-suffix best)))))
                  association
                  best))))))

  (define-record-type file-binding
    (fields resource version lock))

  (define-record-type file-lock
    (fields path token))

  (define-record-type file-load
    (fields buffer-id resource version discard-history?))

  (define-record-type file-write
    (fields buffer-id resource contents expected-version rebind?))

  (define-record-type file-visit
    (fields context resource))

  (define-record-type file-location-open
    (fields location))

  (define-record-type file-close
    (fields buffer-id))

  (define-record-type file-insert
    (fields context resource))

  ;; Backups are a Buffer policy: visiting the same file through another View
  ;; observes the same save behavior, while an unrelated Buffer retains its
  ;; own choice.  The VFS remains unaware of backup naming or retention.
  (define (first-value values default)
    (if (null? values) default (car values)))

  (define file-backup-facet
    (make-facet 'file-backup 'buffer #f
                (lambda (values) (first-value values #f)) eq? eq?))

  (define file-backup-compartment (make-compartment 'file-backup 'buffer))

  ;; A lock conflict is Buffer-local.  The compartment prevents this safety
  ;; policy from leaking into the next file visited from a read-only Buffer.
  (define file-lock-read-only-compartment
    (make-compartment 'file-lock-read-only 'buffer))

  (define (file-backup-enabled? configuration)
    (configuration-facet configuration file-backup-facet 'buffer))

  (define (make-file-backup-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-file-backup-extension
                           "expected a backup policy boolean" enabled?))
    (make-facet-provider file-backup-facet enabled? 'highest))

  (define (parse-backup-policy input)
    (cond
      [(boolean? input) input]
      [(and (string? input)
            (member (string-downcase input) '("true" "yes" "on" "1"))) #t]
      [(and (string? input)
            (member (string-downcase input) '("false" "no" "off" "0"))) #f]
      [else 'invalid]))

  (define (register-file-settings! host owner)
    (package-host-register-setting-schema!
      host owner
      (make-setting-schema
        'file.backup 'boolean #f '(buffer) parse-backup-policy #f
        (lambda (enabled? scope)
          (make-facet-provider file-backup-facet enabled?)))))

  (define (buffer-id? value)
    (and (integer? value) (exact? value) (>= value 0)))

  (define (require-path who path)
    (unless (and (string? path) (positive? (string-length path)))
      (assertion-violation who "expected a non-empty file name" path)))

  (define (canonical-file-resource path)
    (require-path 'canonical-file-resource path)
    (make-resource 'file
      (vfs-resolve-path (vfs-directory-path (current-directory)) path)))

  (define (file-backup-path path) (string-append path "~"))

  (define (file-lock-file-path resource)
    (string-append (resource-locator resource) ".soda-lock"))

  (define file-lock-serial 0)

  (define (next-file-lock-token)
    (set! file-lock-serial (+ file-lock-serial 1))
    (string->utf8
      (string-append "soda " (number->string (get-process-id)) " "
                     (number->string file-lock-serial) "\n")))

  (define (acquire-file-lock resource)
    (let* ([path (file-lock-file-path resource)]
           [token (next-file-lock-token)])
      (and (vfs-create-exclusive-file! path token)
           (make-file-lock path token))))

  (define (release-file-lock! lock)
    (and lock
         (vfs-delete-file-if-matches!
           (file-lock-path lock) (file-lock-token lock))))

  (define (string-prefix? prefix value)
    (let ([length (string-length prefix)])
      (and (<= length (string-length value))
           (string=? prefix (substring value 0 length)))))

  (define (path-field-start value point)
    (let loop ([index (- point 1)])
      (cond [(negative? index) 0]
            [(vfs-path-separator? (string-ref value index)) (+ index 1)]
            [else (loop (- index 1))])))

  ;; File-name completion has no project ownership.  It resolves the path
  ;; field under point against the process directory, preserving the spelling
  ;; already typed in the prompt for the candidate insertion text.
  (define (file-name-candidates snapshot)
    (let* ([input (prompt-snapshot-input snapshot)]
           [point (prompt-snapshot-point snapshot)]
           [length (string-length input)])
      ;; Completion replacement currently addresses one whole prompt value.
      ;; Do not offer a candidate if text after point would be overwritten.
      (if (not (= point length))
          '()
          (let* ([start (path-field-start input point)]
                 [directory-prefix (substring input 0 start)]
                 [name-prefix (substring input start point)]
                 [directory
                  (if (zero? (string-length directory-prefix))
                      (vfs-directory-path (current-directory))
                      (vfs-resolve-path
                        (vfs-directory-path (current-directory)) directory-prefix))])
            (guard (condition [else '()])
              (map
                (lambda (entry)
                  (let* ([name (vfs-entry-name entry)]
                         [directory? (eq? (vfs-entry-kind entry) 'directory)]
                         [label (if directory? (vfs-directory-path name) name)]
                         [insert-text (string-append directory-prefix label)])
                    (make-completion-candidate
                      (vfs-path-join directory name) insert-text label
                      (if directory? "directory" "file") "file" entry)))
                (filter
                  (lambda (entry)
                    (and (not (string=? (vfs-entry-name entry) "."))
                         (not (string=? (vfs-entry-name entry) ".."))
                         (string-prefix? name-prefix (vfs-entry-name entry))))
                  (vfs-list-directory directory))))))))

  (define file-name-completion-source
    (make-completion-source file-name-candidates #f #f #f))

  (define (make-file-name-reader prompt)
    (make-interactive-reader
      'file-name
      (lambda (context arguments)
        (make-interactive-suspend
          (make-interaction-request
            'file-name prompt #f file-name-completion-source 'free)
          (lambda (value) (make-interactive-ready (list value)))))))

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
       (set-resource! service buffer-id resource version #f)]
      [(service buffer-id resource version lock)
       (let ([binding (make-file-binding resource version lock)])
         (hashtable-set! (file-service-resources service) buffer-id binding)
         binding)]))

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
          (values (vfs-read-file path) (vfs-stat-path path))
          (values (empty-bytes) #f))))

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
                  (lambda (contents version)
                    (let ([created
                           (package-host-create-buffer!
                             host (file-service-owner service)
                             (resource-locator resource)
                             (make-document contents)
                             (file-buffer-configuration
                               service resource context (not lock)))])
                      (set-resource! service (buffer-id created) resource version lock)
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

  (define (make-file-write-effect buffer-id document resource version rebind?)
    (make-command-effect
      'file.write
      (make-file-write
        buffer-id resource (snapshot-bytevector document) version rebind?)))

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

  (define (make-quit-reader service)
    (make-interactive-reader
      'save-decision
      (lambda (context arguments)
        (let ([dirty (modified-file-buffers service)])
          (if (null? dirty)
              (make-interactive-ready (list 'discard))
              (make-interactive-suspend
                (make-decision-request
                  (string-append "Save " (number->string (length dirty))
                                 " modified file buffer"
                                 (if (= (length dirty) 1) "" "s")
                                 "? (save/discard/cancel) "))
                (lambda (value)
                  (make-interactive-ready (list (close-decision value))))))))))

  (define (close-buffer! service target-id)
    (package-host-close-buffer-with-fallback!
      (file-service-host service) (file-service-owner service) target-id))

  (define (make-file-service! host owner history)
    (unless (and (package-host? host) (owner? owner)
                 (or (not history) (history? history)))
      (assertion-violation 'make-file-service! "invalid file service dependencies"
                           host owner history))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-keymap 'file)]
           [service
            (%make-file-service (make-eqv-hashtable) host owner history keymap '())])
      (register-file-settings! host owner)
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
                             (and binding (file-binding-lock binding))))
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
                                       (and binding (file-binding-lock binding))))
                    (set! written? #t)
                    (when transfer-lock?
                      (release-file-lock! (and binding (file-binding-lock binding)))))
                  (lambda ()
                    (when (and transfer-lock? (not written?))
                      (release-file-lock! new-lock))))))
            (when history
              (history-mark-saved! history (file-write-buffer-id request))))))
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
            (command-runtime-enqueue!
              runtime
              (make-command-invoke-message
                'fundamental.insert-text
                (file-insert-context request)
                (list (vfs-read-file
                        (resource-locator (file-insert-resource request))))
                #f)))))
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
                       [version (vfs-stat-path (resource-locator resource))]
                       [contents (vfs-read-file (resource-locator resource))])
                  (list
                    (replace-buffer-contents context contents)
                    (make-command-effect 'file.load
                      (make-file-load (command-context-buffer-id context)
                                      resource version #t))))))))
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
                      (command-context-buffer-id context)
                      (buffer-state-document (command-context-buffer-state context))
                      (file-binding-resource binding) (file-binding-version binding) #f)
                    (command-handled))
                (if (or (null? arguments) (not (string? (car arguments)))
                        (and (pair? (cdr arguments))
                             (not (eq? (cadr arguments) 'overwrite))))
                    (command-handled)
                    (let ([resource (canonical-file-resource (car arguments))])
                      (make-file-write-effect
                        (command-context-buffer-id context)
                        (buffer-state-document (command-context-buffer-state context))
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
                  (make-command-effect
                    'file.write
                    (make-file-write
                      (command-context-buffer-id context) resource
                      (snapshot-bytevector
                        (buffer-state-document (command-context-buffer-state context)))
                      #f #t)))
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
                           target-id
                           (buffer-state-document (buffer-state target))
                           (file-binding-resource binding) (file-binding-version binding) #f)
                         (make-command-effect 'file.close (make-file-close target-id)))
                       (make-command-effect 'file.close (make-file-close target-id)))))]
            [else
             (make-command-effect 'file.close (make-file-close target-id))])))
      ;; Exit is a normal interactive command.  It asks once for all modified
      ;; visited files, performs writes first, and only then notifies the
      ;; frontend to terminate.  Unvisited scratch Buffers remain disposable.
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'application.quit
          (lambda (context decision)
            (case decision
              [(cancel) (command-handled)]
              [(save)
               (append
                 (map
                   (lambda (buffer)
                     (let ([binding (file-service-binding service (buffer-id buffer))])
                       (make-file-write-effect
                         (buffer-id buffer)
                         (buffer-state-document (buffer-state buffer))
                         (file-binding-resource binding) (file-binding-version binding) #f)))
                   (modified-file-buffers service))
                 (list (make-command-effect 'application.quit #f)))]
              [else (make-command-effect 'application.quit #f)]))
          owner "Request application shutdown, resolving modified file Buffers first."
          'application (make-interactive-plan (list (make-quit-reader service)))))
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 4)
                          (make-key-stroke 'character (char->integer #\f) 4))
                    'file.visit)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 4)
                          (make-key-stroke 'character (char->integer #\s) 4))
                    'file.save)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 4)
                          (make-key-stroke 'character (char->integer #\w) 4))
                    'file.save-as)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\x) 4)
                          (make-key-stroke 'character (char->integer #\k) 4))
                    'file.close)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\r) 4))
                    'file.insert)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\o) 4))
                    'file.save)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\r) 2))
                    'file.revert)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\B) 2))
                    'file.toggle-backup)
      (package-host-add-buffer-close-listener!
        host owner
        (lambda (buffer)
          (let ([binding (file-service-binding service (buffer-id buffer) #f)])
            (when binding (release-file-lock! (file-binding-lock binding))))
          (hashtable-delete! (file-service-resources service) (buffer-id buffer))
          (when history (history-discard-buffer! history (buffer-id buffer)))))
      service))
)
