(library (soda packages directory)
  (export make-directory-service!
          directory-service?
          directory-keymap
          directory-service-path)
  (import (rnrs)
          (only (chezscheme) current-directory)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel range-set)
          (soda kernel state)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host internal buffer)
          (soda host internal operation)
          (soda host internal state)
          (soda host internal view)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host value)
          (soda packages buffer-ui)
          (soda packages file)
          (soda packages resource)
          (soda support vfs))

  ;; DirectoryService presents a directory as a generated, read-only Buffer.
  ;; Its entries are BufferItems, so activation, motion, and future result
  ;; actions share the generic Buffer UI protocol rather than a browser-only
  ;; input loop.
  (define-record-type
    (directory-service %make-directory-service directory-service?)
    (fields state owner files actions keymap result-keymap authority directories))

  (define-record-type directory-state
    (fields path (mutable generation directory-state-generation directory-state-generation-set!)))

  (define-record-type directory-entry
    (fields path kind label))

  (define-record-type directory-open-request
    (fields context path))

  (define-record-type directory-refresh-request
    (fields context))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (directory-keymap service)
    (unless (directory-service? service)
      (assertion-violation 'directory-keymap "expected a DirectoryService" service))
    (directory-service-keymap service))

  (define (directory-service-path service buffer-id . default)
    (unless (and (directory-service? service) (integer? buffer-id) (exact? buffer-id)
                 (>= buffer-id 0))
      (assertion-violation 'directory-service-path
                           "expected a DirectoryService and Buffer identity" service buffer-id))
    (let ([state (hashtable-ref (directory-service-directories service) buffer-id #f)])
      (if state
          (directory-state-path state)
          (if (null? default) #f (car default)))))

  (define (normalize-directory path)
    (and (string? path) (positive? (string-length path))
         (let ([resolved
                (vfs-directory-path
                  (vfs-resolve-path (vfs-directory-path (current-directory)) path))])
           (guard (condition [else #f])
             (and (eq? (vfs-stat-kind (vfs-stat-path resolved)) 'directory) resolved)))))

  (define (context-directory service context)
    (let ([resource
           (file-service-resource
             (directory-service-files service) (command-context-buffer-id context) #f)])
      (if (and resource (resource? resource))
          (vfs-parent-directory (resource-locator resource))
          (vfs-directory-path (current-directory)))))

  (define (entry-label name kind)
    (case kind
      [(directory) (string-append name "/")]
      [(link) (string-append name "@")]
      [else name]))

  (define (directory-entries path)
    (let* ([parent (vfs-parent-directory path)]
           [parent-entry
            (if (string=? parent path)
                '()
                (list (make-directory-entry parent 'directory "../")))])
      (append
        parent-entry
        (map
          (lambda (entry)
            (let ([name (vfs-entry-name entry)] [kind (vfs-entry-kind entry)])
              (make-directory-entry
                (vfs-path-join path name) kind (entry-label name kind))))
          (vfs-list-directory path)))))

  (define (directory-layout path)
    (let loop ([entries (directory-entries path)]
               [text (string-append "Directory: " path "\n\n")]
               [ranges '()])
      (if (null? entries)
          (cons text (make-range-set (reverse ranges)))
          (let* ([entry (car entries)]
                 [row (string-append (directory-entry-label entry) "\n")]
                 [start (bytevector-length (string->utf8 text))]
                 [end (+ start (bytevector-length (string->utf8 row)))]
                 [item
                  (make-buffer-item
                    'directory (directory-entry-path entry) 'entry entry '(open) 'open)])
            (loop (cdr entries) (string-append text row)
                  (cons (make-range-value start end item) ranges))))))

  (define (directory-configuration service)
    (make-configuration
      (append
        (generated-projection-extension)
        (list
          (make-buffer-input-layer-extension
            (list (make-input-layer
                    'buffer (directory-service-result-keymap service) #f 'ignore)))
          (make-buffer-edit-policy-extension
            (make-buffer-edit-policy 'reject #f (directory-service-authority service)))))))

  (define (publish-directory! service buffer)
    (let* ([state (hashtable-ref (directory-service-directories service) (buffer-id buffer) #f)]
           [path (and state (directory-state-path state))])
      (and path
           (let* ([generation (+ (directory-state-generation state) 1)]
                  [layout (directory-layout path)]
                  [update
                   (make-projection-update generation (car layout) (cdr layout) '() '())]
                  [published
                   (dispatcher-dispatch!
                     (host-state-dispatch (directory-service-state service))
                     (make-projection-transaction-spec
                       (buffer-id buffer) #f (buffer-state buffer) update
                       (list (make-edit-authority-annotation
                               (directory-service-authority service)))))])
             (and published
                  (begin (directory-state-generation-set! state generation) published))))))

  (define (show-directory-error! service context path)
    (dispatcher-dispatch-host!
      (host-state-dispatch (directory-service-state service))
      (make-set-surface-message-operation
        (command-context-surface-id context)
        (string-append "Not a readable directory: " path))))

  (define (directory-buffer-key path)
    (make-buffer-key 'directory path))

  (define (open-directory! service request)
    (let* ([context (directory-open-request-context request)]
           [requested (directory-open-request-path request)]
           [path (normalize-directory requested)])
      (if (not path)
          (show-directory-error! service context requested)
          (let* ([state (directory-service-state service)]
                 [buffers (host-state-buffers state)]
                 [views (host-state-views state)]
                 [buffer
                  (buffer-service-open-or-create!
                    buffers (directory-service-owner service) (directory-buffer-key path)
                    (lambda ()
                      (buffer-service-create!
                        buffers (directory-service-owner service)
                        (string-append "*Directory: " path "*")
                        (make-document "") (directory-configuration service))))]
                 [directory-state
                  (hashtable-ref (directory-service-directories service) (buffer-id buffer) #f)])
            (unless directory-state
              (set! directory-state (make-directory-state path 0))
              (hashtable-set! (directory-service-directories service)
                              (buffer-id buffer) directory-state)
              (publish-directory! service buffer))
            (let ([view
                   (view-service-create!
                     views (directory-service-owner service) buffer
                     (buffer-state-configuration (buffer-state buffer)))])
              (unless
                (dispatcher-dispatch-host!
                  (host-state-dispatch state)
                  (make-replace-window-view-operation
                    (command-context-surface-id context)
                    (command-context-window-id context) (view-id view)))
                (view-service-close-view! views (view-id view))
                (assertion-violation 'directory.browse
                                     "origin Window is no longer available" context))
              buffer)))))

  (define (refresh-directory! service request)
    (let* ([context (directory-refresh-request-context request)]
           [buffer
            (buffer-service-ref (host-state-buffers (directory-service-state service))
                                (command-context-buffer-id context) #f)])
      (and buffer (publish-directory! service buffer))))

  (define (activate-directory-entry! service item context ignored)
    (let ([entry (buffer-item-payload item)]
          [runtime (host-state-command-runtime (directory-service-state service))])
      (if (not (directory-entry? entry))
          (command-handled)
          (begin
            (command-runtime-enqueue!
              runtime
              (make-command-invoke-message
                (if (eq? (directory-entry-kind entry) 'directory)
                    'directory.browse
                    'file.visit)
                context (list (directory-entry-path entry)) #f))
            (command-handled)))))

  (define (make-directory-service! state owner files actions)
    (unless (and (host-state? state) (owner? owner) (file-service? files)
                 (buffer-item-action-service? actions))
      (assertion-violation 'make-directory-service!
                           "expected HostState, owner, file service, and BufferItem actions"
                           state owner files actions))
    (let* ([runtime (host-state-command-runtime state)]
           [keymap (make-keymap 'directory)]
           [result-keymap (make-keymap 'directory-result)]
           [authority (make-edit-authority owner 'directory-refresh)]
           [service
            (%make-directory-service
              state owner files actions keymap result-keymap authority (make-eqv-hashtable))])
      (keymap-bind! keymap (list (control-stroke #\x) (control-stroke #\d)) 'directory.browse)
      (keymap-bind! result-keymap (list (make-key-stroke 'enter #f 0)) 'buffer.activate-item)
      (keymap-bind! result-keymap (list (control-stroke #\g)) 'file.close)
      (keymap-bind! result-keymap
                    (list (make-key-stroke 'character (char->integer #\g) 0))
                    'directory.refresh)
      (buffer-item-action-register!
        actions owner 'directory 'open
        (lambda (item context generation)
          (activate-directory-entry! service item context generation)))
      (command-runtime-register-effect-handler!
        runtime 'directory.open owner 'open-directory
        (lambda (ignored invocation effect)
          (open-directory! service (command-effect-payload effect))))
      (command-runtime-register-effect-handler!
        runtime 'directory.refresh owner 'refresh-directory
        (lambda (ignored invocation effect)
          (refresh-directory! service (command-effect-payload effect))))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'directory.browse
          (lambda (context . requested)
            (let ([path
                   (cond [(null? requested) (context-directory service context)]
                         [(and (null? (cdr requested)) (string? (car requested))) (car requested)]
                         [else
                          (assertion-violation 'directory.browse
                                               "expected zero arguments or one directory name"
                                               requested)])])
              (make-command-effect 'directory.open
                (make-directory-open-request context path))))
          owner "Browse a directory in a generated read-only Buffer." 'directory #f))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'directory.refresh
          (lambda (context)
            (make-command-effect 'directory.refresh (make-directory-refresh-request context)))
          owner "Refresh the directory entries in the current Directory Buffer." 'directory #f))
      (buffer-service-add-close-listener!
        (host-state-buffers state) owner
        (lambda (buffer)
          (hashtable-delete! (directory-service-directories service) (buffer-id buffer))))
      service))
)
