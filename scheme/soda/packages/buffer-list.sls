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
          (soda packages buffer-item))

  ;; BufferListService is a generated Buffer producer.  It has no special
  ;; rendering or navigation path: rows are BufferItems and activation uses
  ;; the normal Window replacement operation shared by file and directory
  ;; packages.
  (define-record-type
    (buffer-list-service %make-buffer-list-service buffer-list-service?)
    (fields host owner history actions keymap result-keymap authority mode lists))

  (define-record-type buffer-list-state
    (fields (mutable generation buffer-list-state-generation
                     buffer-list-state-generation-set!)))

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

  ;; Deterministic ordering keeps a refreshed list stable for keyboard and
  ;; programmatic navigation.
  (define (listed-buffers service)
    (list-sort
      (lambda (left right) (< (buffer-id left) (buffer-id right)))
      (filter
        (lambda (buffer)
          (not (hashtable-contains? (buffer-list-service-lists service)
                                    (buffer-id buffer))))
        (package-host-buffers (buffer-list-service-host service)))))

  (define (modified-marker service buffer)
    (if (and (not (generated-buffer? buffer))
             (history-modified? (buffer-list-service-history service) (buffer-id buffer)))
        "*"
        " "))

  (define (buffer-list-layout service)
    (let loop ([buffers (listed-buffers service)]
               [text "Buffers:\n\n"]
               [ranges '()])
      (if (null? buffers)
          (cons text (make-range-set (reverse ranges)))
          (let* ([buffer (car buffers)]
                 [row
                  (string-append
                    (modified-marker service buffer) " "
                    (number->string (buffer-id buffer)) "  "
                    (buffer-name buffer) "\n")]
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
                  [layout (buffer-list-layout service)]
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
      (unless (hashtable-ref (buffer-list-service-lists service) (buffer-id buffer) #f)
        (hashtable-set! (buffer-list-service-lists service) (buffer-id buffer)
                        (make-buffer-list-state 0)))
      (publish-buffer-list! service buffer)
      (if (= (buffer-id buffer) (command-context-buffer-id context))
          buffer
          (let ([view
                 (package-host-create-view!
                   host (buffer-list-service-owner service) buffer
                   (buffer-state-configuration (buffer-state buffer)))])
            (unless
              (package-host-replace-window-view!
                host (command-context-surface-id context)
                (command-context-window-id context) (view-id view))
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
                  (package-host-create-view!
                    host (buffer-list-service-owner service) target
                    (buffer-state-configuration (buffer-state target)))])
            (unless
              (package-host-replace-window-view!
                host (command-context-surface-id context)
                (command-context-window-id context) (view-id view))
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
              (make-command-invoke-message 'file.close context (list target-id) #t))
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
           [mode
            (make-mode-spec
              'buffer-list-mode 'major "Buffer List" #f
              (append
                (generated-projection-extension)
                (list
                  (make-buffer-input-layer-extension
                    (list (make-input-layer 'buffer result-keymap #f 'ignore)
                          (buffer-item-input-layer actions)))
                  (make-buffer-edit-policy-extension
                    (make-buffer-edit-policy 'reject #f authority))))
              '(buffer-list buffer-item) "Buffers")]
           [service
            (%make-buffer-list-service
              host owner history actions keymap result-keymap authority mode
              (make-eqv-hashtable))])
      (keymap-bind! keymap (list (control-stroke #\x) (control-stroke #\b)) 'buffer.list)
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
        runtime owner 'buffer-list.refresh (context)
        (documentation "Refresh the generated Buffer List.")
        (class 'buffer)
        (undo 'ignore)
        (make-command-effect
          'buffer-list.refresh (make-buffer-list-refresh-request context)))
      (define-command
        runtime owner 'buffer-list.close-item (context)
        (documentation "Close the Buffer item at point.")
        (class 'buffer)
        (undo 'ignore)
        (close-item-at-point! service context))
      (package-host-add-buffer-close-listener!
        host owner
        (lambda (buffer)
          (hashtable-delete! (buffer-list-service-lists service) (buffer-id buffer))))
      service))
)
