(library (soda packages buffer-list)
  (export make-buffer-list-service!
          buffer-list-service?
          buffer-list-keymap)
  (import (rnrs)
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
          (soda host value)
          (soda host view)
          (soda packages base history)
          (soda packages buffer-mode)
          (soda packages edit-policy)
          (soda packages generated-buffer)
          (soda packages buffer-item)
          (soda packages completion)
          (soda packages interaction))

  ;; BufferListService is a generated Buffer producer.  It has no special
  ;; rendering or navigation path: rows are BufferItems and activation uses
  ;; the normal Window replacement operation shared by file and directory
  ;; packages.
  (define-record-type
    (buffer-list-service %make-buffer-list-service buffer-list-service?)
    (fields host owner history actions keymap result-keymap authority mode lists))

  (define-record-type buffer-list-state
    (fields (mutable generation buffer-list-state-generation
                     buffer-list-state-generation-set!)
            (mutable surface-id buffer-list-state-surface-id
                     buffer-list-state-surface-id-set!)
            (mutable selected-buffer-id buffer-list-state-selected-buffer-id
                     buffer-list-state-selected-buffer-id-set!)))

  (define-record-type buffer-list-open-request
    (fields context))

  (define-record-type buffer-list-refresh-request
    (fields context))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (buffer-list-keymap service)
    (unless (buffer-list-service? service)
      (assertion-violation 'buffer-list-keymap "expected a BufferListService" service))
    (buffer-list-service-keymap service))

  (define (generated-buffer? buffer)
    (buffer-state-field (buffer-state buffer) generated-projection-field #f))

  ;; Ordering is Surface-relative MRU.  The Buffer List itself is an interface
  ;; Buffer and never appears as an item in its own projection.
  (define (listed-buffers service list-state)
    (let* ([buffers
            (filter
              (lambda (buffer)
                (not (hashtable-contains? (buffer-list-service-lists service)
                                          (buffer-id buffer))))
              (package-host-buffers-for-surface
                (buffer-list-service-host service)
                (buffer-list-state-surface-id list-state)))]
           [selected-id (buffer-list-state-selected-buffer-id list-state)]
           [selected
            (find (lambda (buffer) (= (buffer-id buffer) selected-id)) buffers)])
      (if selected
          (cons selected
                (filter
                  (lambda (buffer) (not (= (buffer-id buffer) selected-id)))
                  buffers))
          buffers)))

  (define (modified-marker service buffer)
    (if (and (not (generated-buffer? buffer))
             (history-modified? (buffer-list-service-history service) (buffer-id buffer)))
        "*"
        " "))

  (define (buffer-mode-name buffer)
    (let ([mode
           (configuration-facet
             (buffer-state-configuration (buffer-state buffer))
             buffer-mode-facet 'buffer)])
      (if mode (mode-spec-display-name mode) "Fundamental")))

  (define (string-contains? value needle)
    (let ([limit (- (string-length value) (string-length needle))])
      (let loop ([index 0])
        (and (<= index limit)
             (or (string=? needle
                           (substring value index (+ index (string-length needle))))
                 (loop (+ index 1)))))))

  ;; The reader captures the Surface-relative catalog before opening its
  ;; minibuffer.  Prompt and completion Buffers therefore never appear as
  ;; switch targets, while liveness is checked again when the user accepts a
  ;; name.
  (define (make-buffer-switch-reader service)
    (make-interactive-reader
      'buffer
      (lambda (context arguments)
        (if (pair? arguments)
            (make-interactive-ready '())
            (let* ([host (buffer-list-service-host service)]
                   [surface-id (command-context-surface-id context)]
                   [choices (package-host-buffers-for-surface host surface-id)])
              (define (live-buffer-for-name name)
                (let ([candidate
                       (find (lambda (buffer) (string=? (buffer-name buffer) name))
                             choices)])
                  (and candidate
                       (let ([current
                              (package-host-buffer-ref host (buffer-id candidate) #f)])
                         (and current
                              (string=? (buffer-name current) name)
                              current)))))
              (define source
                (make-completion-source
                  (lambda (snapshot)
                    (let ([query (prompt-snapshot-input snapshot)])
                      (map
                        (lambda (buffer)
                          (make-completion-candidate
                            (buffer-id buffer) (buffer-name buffer) (buffer-name buffer)
                            (buffer-mode-name buffer) "Buffers" buffer))
                        (filter
                          (lambda (buffer)
                            (and (live-buffer-for-name (buffer-name buffer))
                                 (string-contains? (buffer-name buffer) query)))
                          choices))))
                  #f #f #f
                  (lambda (name snapshot) (and (string? name)
                                                (live-buffer-for-name name)))))
              (make-interactive-suspend
                (make-interaction-request
                  'buffer "Switch to buffer: " "" source 'must-match
                  (lambda (name snapshot) (and (string? name)
                                                (live-buffer-for-name name)))
                  'buffer)
                (lambda (name)
                  (let ([buffer (and (string? name) (live-buffer-for-name name))])
                    (unless buffer
                      (assertion-violation 'buffer.switch
                                           "selected Buffer no longer exists" name))
                    (make-interactive-ready (list buffer))))))))))

  (define (switch-buffer! service context buffer)
    (unless (buffer? buffer)
      (assertion-violation 'buffer.switch "expected a live Buffer" buffer))
    (unless
      (package-host-present-buffer!
        (buffer-list-service-host service) (buffer-list-service-owner service) buffer
        (command-context-surface-id context)
        (command-context-window-id context)
        (buffer-state-configuration (buffer-state buffer)))
      (assertion-violation 'buffer.switch "origin Window is no longer available" context))
    (command-handled))

  (define (buffer-list-layout service list-state)
    (let loop ([buffers (listed-buffers service list-state)]
               [text "Buffers  (* modified, % read-only)\n\n"]
               [ranges '()])
      (if (null? buffers)
          (cons text (make-range-set (reverse ranges)))
          (let* ([buffer (car buffers)]
                 [row
                  (string-append
                    (if (= (buffer-id buffer)
                           (buffer-list-state-selected-buffer-id list-state))
                        ">" " ")
                    (modified-marker service buffer)
                    (if (buffer-read-only?
                          (buffer-state-configuration (buffer-state buffer)))
                        "%" " ")
                    " " (buffer-name buffer)
                    "  "
                    (number->string
                      (snapshot-byte-size
                        (buffer-state-document (buffer-state buffer))))
                    " bytes  " (buffer-mode-name buffer) "\n")]
                 [start (bytevector-length (string->utf8 text))]
                 [end (+ start (bytevector-length (string->utf8 row)))]
                 [item
                  (make-buffer-item
                    'buffer-list (buffer-id buffer) 'buffer (buffer-id buffer)
                    '(visit close) 'visit)])
            (loop (cdr buffers) (string-append text row)
                  (cons (make-range-value start end item) ranges))))))

  (define (buffer-list-configuration service)
    (make-configuration
      (make-buffer-modes-extension (buffer-list-service-mode service) '())))

  (define (publish-buffer-list! service buffer)
    (let ([list-state
           (hashtable-ref (buffer-list-service-lists service) (buffer-id buffer) #f)])
      (and list-state
           (let* ([generation (+ (buffer-list-state-generation list-state) 1)]
                  [layout (buffer-list-layout service list-state)]
                  [update
                   (make-projection-update generation (car layout) (cdr layout) '() '())]
                  [published
                   (package-host-dispatch!
                     (buffer-list-service-host service)
                     (make-projection-transaction-spec
                       (buffer-id buffer) #f (buffer-state buffer) update
                       (list (make-edit-authority-annotation
                               (buffer-list-service-authority service)))))])
             (and published
                  (begin
                    (buffer-list-state-generation-set! list-state generation)
                    published))))))

  (define (show-buffer-list! service request)
    (let* ([context (buffer-list-open-request-context request)]
           [host (buffer-list-service-host service)]
           [key (make-buffer-key 'buffer-list 'default)]
           [buffer
            (package-host-open-or-create-buffer!
              host (buffer-list-service-owner service) key
              (lambda ()
                (package-host-create-buffer!
                  host (buffer-list-service-owner service) "*Buffer List*"
                  (make-document "") (buffer-list-configuration service))))])
      (let ([list-state
             (hashtable-ref
               (buffer-list-service-lists service) (buffer-id buffer) #f)])
        (unless list-state
          (set! list-state
                (make-buffer-list-state
                  0 (command-context-surface-id context)
                  (command-context-buffer-id context)))
          (hashtable-set! (buffer-list-service-lists service) (buffer-id buffer)
                          list-state))
        (unless (= (command-context-buffer-id context) (buffer-id buffer))
          (buffer-list-state-surface-id-set!
            list-state (command-context-surface-id context))
          (buffer-list-state-selected-buffer-id-set!
            list-state (command-context-buffer-id context))))
      (publish-buffer-list! service buffer)
      (if (= (buffer-id buffer) (command-context-buffer-id context))
          buffer
          (let ([view
                 (package-host-present-buffer!
                   host (buffer-list-service-owner service) buffer
                   (command-context-surface-id context)
                   (command-context-window-id context)
                   (buffer-state-configuration (buffer-state buffer)))])
            (unless view
              (assertion-violation 'buffer.list
                                   "origin Window is no longer available" context))
            buffer))))

  (define (refresh-buffer-list! service request)
    (let* ([context (buffer-list-refresh-request-context request)]
           [buffer
            (package-host-buffer-ref (buffer-list-service-host service)
                                (command-context-buffer-id context) #f)])
      (and buffer (publish-buffer-list! service buffer))))

  (define (visit-buffer! service item context ignored)
    (let* ([target-id (buffer-item-payload item)]
           [host (buffer-list-service-host service)]
           [target (package-host-buffer-ref host target-id #f)])
      (if (or (not target) (= target-id (command-context-buffer-id context)))
          (command-handled)
          (let* ([view
                  (package-host-present-buffer!
                    host (buffer-list-service-owner service) target
                    (command-context-surface-id context)
                    (command-context-window-id context)
                    (buffer-state-configuration (buffer-state target)))])
            (unless view
              (assertion-violation 'buffer-list.visit
                                   "origin Window is no longer available" context))
            (command-handled)))))

  (define (close-buffer! service item context ignored)
    (let ([target-id (buffer-item-payload item)])
      (if (not (package-host-buffer-ref (buffer-list-service-host service) target-id #f))
          (command-handled)
          (begin
            ;; The File package owns save decisions and close replacement.
            ;; Preserve the result Buffer's context while passing the selected
            ;; Buffer as an explicit command target.
            (command-runtime-enqueue!
              (package-host-command-runtime (buffer-list-service-host service))
              (make-command-invoke-message 'buffer.kill context (list target-id) #t))
            (command-handled)))))

  (define (close-item-at-point! service context)
    (let ([item
           (buffer-item-at-point
             (command-context-buffer-state context)
             (selection-range-head
               (selection-primary-range
                 (view-state-selection (command-context-view-state context)))))])
      (if (and item (memq 'close (buffer-item-actions item)))
          (or (buffer-item-action-invoke
                (buffer-list-service-actions service) 'close item context)
              (command-handled))
          (command-handled))))

  (define (make-buffer-list-service! host owner history actions)
    (unless (and (package-host? host) (owner? owner) (history? history)
                 (buffer-item-action-service? actions))
      (assertion-violation 'make-buffer-list-service!
                           "expected HostState, owner, History, and BufferItem actions"
                           host owner history actions))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-keymap 'buffer-list)]
           [result-keymap (make-keymap 'buffer-list-result)]
           [authority (make-edit-authority owner 'buffer-list-refresh)]
           [profile
            (make-generated-buffer-profile
              #t authority #t
              (list (make-input-layer 'buffer result-keymap #f 'ignore)
                    (buffer-item-input-layer actions)))]
           [mode
            (make-mode-spec
              'buffer-list-mode 'major "Buffer List" #f
              (generated-buffer-profile-extensions profile)
              (append '(buffer-list)
                      (generated-buffer-profile-command-categories profile))
              "Buffers")]
           [service
            (%make-buffer-list-service
              host owner history actions keymap result-keymap authority mode
              (make-eqv-hashtable))])
      (package-host-register-mode! host owner mode)
      (keymap-bind! keymap
                    (list (control-stroke #\x)
                          (make-key-stroke 'character (char->integer #\b) 0))
                    'buffer.list)
      (keymap-bind! keymap
                    (list (control-stroke #\x)
                          (make-key-stroke 'character (char->integer #\b) 4))
                    'buffer.switch)
      (keymap-bind! result-keymap (list (make-key-stroke 'character (char->integer #\g) 0))
                    'buffer-list.refresh)
      (keymap-bind! result-keymap (list (make-key-stroke 'character (char->integer #\d) 0))
                    'buffer-list.close-item)
      (buffer-item-action-register!
        actions owner 'buffer-list 'visit
        (lambda (item context generation)
          (visit-buffer! service item context generation)))
      (buffer-item-action-register!
        actions owner 'buffer-list 'close
        (lambda (item context generation)
          (close-buffer! service item context generation)))
      (command-runtime-register-effect-handler!
        runtime 'buffer-list.open owner 'open-buffer-list
        (lambda (ignored invocation effect)
          (show-buffer-list! service (command-effect-payload effect))))
      (command-runtime-register-effect-handler!
        runtime 'buffer-list.refresh owner 'refresh-buffer-list
        (lambda (ignored invocation effect)
          (refresh-buffer-list! service (command-effect-payload effect))))
      (define-command
        runtime owner 'buffer.list (context)
        (documentation "Show live Buffers in a generated Buffer List.")
        (class 'buffer)
        (undo 'ignore)
        (make-command-effect 'buffer-list.open (make-buffer-list-open-request context)))
      (define-command
        runtime owner 'buffer.switch (context buffer)
        (documentation "Switch to a live Buffer selected with completion.")
        (class 'buffer)
        (interactive
          (make-interactive-plan (list (make-buffer-switch-reader service))))
        (undo 'ignore)
        (switch-buffer! service context buffer))
      (define-command
        runtime owner 'buffer.bury (context)
        (documentation "Leave the active Buffer displayed elsewhere without killing it.")
        (class 'buffer)
        (undo 'ignore)
        (package-host-bury-window! host context)
        (command-handled))
      (define-command
        runtime owner 'buffer-list.refresh (context)
        (documentation "Refresh the generated Buffer List.")
        (class 'buffer-list)
        (scope 'mode)
        (undo 'ignore)
        (make-command-effect
          'buffer-list.refresh (make-buffer-list-refresh-request context)))
      (define-command
        runtime owner 'buffer-list.close-item (context)
        (documentation "Close the Buffer item at point.")
        (class 'buffer-list)
        (scope 'mode)
        (undo 'ignore)
        (close-item-at-point! service context))
      (package-host-add-buffer-close-listener!
        host owner
        (lambda (buffer)
          (hashtable-delete! (buffer-list-service-lists service) (buffer-id buffer))))
      service))
)
