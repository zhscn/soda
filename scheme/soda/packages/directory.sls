(library (soda packages directory)
  (export make-directory-service!
          directory-service?
          directory-keymap
          directory-service-path)
  (import (rnrs)
          (only (chezscheme) current-directory)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host command)
          (soda host command-runtime)
          (soda host buffer)
          (soda host package)
          (soda host input)
          (soda host input-event)
          (soda host operation)
          (soda host value)
          (soda host view)
          (soda packages buffer-ui)
          (soda packages file)
          (soda packages interaction)
          (soda packages resource)
          (soda support vfs))

  ;; DirectoryService presents a directory as a generated, read-only Buffer.
  ;; Its entries are BufferItems, so activation, motion, and future result
  ;; actions share the generic Buffer UI protocol rather than a browser-only
  ;; input loop.
  (define-record-type
    (directory-service %make-directory-service directory-service?)
    (fields host owner files actions keymap result-keymap authority mode directories))

  (define-record-type directory-state
    (fields (mutable path directory-state-path directory-state-path-set!)
            (mutable generation directory-state-generation directory-state-generation-set!)))

  (define-record-type directory-entry
    (fields path kind label))

  (define-record-type directory-open-request
    (fields context path))

  (define-record-type directory-refresh-request
    (fields context))

  (define-record-type directory-mutation-request
    (fields kind context path destination))

  (define-record-type directory-target
    (fields path version))

  (define (capture-directory-target who value)
    (cond
      [(directory-target? value) value]
      [(and (string? value) (positive? (string-length value)))
       (make-directory-target value (vfs-stat-path value #f))]
      [else (assertion-violation who "expected a directory entry path" value)]))

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
      (make-buffer-modes-extension (directory-service-mode service) '())))

  (define (publish-directory! service buffer)
    (let* ([state (hashtable-ref (directory-service-directories service) (buffer-id buffer) #f)]
           [path (and state (directory-state-path state))])
      (and path
           (let* ([generation (+ (directory-state-generation state) 1)]
                  [layout (directory-layout path)]
                  [update
                   (make-projection-update generation (car layout) (cdr layout) '() '())]
                  [published
                   (package-host-dispatch!
                     (directory-service-host service)
                     (make-projection-transaction-spec
                       (buffer-id buffer) #f (buffer-state buffer) update
                       (list (make-edit-authority-annotation
                               (directory-service-authority service)))))])
             (and published
                  (begin (directory-state-generation-set! state generation) published))))))

  (define (show-directory-error! service context path)
    (package-host-set-surface-message!
      (directory-service-host service) (command-context-surface-id context)
      (string-append "Not a readable directory: " path)))

  (define (directory-buffer-key path)
    (make-buffer-key 'directory path))

  (define (open-directory! service request)
    (let* ([context (directory-open-request-context request)]
           [requested (directory-open-request-path request)]
           [path (normalize-directory requested)])
      (if (not path)
          (show-directory-error! service context requested)
          (let* ([host (directory-service-host service)]
                 [buffer
                  (package-host-open-or-create-buffer!
                    host (directory-service-owner service) (directory-buffer-key path)
                    (lambda ()
                      (package-host-create-buffer!
                        host (directory-service-owner service)
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
                   (package-host-create-view!
                     host (directory-service-owner service) buffer
                     (buffer-state-configuration (buffer-state buffer)))])
              (unless
                (package-host-replace-window-view!
                  host (command-context-surface-id context)
                  (command-context-window-id context) (view-id view))
                (assertion-violation 'directory.browse
                                     "origin Window is no longer available" context))
              buffer)))))

  (define (refresh-directory! service request)
    (let* ([context (directory-refresh-request-context request)]
           [buffer
            (package-host-buffer-ref (directory-service-host service)
                                (command-context-buffer-id context) #f)])
      (and buffer (publish-directory! service buffer))))

  (define (selected-entry context)
    (let* ([range
            (selection-primary-range
              (view-state-selection (command-context-view-state context)))]
           [item
            (buffer-item-at-point
              (command-context-buffer-state context)
              (selection-range-head range))]
           [entry (and item (buffer-item-payload item))])
      (and (directory-entry? entry)
           (not (string=? (directory-entry-label entry) "../"))
           entry)))

  (define (make-selected-path-reader operation)
    (make-interactive-reader
      'directory-entry
      (lambda (context arguments)
        (if (pair? arguments)
            (make-interactive-ready '())
            (let ([entry (selected-entry context)])
              (if entry
                  (let ([path (directory-entry-path entry)])
                    (make-interactive-ready
                      (list (make-directory-target path (vfs-stat-path path #f)))))
                  (assertion-violation operation
                                       "point does not identify a mutable directory entry")))))))

  (define (make-rename-destination-reader)
    (make-interactive-reader
      'directory-rename-destination
      (lambda (context arguments)
        (let ([source (and (pair? arguments) (car arguments))])
          (unless (directory-target? source)
            (assertion-violation 'directory.rename "missing source path"))
          (make-interactive-suspend
            (make-interaction-request
              'file-name "Rename to: " (directory-target-path source) #f 'free
              (lambda (value ignored)
                (and (string? value) (positive? (string-length value)))))
            (lambda (value) (make-interactive-ready (list value))))))))

  (define (delete-decision value)
    (and (string? value) (string-ci=? value "yes")))

  (define (make-delete-reader)
    (make-interactive-reader
      'directory-delete-confirmation
      (lambda (context arguments)
        (let ([target (and (pair? arguments) (car arguments))])
          (unless (directory-target? target)
            (assertion-violation 'directory.delete "missing target path"))
          (make-interactive-suspend
            (make-interaction-request
              'confirmation
              (string-append "Delete " (directory-target-path target) "? (yes/no) ")
              #f #f 'free
              (lambda (value ignored)
                (and (string? value)
                     (or (string-ci=? value "yes")
                         (string-ci=? value "no")))))
            (lambda (value)
              (make-interactive-ready (list (delete-decision value)))))))))

  (define (mutate-directory! service request)
    (let ([kind (directory-mutation-request-kind request)]
          [target (directory-mutation-request-path request)]
          [destination (directory-mutation-request-destination request)])
      (case kind
        [(create) (vfs-create-directory! target #f)]
        [(rename)
         (file-service-rename-resource!
           (directory-service-files service)
           (directory-target-path target) destination
           (directory-target-version target))
         (let* ([source-prefix
                 (vfs-directory-path (directory-target-path target))]
                [destination-prefix (vfs-directory-path destination)])
           (let-values ([(ids states)
                         (hashtable-entries
                           (directory-service-directories service))])
             (do ([index 0 (+ index 1)])
                 ((= index (vector-length ids)))
               (let* ([state (vector-ref states index)]
                      [path (directory-state-path state)])
                 (when (and (>= (string-length path)
                                (string-length source-prefix))
                            (string=? source-prefix
                                      (substring path 0
                                                 (string-length source-prefix))))
                   (let* ([next
                           (string-append
                             destination-prefix
                             (substring path (string-length source-prefix)
                                        (string-length path)))]
                          [buffer
                           (package-host-buffer-ref
                             (directory-service-host service)
                             (vector-ref ids index) #f)])
                     (when buffer
                       (package-host-rebind-buffer-key!
                         (directory-service-host service)
                         (directory-buffer-key next) buffer)
                       (directory-state-path-set! state next)
                       (publish-directory! service buffer))))))))]
        [(delete)
         (let ([selected (vfs-directory-path (directory-target-path target))])
           (let-values ([(ids states)
                         (hashtable-entries
                           (directory-service-directories service))])
             (do ([index 0 (+ index 1)])
                 ((= index (vector-length ids)))
               (when (string=? selected
                               (directory-state-path (vector-ref states index)))
                 (assertion-violation
                   'directory.delete "cannot delete an open directory" selected)))))
         (file-service-delete-resource!
           (directory-service-files service)
           (directory-target-path target) (directory-target-version target))]
        [else (assertion-violation 'directory.mutate "unknown mutation" kind)])
      (refresh-directory!
        service
        (make-directory-refresh-request
          (directory-mutation-request-context request)))))

  (define (activate-directory-entry! service item context ignored)
    (let ([entry (buffer-item-payload item)]
          [runtime (package-host-command-runtime (directory-service-host service))])
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

  (define (make-directory-service! host owner files actions)
    (unless (and (package-host? host) (owner? owner) (file-service? files)
                 (buffer-item-action-service? actions))
      (assertion-violation 'make-directory-service!
                           "expected HostState, owner, file service, and BufferItem actions"
                           host owner files actions))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-keymap 'directory)]
           [result-keymap (make-keymap 'directory-result)]
           [authority (make-edit-authority owner 'directory-refresh)]
           [mode
            (make-mode-spec
              'directory-mode 'major "Directory" #f
              (append
                (generated-projection-extension)
                (list
                  (make-buffer-input-layer-extension
                    (list (make-input-layer 'buffer result-keymap #f 'ignore)
                          (buffer-item-input-layer actions)))
                  (make-buffer-edit-policy-extension
                    (make-buffer-edit-policy 'reject #f authority))))
              '(directory buffer-item) "Directory")]
           [service
            (%make-directory-service
              host owner files actions keymap result-keymap authority mode
              (make-eqv-hashtable))])
      (keymap-bind! keymap (list (control-stroke #\x) (control-stroke #\d)) 'directory.browse)
      (keymap-bind! result-keymap
                    (list (make-key-stroke 'character (char->integer #\g) 0))
                    'directory.refresh)
      (keymap-bind! result-keymap
                    (list (make-key-stroke 'character (char->integer #\+) 0))
                    'directory.create-directory)
      (keymap-bind! result-keymap
                    (list (make-key-stroke 'character (char->integer #\R) 0))
                    'directory.rename)
      (keymap-bind! result-keymap
                    (list (make-key-stroke 'character (char->integer #\D) 0))
                    'directory.delete)
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
      (command-runtime-register-effect-handler!
        runtime 'directory.mutate owner 'mutate-directory
        (lambda (ignored invocation effect)
          (mutate-directory! service (command-effect-payload effect))))
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
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'directory.create-directory
          (lambda (context name)
            (let ([base
                   (directory-service-path
                     service (command-context-buffer-id context) #f)])
              (unless base
                (assertion-violation 'directory.create-directory
                                     "current Buffer is not a directory browser"))
              (make-command-effect
                'directory.mutate
                (make-directory-mutation-request
                  'create context (vfs-resolve-path base name) #f))))
          owner "Create a directory and refresh the current browser."
          'directory
          (make-interactive-plan
            (list (make-interaction-string-reader
                    'directory-name "Create directory: ")))))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'directory.rename
          (lambda (context source destination)
            (let ([base
                   (directory-service-path
                     service (command-context-buffer-id context) #f)])
              (unless base
                (assertion-violation 'directory.rename
                                     "current Buffer is not a directory browser"))
              (make-command-effect
                'directory.mutate
                (make-directory-mutation-request
                  'rename context (capture-directory-target 'directory.rename source)
                  (vfs-resolve-path base destination)))))
          owner "Rename the entry at point without replacing an existing path."
          'directory
          (make-interactive-plan
            (list (make-selected-path-reader 'directory.rename)
                  (make-rename-destination-reader)))))
      (command-runtime-register-command!
        runtime
        (make-command-definition
          'directory.delete
          (lambda (context path confirmed?)
            (if confirmed?
                (make-command-effect
                  'directory.mutate
                  (make-directory-mutation-request
                    'delete context (capture-directory-target 'directory.delete path) #f))
                (command-handled)))
          owner "Delete the entry at point after confirmation."
          'directory
          (make-interactive-plan
            (list (make-selected-path-reader 'directory.delete)
                  (make-delete-reader)))))
      (package-host-add-buffer-close-listener!
        host owner
        (lambda (buffer)
          (hashtable-delete! (directory-service-directories service) (buffer-id buffer))))
      service))
)
