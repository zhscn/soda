(library (soda packages file-conflict-workflow)
  (export make-overwrite-request
          make-external-change-reader
          make-conflict-target-reader
          make-conflict-save-as-reader
          make-conflict-overwrite-reader
          file-service-conflict
          file-version=?
          file-service-handle-state-event!
          file-service-handle-runtime-event!
          resolve-external-file!
          retry-external-resolution!
          automatic-reload-became-dirty?
          request-conflict-decision!
          clear-recovery!)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel resource)
          (soda kernel state)
          (soda host buffer)
          (soda host command)
          (soda host command-runtime)
          (soda host package)
          (soda packages base history)
          (soda packages file-format)
          (soda packages file-operation)
          (soda packages file-path)
          (soda packages file-policy)
          (soda packages file-resource-binding)
          (soda packages file-save)
          (soda packages file-service-value)
          (soda packages file-state)
          (soda packages file-visit)
          (soda packages file-watch)
          (soda packages interaction)
          (soda packages recovery)
          (soda support vfs))

  (define (make-overwrite-request path)
    (make-choice-interaction-request
      'overwrite-decision
      (string-append "File exists: " path ". Overwrite?")
      (list
        (make-choice-action 'overwrite "Overwrite" (list #\o) 'destructive #f)
        (make-choice-action 'cancel "Cancel" (list #\c) 'cancel #t))))

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
            (make-choice-interaction-request
              'external-file-change
              (string-append
                "File changed on disk: " path ".")
              (list
                (make-choice-action 'reload "Reload" (list #\r) 'destructive #f)
                (make-choice-action
                  'overwrite "Overwrite" (list #\o) 'destructive #f)
                (make-choice-action 'save-as "Save as" (list #\s) 'normal #f)
                (make-choice-action 'ignore "Ignore" (list #\i) 'cancel #t)))
            (lambda (value)
              (make-interactive-ready (list value))))))))

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
                    (list value version)))))
            (make-interactive-ready (list 'overwrite #f))))))

  (define (file-service-conflict service buffer-id . default)
    (unless (and (file-service? service) (buffer-id? buffer-id))
      (assertion-violation 'file-service-conflict
                           "expected a FileService and Buffer id"
                           service buffer-id))
    (file-state-conflict
      (file-service-state service) buffer-id
      (if (null? default) #f (car default))))

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
        (set-file-resource! service (buffer-id buffer) resource version
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
              (clear-file-conflict! service (buffer-id buffer))))))))

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
              (set-file-resource! service (buffer-id buffer) resource version
                             (file-binding-lock binding) format #t)
              (when (file-service-history service)
                (history-mark-saved!
                  (file-service-history service) (buffer-id buffer)))
              (clear-recovery! service (buffer-id buffer))
              (clear-file-conflict! service (buffer-id buffer))))))))

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
                (set-file-resource!
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
            (clear-file-conflict! service (buffer-id buffer)))
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
)
